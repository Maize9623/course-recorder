import Foundation
import AVFoundation
import Combine

final class ProjectMusicCancellation {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}

/// Main-thread UI state; file decoding and copying run on a worker queue.
final class ProjectMusicImportController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var status = ""
    private(set) var operationID: UUID?
    private var cancellation: ProjectMusicCancellation?

    func begin() -> (UUID, ProjectMusicCancellation) {
        let token = UUID()
        let flag = ProjectMusicCancellation()
        operationID = token
        cancellation = flag
        status = "正在检查音乐并保存项目副本…"
        isBusy = true
        return (token, flag)
    }

    func cancel() {
        guard isBusy else { return }
        cancellation?.cancel()
        status = "正在取消并清理本次导入…"
    }

    func finish(_ token: UUID) {
        guard operationID == token else { return }
        operationID = nil
        cancellation = nil
        isBusy = false
        status = ""
    }
}

enum ProjectMusicFiles {
    struct MusicError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct Imported {
        let url: URL
        let relativePath: String
        let directory: URL
        func discard() { try? FileManager.default.removeItem(at: directory) }
    }

    /// Reject files that the same decoder used by BGMPlayer cannot read.
    static func validateAudio(_ url: URL) throws {
        do {
            let file = try AVAudioFile(forReading: url)
            let format = file.processingFormat
            let duration = Double(file.length) / format.sampleRate
            guard file.length > 0, format.channelCount > 0, format.sampleRate.isFinite,
                  format.sampleRate > 0, duration.isFinite, duration > 0,
                  let stereo = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false),
                  AVAudioConverter(from: format, to: stereo) != nil,
                  let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw MusicError(message: "音乐文件没有可读取的声音，请选择有效的音频文件。")
            }
            try file.read(into: buffer, frameCount: 4096)
            guard buffer.frameLength > 0 else {
                throw MusicError(message: "音乐文件没有可读取的声音，请选择有效的音频文件。")
            }
        } catch let error as MusicError {
            throw error
        } catch {
            throw MusicError(message: "无法读取音乐「\(url.lastPathComponent)」，请重新选择可播放的 MP3、M4A、WAV 或 AIFF。")
        }
    }

    /// Copies into a unique directory so rollback can remove only this operation's files.
    static func importFile(from source: URL, projectFolder: URL, cancellation: ProjectMusicCancellation,
                           progress: ((Int64) -> Void)? = nil) throws -> Imported {
        try cancellation.check()
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let before = try source.resourceValues(forKeys: keys)
        guard before.isRegularFile == true, (before.fileSize ?? 0) > 0 else {
            throw MusicError(message: "请选择一个有内容的音乐文件。")
        }
        try validateAudio(source)
        try cancellation.check()
        let music = projectFolder.appendingPathComponent("音乐", isDirectory: true)
        let root = projectFolder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard music.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root) else {
            throw MusicError(message: "项目音乐目录无效，请选择其他项目。")
        }
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: music.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue else {
                throw MusicError(message: "项目的「音乐」路径不是文件夹，请先在访达检查项目目录。")
            }
        } else {
            try fm.createDirectory(at: music, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        let identifier = UUID().uuidString
        let directory = music.appendingPathComponent(identifier, isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let destination = directory.appendingPathComponent(source.lastPathComponent)
        var complete = false
        defer { if !complete { try? fm.removeItem(at: directory) } }
        guard fm.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw MusicError(message: "无法在项目中创建音乐副本，请检查可用空间和文件夹权限。")
        }
        let input = try FileHandle(forReadingFrom: source)
        defer { try? input.close() }
        let output = try FileHandle(forWritingTo: destination)
        defer { try? output.close() }
        var copiedBytes: Int64 = 0
        while true {
            try cancellation.check()
            guard let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty else { break }
            try output.write(contentsOf: chunk)
            copiedBytes += Int64(chunk.count)
            progress?(copiedBytes)
        }
        try output.synchronize()
        try cancellation.check()
        var refreshedSource = source
        refreshedSource.removeAllCachedResourceValues()
        let after = try refreshedSource.resourceValues(forKeys: keys)
        guard before.fileSize == after.fileSize, before.contentModificationDate == after.contentModificationDate,
              (try destination.resourceValues(forKeys: [.fileSizeKey])).fileSize == before.fileSize else {
            throw MusicError(message: "音乐文件在导入期间发生变化，请等文件保存完成后重新选择。")
        }
        try validateAudio(destination)
        try cancellation.check()
        complete = true
        return Imported(url: destination, relativePath: "音乐/\(identifier)/\(source.lastPathComponent)", directory: directory)
    }

    static func tracks(for project: CourseProject, folder: URL, defaults: [String]) throws -> [String] {
        guard project.includeBGM else { return [] }
        guard let relative = project.bgmFile else {
            let urls = defaults.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            for url in urls {
                do {
                    guard FileManager.default.fileExists(atPath: url.path) else {
                        throw MusicError(message: "文件不存在")
                    }
                    try validateAudio(url)
                } catch {
                    throw MusicError(message: "默认播放列表中的音乐「\(url.lastPathComponent)」缺失或无法读取。请重新选择音乐，在「音频」页修复播放列表，或关闭「加入 BGM」后导出。")
                }
            }
            return urls.map(\.path)
        }
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw MusicError(message: "项目的背景音乐路径无效，请重新选择音乐。")
        }
        let root = folder.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let url = folder.appendingPathComponent(relative).resolvingSymlinksInPath().standardizedFileURL
        guard url.path.hasPrefix(root), FileManager.default.fileExists(atPath: url.path) else {
            throw MusicError(message: "找不到项目的背景音乐「\(URL(fileURLWithPath: relative).lastPathComponent)」。请重新选择音乐，或关闭「加入 BGM」后导出。")
        }
        try validateAudio(url)
        return [url.path]
    }
}
