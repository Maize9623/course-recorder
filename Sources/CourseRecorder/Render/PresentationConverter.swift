import Foundation
import AppKit

/// Converts PowerPoint / Keynote / OpenDocument presentations to PDF so they can be used as a slide deck.
/// LibreOffice runs headless in the background; Keynote (via AppleScript) is the fallback and handles `.key`.
enum PresentationConverter {
    static let extensions: Set<String> = ["ppt", "pptx", "pptm", "pps", "ppsx", "pot", "potx", "key", "odp"]

    static func isPresentation(_ path: String) -> Bool {
        extensions.contains((path as NSString).pathExtension.lowercased())
    }

    struct ConversionError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static var cacheDirectory: URL { SettingsStore.directory.appendingPathComponent("Slides", isDirectory: true) }

    /// PDF location for the current version of `source` (changes when the file is edited).
    static func cachedPDF(for source: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: source.path)
        let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in "\(source.path)|\(mtime)|\(size)".utf8 {
            hash ^= UInt64(b)
            hash = hash &* 0x100_0000_01b3
        }
        let name = source.deletingPathExtension().lastPathComponent
        return cacheDirectory.appendingPathComponent("\(name)-\(String(hash, radix: 16)).pdf")
    }

    /// Blocking; call from a background queue. Returns the converted (or cached) PDF.
    static func convert(_ source: URL) throws -> URL {
        let out = cachedPDF(for: source)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        var failures: [String] = []
        if source.pathExtension.lowercased() != "key", let soffice = libreOfficePath() {
            do {
                try convertWithLibreOffice(soffice: soffice, source: source, out: out)
                return out
            } catch {
                failures.append("LibreOffice：\(error.localizedDescription)")
            }
        }
        if NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iWork.Keynote") != nil {
            do {
                try convertWithKeynote(source: source, out: out)
                return out
            } catch {
                failures.append("Keynote：\(error.localizedDescription)")
            }
        }
        if failures.isEmpty {
            throw ConversionError(message: "没有找到 LibreOffice 或 Keynote。可以安装其一，或在 PowerPoint / WPS 里「导出为 PDF」后再导入")
        }
        throw ConversionError(message: failures.joined(separator: "；"))
    }

    static func libreOfficePath() -> String? {
        var candidates = [
            "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice",
            "/opt/homebrew/bin/soffice",
            "/usr/local/bin/soffice",
        ]
        if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "org.libreoffice.script") {
            candidates.insert(app.appendingPathComponent("Contents/MacOS/soffice").path, at: 0)
        }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func convertWithLibreOffice(soffice: String, source: URL, out: URL) throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("course-recorder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        // A private profile lets the conversion run even while the user has LibreOffice open.
        let profile = SettingsStore.directory.appendingPathComponent("libreoffice-profile", isDirectory: true)
        let status = try run(soffice, ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore", "--nologo",
                                       "--convert-to", "pdf", "--outdir", work.path, source.path], timeout: 240)
        let produced = work.appendingPathComponent(source.deletingPathExtension().lastPathComponent + ".pdf")
        guard FileManager.default.fileExists(atPath: produced.path) else {
            throw ConversionError(message: "没有生成 PDF（退出码 \(status.code)）\(status.stderr.isEmpty ? "" : "：" + status.stderr)")
        }
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.moveItem(at: produced, to: out)
    }

    private static func convertWithKeynote(source: URL, out: URL) throws {
        let script = [
            "on run argv",
            "set inFile to POSIX file (item 1 of argv)",
            "set outFile to POSIX file (item 2 of argv)",
            "set wasRunning to application \"Keynote\" is running",
            "tell application \"Keynote\"",
            "set theDoc to open inFile",
            "export theDoc to outFile as PDF with properties {PDF image quality:Best}",
            "close theDoc saving no",
            "if not wasRunning then quit",
            "end tell",
            "end run",
        ]
        let status = try run("/usr/bin/osascript", script.flatMap { ["-e", $0] } + [source.path, out.path], timeout: 300)
        guard FileManager.default.fileExists(atPath: out.path) else {
            throw ConversionError(message: status.stderr.isEmpty ? "导出失败（退出码 \(status.code)）" : status.stderr)
        }
    }

    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval) throws -> (code: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = FileHandle.nullDevice
        let lock = NSLock()
        var errData = Data()
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            lock.lock()
            errData.append(d)
            lock.unlock()
        }
        try p.run()
        let deadline = Date().addingTimeInterval(timeout)
        while p.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
        if p.isRunning {
            p.terminate()
            errPipe.fileHandleForReading.readabilityHandler = nil
            throw ConversionError(message: "转换超时")
        }
        errPipe.fileHandleForReading.readabilityHandler = nil
        lock.lock()
        let errText = String(data: errData, encoding: .utf8) ?? ""
        lock.unlock()
        let meaningful = errText.split(separator: "\n").filter { !$0.contains("Task policy set failed") }.joined(separator: " ")
        return (p.terminationStatus, String(meaningful.prefix(200)).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
