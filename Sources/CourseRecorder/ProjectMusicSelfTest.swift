import Foundation
import AVFoundation

/// CPU-only checks: synthetic sound, project-local copies and export music resolution.
enum ProjectMusicSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() throws -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("course-music-test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var checks = 0
        func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
            guard try condition() else { throw Failure(message: message) }
            checks += 1
        }
        func reject(_ message: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { checks += 1; return }
            throw Failure(message: message)
        }
        let source = root.appendingPathComponent("自选音乐.wav")
        try writeTone(to: source)
        let sourceData = try Data(contentsOf: source)
        try ProjectMusicFiles.validateAudio(source)
        checks += 1
        let projectFolder = root.appendingPathComponent("测试课程", isDirectory: true)
        var project = CourseProject(name: "测试课程")
        try ProjectStore.save(project, to: projectFolder)

        // Old project JSON does not need a migration or a new required field.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var old = try JSONSerialization.jsonObject(with: encoder.encode(project)) as! [String: Any]
        old.removeValue(forKey: "bgmFile")
        try JSONSerialization.data(withJSONObject: old).write(to: projectFolder.appendingPathComponent(CourseProject.fileName))
        let legacy = ProjectStore.load(projectFolder)
        try expect(legacy != nil && legacy?.bgmFile == nil && legacy?.includeBGM == true, "旧项目无法兼容默认播放列表")
        try expect(try ProjectMusicFiles.tracks(for: project, folder: projectFolder, defaults: [source.path]) == [source.path], "默认列表未沿用")

        let imported = try ProjectMusicFiles.importFile(from: source, projectFolder: projectFolder, cancellation: ProjectMusicCancellation())
        try expect(imported.relativePath.hasPrefix("音乐/"), "音乐未保存在项目内")
        try expect(imported.url.lastPathComponent == source.lastPathComponent, "未保留原音乐文件名")
        try expect(try Data(contentsOf: imported.url) == sourceData, "音乐副本内容不一致")
        try expect(try Data(contentsOf: source) == sourceData, "原音乐被改动")
        project.bgmFile = imported.relativePath
        try ProjectStore.save(project, to: projectFolder)
        try expect(ProjectStore.load(projectFolder)?.bgmFile == imported.relativePath, "项目音乐选择未持久化")
        try expect(try ProjectMusicFiles.tracks(for: project, folder: projectFolder, defaults: ["unused-default.mp3"]) == [imported.url.path], "项目音乐未优先于默认列表")

        let second = try ProjectMusicFiles.importFile(from: source, projectFolder: projectFolder, cancellation: ProjectMusicCancellation())
        try expect(second.relativePath != imported.relativePath, "重复导入覆盖了之前的音乐")
        second.discard()
        try expect(!fm.fileExists(atPath: second.directory.path), "取消的新音乐未清理")
        try expect(try Data(contentsOf: imported.url) == sourceData, "清理新副本影响了旧音乐")
        try fm.removeItem(at: source)
        let resolved = try ProjectMusicFiles.tracks(for: project, folder: projectFolder, defaults: [])
        try expect(resolved == [imported.url.path], "原音乐移动后项目副本不可用")

        // Exercise the real export-side BGM decoder without touching audio devices or GPU.
        let player = BGMPlayer()
        player.setTracks(resolved)
        player.setFadeSeconds(0.05)
        player.loopMode = .single
        player.play()
        var left = [Float](repeating: 0, count: 48000 * 3)
        var right = left
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                player.render(frames: l.count, l: l.baseAddress!, r: r.baseAddress!)
            }
        }
        player.pause()
        try expect(left.contains { abs($0) > 0.05 }, "选中的项目音乐没有解码输出")
        try expect(right.contains { abs($0) > 0.05 }, "项目音乐没有右声道输出")
        try expect(left.suffix(48000).contains { abs($0) > 0.05 }, "项目音乐单曲循环未覆盖成片时长")

        var disabled = project
        disabled.includeBGM = false
        disabled.bgmFile = "音乐/缺失.mp3"
        try expect(try ProjectMusicFiles.tracks(for: disabled, folder: projectFolder, defaults: ["unused"]).isEmpty,
                   "关闭BGM后仍尝试打开音乐")
        var invalid = project
        invalid.bgmFile = "音乐/缺失.mp3"
        try reject("缺失的项目音乐被静默忽略") { _ = try ProjectMusicFiles.tracks(for: invalid, folder: projectFolder, defaults: []) }
        invalid.bgmFile = "../自选音乐.wav"
        try reject("项目音乐允许跨目录路径") { _ = try ProjectMusicFiles.tracks(for: invalid, folder: projectFolder, defaults: []) }
        invalid.bgmFile = imported.url.path
        try reject("项目音乐允许绝对路径") { _ = try ProjectMusicFiles.tracks(for: invalid, folder: projectFolder, defaults: []) }
        invalid.bgmFile = ""
        try reject("项目音乐允许空路径") { _ = try ProjectMusicFiles.tracks(for: invalid, folder: projectFolder, defaults: []) }

        let bad = root.appendingPathComponent("损坏音乐.wav")
        try Data("not audio".utf8).write(to: bad)
        try reject("损坏音频被接受") { try ProjectMusicFiles.validateAudio(bad) }
        var defaultProject = project
        defaultProject.bgmFile = nil
        try reject("默认列表缺失音乐被静默忽略") {
            _ = try ProjectMusicFiles.tracks(for: defaultProject, folder: projectFolder, defaults: [source.path])
        }
        try reject("默认列表损坏音乐被静默忽略") {
            _ = try ProjectMusicFiles.tracks(for: defaultProject, folder: projectFolder, defaults: [bad.path])
        }
        try expect(try ProjectMusicFiles.tracks(for: defaultProject, folder: projectFolder, defaults: []).isEmpty,
                   "空默认列表不兼容旧项目")
        let empty = root.appendingPathComponent("空音乐.wav")
        try Data().write(to: empty)
        try reject("空文件被接受") { _ = try ProjectMusicFiles.importFile(from: empty, projectFolder: projectFolder, cancellation: ProjectMusicCancellation()) }
        let directory = root.appendingPathComponent("目录.wav", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: false)
        try reject("目录被接受为音乐") { _ = try ProjectMusicFiles.importFile(from: directory, projectFolder: projectFolder, cancellation: ProjectMusicCancellation()) }
        let priorFiles = try fm.contentsOfDirectory(atPath: projectFolder.appendingPathComponent("音乐").path)
        try reject("损坏音频被复制进项目") { _ = try ProjectMusicFiles.importFile(from: bad, projectFolder: projectFolder, cancellation: ProjectMusicCancellation()) }
        try expect(try fm.contentsOfDirectory(atPath: projectFolder.appendingPathComponent("音乐").path) == priorFiles,
                   "导入坏音频留下临时目录")
        let flag = ProjectMusicCancellation()
        flag.cancel()
        do {
            _ = try ProjectMusicFiles.importFile(from: imported.url, projectFolder: projectFolder, cancellation: flag)
            throw Failure(message: "取消后的操作仍导入音乐")
        } catch is CancellationError { checks += 1 }
        try expect(try fm.contentsOfDirectory(atPath: projectFolder.appendingPathComponent("音乐").path) == priorFiles,
                   "取消导入改变了原音乐目录")
        let midCopyCancellation = ProjectMusicCancellation()
        do {
            _ = try ProjectMusicFiles.importFile(from: imported.url, projectFolder: projectFolder,
                                                 cancellation: midCopyCancellation) { _ in midCopyCancellation.cancel() }
            throw Failure(message: "复制过程中的取消未生效")
        } catch is CancellationError { checks += 1 }
        try expect(try fm.contentsOfDirectory(atPath: projectFolder.appendingPathComponent("音乐").path) == priorFiles,
                   "复制中取消遗留了部分音乐文件")
        try expect(try Data(contentsOf: imported.url) == sourceData, "复制中取消影响了原音乐")

        let outside = root.appendingPathComponent("外部", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        let linked = projectFolder.appendingPathComponent("外部音乐.wav")
        try fm.createSymbolicLink(at: linked, withDestinationURL: bad)
        invalid.bgmFile = linked.lastPathComponent
        try reject("导出读取了项目外的音乐链接") { _ = try ProjectMusicFiles.tracks(for: invalid, folder: projectFolder, defaults: []) }
        let symlinkProject = root.appendingPathComponent("链接项目", isDirectory: true)
        try fm.createDirectory(at: symlinkProject, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: symlinkProject.appendingPathComponent("音乐"), withDestinationURL: outside)
        try reject("导入写到了项目外部目录") {
            _ = try ProjectMusicFiles.importFile(from: imported.url, projectFolder: symlinkProject, cancellation: ProjectMusicCancellation())
        }
        try expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "链接目录外部被写入音乐")
        try expect(ProjectStore.load(projectFolder)?.bgmFile == imported.relativePath, "失败或取消改变了原音乐选择")
        return checks
    }

    private static func writeTone(to url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44100)!
        buffer.frameLength = 44100
        for i in 0..<44100 {
            buffer.floatChannelData![0][i] = 0.2 * Float(sin(Double(i) / 44100 * 440 * 2 * .pi))
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
