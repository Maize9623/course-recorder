import Foundation

/// Commits a new narration version only after rendering and subtitle generation succeed.
enum NarrationEditStore {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func localFile(_ relative: String, in folder: URL) throws -> URL {
        guard !relative.isEmpty, !relative.hasPrefix("/"),
              !relative.split(separator: "/").contains("..") else {
            throw Failure(message: "项目文件路径无效，请重新打开项目。")
        }
        let base = folder.resolvingSymlinksInPath().standardizedFileURL
        var url = base
        // Resolve each existing parent before appending a not-yet-created child. Foundation may leave
        // a symlink unresolved when only the final leaf is missing; project copies never need symlinks.
        for component in relative.split(separator: "/") {
            guard component != "." else { throw Failure(message: "项目文件路径无效。") }
            url.appendPathComponent(String(component))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil {
                throw Failure(message: "项目文件路径不能经过符号链接，请使用项目内的原文件。")
            }
        }
        url = url.standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw Failure(message: "项目文件不能位于项目目录之外。") }
        return url
    }

    static func checkUnchanged(_ original: CourseProject, folder: URL) throws {
        // Compare the persisted representation because ISO-8601 storage discards subsecond creation dates.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        guard let stored = ProjectStore.load(folder),
              try encoder.encode(stored) == encoder.encode(original) else {
            throw Failure(message: "项目文件已发生变化，本次剪辑没有应用，请重新打开项目。")
        }
    }

    static func apply(original: CourseProject, folder: URL, editedURL: URL?, duration: Double,
                      srt: String, cuts: [NarrationCut]) throws -> CourseProject {
        try checkUnchanged(original, folder: folder)
        guard duration.isFinite, duration > 0, !srt.isEmpty else {
            throw Failure(message: "剪辑结果或字幕为空，原项目没有修改。")
        }
        let expectedDuration = try NarrationEditor.timeline(duration: original.narrationDuration, cuts: cuts).duration
        guard cuts.isEmpty == (editedURL == nil), abs(duration - expectedDuration) < 0.001 else {
            throw Failure(message: "剪辑视频与字幕时间不一致，原项目没有修改。")
        }
        let fm = FileManager.default
        let identity = UUID().uuidString
        let backupPath = "剪辑前备份/\(identity)"
        let backup = try localFile(backupPath, in: folder)
        try ProjectStore.save(original, to: backup)
        let subtitleName = "口播字幕-\(identity).srt"
        let subtitleURL = folder.appendingPathComponent(subtitleName)
        var newMedia: URL?
        do {
            var replacement = original
            if let editedURL {
                let filename = "口播-剪辑-\(identity).mp4"
                let destination = folder.appendingPathComponent(filename)
                try fm.moveItem(at: editedURL, to: destination)
                newMedia = destination
                replacement.narrationFile = filename
                replacement.narrationDuration = duration
                replacement.narrationEditBackup = backupPath
                replacement.cues = []
                replacement.takes = []
                replacement.cursor = []
                replacement.clicks = []
                replacement.outputFile = nil
            }
            try srt.write(to: subtitleURL, atomically: true, encoding: .utf8)
            replacement.subtitleFile = subtitleName
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cuts).write(to: backup.appendingPathComponent("删除建议.json"), options: .atomic)
            try checkUnchanged(original, folder: folder)
            try ProjectStore.save(replacement, to: folder)
            return replacement
        } catch {
            if let newMedia { try? fm.removeItem(at: newMedia) }
            try? fm.removeItem(at: subtitleURL)
            throw error
        }
    }

    static func restore(current: CourseProject, folder: URL) throws -> CourseProject {
        try checkUnchanged(current, folder: folder)
        guard let relative = current.narrationEditBackup else { throw Failure(message: "没有可恢复的剪辑前版本。") }
        let backup = try localFile(relative, in: folder)
        guard let restored = ProjectStore.load(backup), let narration = restored.narrationFile,
              FileManager.default.fileExists(atPath: try localFile(narration, in: folder).path) else {
            throw Failure(message: "剪辑前备份或原口播不在项目里，无法恢复；当前版本未修改。")
        }
        let undo = try localFile("恢复前备份/\(UUID().uuidString)", in: folder)
        try ProjectStore.save(current, to: undo)
        try ProjectStore.save(restored, to: folder)
        return restored
    }
}
