import Foundation

extension ProjectStore {
    struct TrashError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Only an actual project directly inside this recording directory may be moved.
    static func validateTrashFolder(_ folder: URL, in recordings: URL) throws {
        let target = folder.standardizedFileURL
        let expectedRoot = root(in: recordings).standardizedFileURL.resolvingSymlinksInPath()
        let resolved = target.resolvingSymlinksInPath()
        let values = try target.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              resolved != expectedRoot,
              resolved.deletingLastPathComponent() == expectedRoot,
              load(target) != nil else {
            throw TrashError(message: "该目录不是录制目录内的有效项目，未执行删除")
        }
    }

    /// Uses the system Trash so the entire project, including backups, remains recoverable.
    @discardableResult
    static func trash(_ folder: URL, in recordings: URL) throws -> URL? {
        try validateTrashFolder(folder, in: recordings)
        var result: NSURL?
        try FileManager.default.trashItem(at: folder, resultingItemURL: &result)
        return result as URL?
    }
}
