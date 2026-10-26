import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {
    func setProjectBGMEnabled(_ enabled: Bool) {
        guard canManageProject, var project = production.project, let folder = production.folder else { return }
        project.includeBGM = enabled
        saveProjectMusicChoice(project, folder: folder)
    }

    func useDefaultProjectBGM() {
        guard canManageProject, var project = production.project, let folder = production.folder else { return }
        project.bgmFile = nil
        project.includeBGM = true
        saveProjectMusicChoice(project, folder: folder)
    }

    private func saveProjectMusicChoice(_ project: CourseProject, folder: URL) {
        do {
            try ProjectStore.save(project, to: folder)
            production.update(project)
        } catch {
            production.reportError("无法保存背景音乐选择：\(error.localizedDescription)")
            showToast("无法保存背景音乐选择：\(error.localizedDescription)", icon: "exclamationmark.triangle")
        }
    }

    func chooseProjectBGM() {
        guard canManageProject, let snapshot = production.project, let folder = production.folder else { return }
        projectActionInProgress = true
        let panel = NSOpenPanel()
        panel.title = "选择项目背景音乐"
        panel.message = "选择一首背景音乐，将保存独立副本到当前项目。原音乐文件不改动。"
        panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url,
              production.project == snapshot, production.folder == folder else {
            projectActionInProgress = false
            return
        }
        beginProjectMusicImport(from: url, snapshot: snapshot, folder: folder)
    }

    func selectProjectBGM(path: String) {
        guard canManageProject, let snapshot = production.project, let folder = production.folder else { return }
        projectActionInProgress = true
        let source = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        beginProjectMusicImport(from: source, snapshot: snapshot, folder: folder)
    }

    private func beginProjectMusicImport(from source: URL, snapshot: CourseProject, folder: URL) {
        let (token, cancellation) = projectMusicImport.begin()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = Result { try ProjectMusicFiles.importFile(from: source, projectFolder: folder, cancellation: cancellation) }
            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    if case .success(let imported) = result { imported.discard() }
                    return
                }
                guard self.projectMusicImport.operationID == token else {
                    if case .success(let imported) = result { imported.discard() }
                    return
                }
                defer {
                    if self.projectMusicImport.operationID == token {
                        self.projectMusicImport.finish(token)
                        self.projectActionInProgress = false
                    }
                }
                var committed = false
                if case .success(let imported) = result {
                    defer { if !committed { imported.discard() } }
                    do {
                        try cancellation.check()
                        guard self.projectMusicImport.operationID == token, self.production.project == snapshot,
                              self.production.folder == folder else {
                            throw ProjectMusicFiles.MusicError(message: "项目在导入期间发生变化，请重新选择背景音乐。")
                        }
                        var project = snapshot
                        project.bgmFile = imported.relativePath
                        project.includeBGM = true
                        // Saving metadata is the commit point; previous music copies remain available.
                        try ProjectStore.save(project, to: folder)
                        committed = true
                        self.production.update(project)
                        self.showToast("已选择背景音乐「\(source.deletingPathExtension().lastPathComponent)」", icon: "music.note")
                    } catch is CancellationError {
                        self.showToast("已取消导入，原音乐选择保持不变", icon: "xmark.circle")
                    } catch {
                        self.production.reportError("音乐导入失败：\(error.localizedDescription)")
                        self.showToast("音乐导入失败：\(error.localizedDescription)", icon: "exclamationmark.triangle")
                    }
                } else if case .failure(let error) = result {
                    if error is CancellationError {
                        self.showToast("已取消导入，原音乐选择保持不变", icon: "xmark.circle")
                    } else {
                        self.production.reportError("音乐导入失败：\(error.localizedDescription)")
                        self.showToast("音乐导入失败：\(error.localizedDescription)", icon: "exclamationmark.triangle")
                    }
                }
            }
        }
    }

    func cancelProjectMusicImport() {
        projectMusicImport.cancel()
    }
}
