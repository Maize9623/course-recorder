import Foundation
import CoreGraphics

/// Exercises metadata transactions with fake movie bytes; this is not a media validity test.
/// All files live under an isolated temporary folder. No AppState, capture, Speech, or GPU is created.
enum NarrationEditStoreSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() throws -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("CourseRecorder-Edit-Store-Test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: root) }
        var count = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw Failure(message: "口播剪辑事务检查失败：\(label)") }
            count += 1
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            do { try action() }
            catch { count += 1; return }
            throw Failure(message: "口播剪辑事务未拒绝：\(label)")
        }
        let originalBytes = Data("synthetic original narration - not real media".utf8)
        let demoBytes = Data("synthetic demonstration - keep original".utf8)
        let outputBytes = Data("synthetic old final output - keep original".utf8)
        let editedBytes = Data("synthetic edited narration - not real media".utf8)
        let oldCaption = "1\n00:00:00,000 --> 00:00:01,000\n原字幕\n"
        let newCaption = "1\n00:00:00,000 --> 00:00:01,000\n剪后字幕\n"
        let cuts = [NarrationCut(start: 2, end: 4, text: "重来", reason: "合成事务检查")]
        func fixture(_ name: String) throws -> (folder: URL, project: CourseProject, source: URL) {
            let folder = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder.appendingPathComponent("演示"), withIntermediateDirectories: true)
            let source = folder.appendingPathComponent("口播.mp4")
            try originalBytes.write(to: source)
            try demoBytes.write(to: folder.appendingPathComponent("演示/take-001.mp4"))
            try outputBytes.write(to: folder.appendingPathComponent("成片.mp4"))
            try oldCaption.write(to: folder.appendingPathComponent("旧字幕.srt"), atomically: true, encoding: .utf8)
            var project = CourseProject(name: name)
            project.narrationFile = "口播.mp4"
            project.narrationDuration = 10
            project.narrationIsImported = true
            project.subtitleFile = "旧字幕.srt"
            project.outputFile = "成片.mp4"
            project.cues = [Cue(time: 0, action: .scene(.camera)), Cue(time: 5, action: .slide(0))]
            project.takes = [Take(file: "演示/take-001.mp4", source: .display(1), start: 1, end: 9,
                                  width: 100, height: 100, contentRect: CGRect(x: 0, y: 0, width: 100, height: 100))]
            project.cursor = [TimedPoint(t: 3, x: 0.3, y: 0.4)]
            project.clicks = [TimedPoint(t: 4, x: 0.3, y: 0.4)]
            project.deckPath = "/synthetic/lecture.pdf"
            project.includeBGM = false
            project.bgmFile = "音乐/synthetic.wav"
            try ProjectStore.save(project, to: folder)
            // Compare persisted values, whose date precision matches the store.
            guard let saved = ProjectStore.load(folder) else { throw Failure(message: "无法创建合成项目") }
            return (folder, saved, source)
        }
        func staged(_ name: String) throws -> URL {
            let url = root.appendingPathComponent(name)
            try editedBytes.write(to: url)
            return url
        }
        let basic = try fixture("正常应用")
        let stagedMovie = try staged("prepared.mp4")
        let changed = try NarrationEditStore.apply(original: basic.project, folder: basic.folder,
                                                   editedURL: stagedMovie, duration: 8, srt: newCaption, cuts: cuts)
        try check(ProjectStore.load(basic.folder) == changed, "新项目已原子保存")
        try check(changed.narrationFile != basic.project.narrationFile && changed.narrationDuration == 8, "媒体引用与时长更新")
        try check(try Data(contentsOf: basic.source) == originalBytes, "原口播逐字节保留")
        try check(!fm.fileExists(atPath: stagedMovie.path), "只移动本次准备文件")
        let newMedia = try NarrationEditStore.localFile(changed.narrationFile!, in: basic.folder)
        try check(try Data(contentsOf: newMedia) == editedBytes, "新口播保存到项目")
        try check(changed.cues.isEmpty && changed.takes.isEmpty && changed.cursor.isEmpty && changed.clicks.isEmpty, "旧时间线引用清空")
        try check(changed.outputFile == nil, "旧成片不再作为当前输出")
        try check(try Data(contentsOf: basic.folder.appendingPathComponent("演示/take-001.mp4")) == demoBytes, "原演示媒体保留")
        try check(try Data(contentsOf: basic.folder.appendingPathComponent("成片.mp4")) == outputBytes, "原成片媒体保留")
        try check(changed.narrationIsImported == true && changed.bgmFile == basic.project.bgmFile && changed.deckPath == basic.project.deckPath,
                  "画幅音乐和课件设置不受剪辑影响")
        let newCaptionURL = try NarrationEditStore.localFile(changed.subtitleFile!, in: basic.folder)
        try check(try String(contentsOf: newCaptionURL, encoding: .utf8) == newCaption, "字幕引用指向本次SRT")
        try check(try String(contentsOf: basic.folder.appendingPathComponent("旧字幕.srt"), encoding: .utf8) == oldCaption, "旧字幕保留")
        let backup = try NarrationEditStore.localFile(changed.narrationEditBackup!, in: basic.folder)
        try check(ProjectStore.load(backup) == basic.project, "剪辑前完整项目可读取")
        let savedCuts = try JSONDecoder().decode([NarrationCut].self, from: Data(contentsOf: backup.appendingPathComponent("删除建议.json")))
        try check(savedCuts == cuts, "审核删减范围留在备份")
        let restored = try NarrationEditStore.restore(current: changed, folder: basic.folder)
        try check(restored == basic.project && ProjectStore.load(basic.folder) == basic.project, "恢复全部旧项目字段")
        try check(try Data(contentsOf: newMedia) == editedBytes && String(contentsOf: newCaptionURL, encoding: .utf8) == newCaption,
                  "恢复不删除新口播和新字幕")
        let beforeRestore = try fm.contentsOfDirectory(at: basic.folder.appendingPathComponent("恢复前备份"), includingPropertiesForKeys: nil)
        try check(beforeRestore.count == 1 && ProjectStore.load(beforeRestore[0]) == changed, "恢复前保存当前版本")

        let subtitleOnly = try fixture("只存字幕")
        let captioned = try NarrationEditStore.apply(original: subtitleOnly.project, folder: subtitleOnly.folder,
                                                     editedURL: nil, duration: 10, srt: newCaption, cuts: [])
        try check(captioned.narrationFile == subtitleOnly.project.narrationFile && captioned.narrationDuration == 10,
                  "仅字幕保留口播引用和时长")
        try check(captioned.cues == subtitleOnly.project.cues && captioned.takes == subtitleOnly.project.takes &&
                  captioned.cursor == subtitleOnly.project.cursor && captioned.outputFile == subtitleOnly.project.outputFile,
                  "仅字幕不清操作或成片")
        try check(captioned.narrationEditBackup == subtitleOnly.project.narrationEditBackup, "仅字幕不创造虚假的可恢复剪辑入口")

        let invalid = try fixture("失败保护")
        let protectedJSON = try Data(contentsOf: invalid.folder.appendingPathComponent(CourseProject.fileName))
        let protectedStage = try staged("still-prepared.mp4")
        try rejects("有删减但缺少视频") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder, editedURL: nil,
                                            duration: 8, srt: newCaption, cuts: cuts)
        }
        try rejects("无删减却传入视频") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder, editedURL: protectedStage,
                                            duration: 10, srt: newCaption, cuts: [])
        }
        try rejects("字幕与剪后时间线不一致") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder, editedURL: protectedStage,
                                            duration: 7.5, srt: newCaption, cuts: cuts)
        }
        try rejects("反向剪辑范围") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder, editedURL: protectedStage,
                                            duration: 8, srt: newCaption, cuts: [NarrationCut(start: 4, end: 2, text: "bad", reason: "bad")])
        }
        try rejects("非有限时长") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder, editedURL: protectedStage,
                                            duration: .infinity, srt: newCaption, cuts: cuts)
        }
        try rejects("空字幕") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder, editedURL: protectedStage,
                                            duration: 8, srt: "", cuts: cuts)
        }
        try check(try Data(contentsOf: protectedStage) == editedBytes, "参数校验失败不移动准备视频")
        try check(try Data(contentsOf: invalid.folder.appendingPathComponent(CourseProject.fileName)) == protectedJSON,
                  "参数校验失败不改旧项目字节")
        try rejects("视频移动失败") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder,
                                            editedURL: root.appendingPathComponent("does-not-exist.mp4"),
                                            duration: 8, srt: newCaption, cuts: cuts)
        }
        try check(try Data(contentsOf: invalid.source) == originalBytes &&
                  Data(contentsOf: invalid.folder.appendingPathComponent(CourseProject.fileName)) == protectedJSON,
                  "事务失败仍保留原口播与项目")
        let afterFailure = try fm.contentsOfDirectory(at: invalid.folder, includingPropertiesForKeys: nil).map(\.lastPathComponent)
        try check(!afterFailure.contains { $0.hasPrefix("口播-剪辑-") || $0.hasPrefix("口播字幕-") }, "失败不遗留可被误用的媒体或字幕")
        var external = invalid.project
        external.name = "磁盘外部更新"
        try ProjectStore.save(external, to: invalid.folder)
        let externalJSON = try Data(contentsOf: invalid.folder.appendingPathComponent(CourseProject.fileName))
        try rejects("磁盘项目外部变化") {
            _ = try NarrationEditStore.apply(original: invalid.project, folder: invalid.folder, editedURL: protectedStage,
                                            duration: 8, srt: newCaption, cuts: cuts)
        }
        try check(try Data(contentsOf: invalid.folder.appendingPathComponent(CourseProject.fileName)) == externalJSON &&
                  Data(contentsOf: protectedStage) == editedBytes, "冲突时保留外部更新和准备文件")

        for path in ["", "/tmp/outside.mp4", "../outside.mp4", "素材/../../outside.mp4"] {
            try rejects("路径越界 \(path)") { _ = try NarrationEditStore.localFile(path, in: invalid.folder) }
        }
        let outside = root.appendingPathComponent("项目外", isDirectory: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.createSymbolicLink(at: invalid.folder.appendingPathComponent("escape"), withDestinationURL: outside)
        try rejects("符号链接逃逸") { _ = try NarrationEditStore.localFile("escape/movie.mp4", in: invalid.folder) }
        try check(try NarrationEditStore.localFile("演示/take-001.mp4", in: invalid.folder)
                    == invalid.folder.appendingPathComponent("演示/take-001.mp4").resolvingSymlinksInPath().standardizedFileURL,
                  "正常相对路径可用")
        let escapedBackup = try fixture("备份逃逸")
        try fm.createSymbolicLink(at: escapedBackup.folder.appendingPathComponent("剪辑前备份"), withDestinationURL: outside)
        try rejects("备份目录符号链接逃逸") {
            _ = try NarrationEditStore.apply(original: escapedBackup.project, folder: escapedBackup.folder,
                                            editedURL: protectedStage, duration: 8, srt: newCaption, cuts: cuts)
        }
        let outsideContents = try fm.contentsOfDirectory(at: outside, includingPropertiesForKeys: nil)
        try check(ProjectStore.load(escapedBackup.folder) == escapedBackup.project && outsideContents.isEmpty,
                  "备份逃逸不写项目外也不改项目")
        let restoreFailure = try fixture("恢复失败保护")
        var missingBackup = restoreFailure.project
        missingBackup.narrationEditBackup = "不存在的备份"
        try ProjectStore.save(missingBackup, to: restoreFailure.folder)
        try rejects("恢复缺失备份") { _ = try NarrationEditStore.restore(current: missingBackup, folder: restoreFailure.folder) }
        let restoredSourceBytes = try Data(contentsOf: restoreFailure.source)
        try check(ProjectStore.load(restoreFailure.folder) == missingBackup &&
                  restoredSourceBytes == originalBytes, "恢复失败不修改当前版本")
        var escapedRestore = missingBackup
        escapedRestore.narrationEditBackup = "../项目外"
        try ProjectStore.save(escapedRestore, to: restoreFailure.folder)
        try rejects("恢复越界备份") { _ = try NarrationEditStore.restore(current: escapedRestore, folder: restoreFailure.folder) }
        try check(ProjectStore.load(restoreFailure.folder) == escapedRestore, "恢复越界失败保持当前项目")
        return count
    }
}
