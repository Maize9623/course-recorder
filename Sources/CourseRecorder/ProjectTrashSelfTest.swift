import Foundation

/// Exercises only disposable fixtures, including a real round trip through the system Trash.
enum ProjectTrashSelfTest {
    static func run() throws -> Int {
        let fm = FileManager.default
        let recordings = fm.temporaryDirectory.appendingPathComponent("CourseRecorder-Trash-Test-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: recordings, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: recordings) }
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw ProjectStore.TrashError(message: "项目删除自测失败：\(name)") }
            checks += 1
        }
        let (_, folder) = try ProjectStore.create(named: "可恢复测试-\(UUID().uuidString)", deckPath: "", in: recordings)
        guard let project = ProjectStore.load(folder) else {
            throw ProjectStore.TrashError(message: "无法读取合成测试项目")
        }
        let (_, sibling) = try ProjectStore.create(named: "保留的项目", deckPath: "", in: recordings)
        let payload = Data("synthetic project data".utf8)
        let media = folder.appendingPathComponent("口播.mp4")
        try payload.write(to: media)
        let backup = folder.appendingPathComponent("导入前备份/合成备份")
        try ProjectStore.save(project, to: backup)
        try ProjectStore.validateTrashFolder(folder, in: recordings)
        checks += 1
        func rejects(_ candidate: URL, _ label: String) throws {
            do {
                try ProjectStore.validateTrashFolder(candidate, in: recordings)
                throw ProjectStore.TrashError(message: "未拒绝\(label)")
            } catch let error as ProjectStore.TrashError {
                try check(!error.message.hasPrefix("未拒绝"), label)
            }
        }
        try rejects(ProjectStore.root(in: recordings), "拒绝整个项目根目录")
        try rejects(recordings, "拒绝录制根目录")
        try rejects(backup, "拒绝嵌套备份目录")
        let outside = recordings.appendingPathComponent("外部文件夹")
        try ProjectStore.save(project, to: outside)
        try rejects(outside, "拒绝项目根目录之外的目录")
        let link = ProjectStore.root(in: recordings).appendingPathComponent("指向其他目录")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        try rejects(link, "拒绝符号链接")
        let invalid = ProjectStore.root(in: recordings).appendingPathComponent("不是项目")
        try fm.createDirectory(at: invalid, withIntermediateDirectories: false)
        try rejects(invalid, "拒绝缺少有效项目的目录")

        guard let trashURL = try ProjectStore.trash(folder, in: recordings) else {
            throw ProjectStore.TrashError(message: "系统未返回测试项目在废纸篓的位置")
        }
        // Restore our fixture on every exit; never leave test data in the user's Trash.
        defer {
            if fm.fileExists(atPath: trashURL.path), !fm.fileExists(atPath: folder.path) {
                try? fm.moveItem(at: trashURL, to: folder)
            }
        }
        try check(!fm.fileExists(atPath: folder.path), "原位置已移走")
        try check(ProjectStore.load(trashURL) == project, "废纸篓中项目元数据完整")
        try check(try Data(contentsOf: trashURL.appendingPathComponent("口播.mp4")) == payload, "媒体逐字节保留")
        try check(ProjectStore.load(trashURL.appendingPathComponent("导入前备份/合成备份")) == project, "项目备份完整")
        try check(ProjectStore.load(sibling) != nil && ProjectStore.load(outside) == project, "其他目录未改动")
        try check(!ProjectStore.list(in: recordings).contains(project.name), "项目列表移除已删项目")
        try fm.moveItem(at: trashURL, to: folder)
        try check(ProjectStore.load(folder) == project && fm.fileExists(atPath: media.path), "可恢复到原位置")
        return checks
    }
}
