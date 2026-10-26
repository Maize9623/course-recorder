import Foundation
import AppKit

extension AppState {
    func deleteProject() {
        guard canManageProject, let project = production.project, let folder = production.folder else { return }
        let recordings = settings.recording.folderURL
        do { try ProjectStore.validateTrashFolder(folder, in: recordings) }
        catch {
            showToast("无法删除项目：\(error.localizedDescription)", icon: "exclamationmark.triangle")
            return
        }

        // Hold the edit lock while the confirmation modal runs its nested main loop.
        projectActionInProgress = true
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "将项目「\(project.name)」移到废纸篓？"
        alert.informativeText = "项目文件夹内的口播、演示素材、时间线、音乐副本、备份和成片都会一起移入废纸篓。项目外的原始视频、音乐和课件不受影响。误删后可在访达的废纸篓中找回。"
        alert.addButton(withTitle: "移到废纸篓")
        alert.addButton(withTitle: "取消")
        alert.buttons.first?.keyEquivalent = ""
        alert.buttons.last?.keyEquivalent = "\r"
        guard alert.runModal() == .alertFirstButtonReturn else {
            projectActionInProgress = false
            return
        }
        guard production.folder == folder, production.project == project,
              recState == .idle, exportProgress == nil, narrationImportProgress == nil,
              !aiProduction.locksProject, !production.isPlaying else {
            projectActionInProgress = false
            showToast("项目状态发生变化，未执行删除，请重试", icon: "exclamationmark.triangle")
            return
        }

        // Invalidate pending player callbacks and delayed saves before moving any files.
        production.close()
        production.finishOperations { [weak self] in
            guard let self else { return }
            defer { self.projectActionInProgress = false }
            let saved = ProjectStore.load(folder) ?? project
            do {
                try ProjectStore.trash(folder, in: recordings)
                self.refreshProjects()
                self.showToast("项目「\(project.name)」已移到废纸篓", icon: "trash")
            } catch {
                self.production.open(saved, folder: folder)
                self.refreshProjects()
                self.showToast("删除失败，项目已保留：\(error.localizedDescription)", icon: "exclamationmark.triangle")
            }
        }
    }
}
