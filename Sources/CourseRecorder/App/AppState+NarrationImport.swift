import Foundation
import AppKit
import UniformTypeIdentifiers

extension AppState {
    func importNarration() {
        guard workMode == .production, recState == .idle, !projectActionInProgress, narrationImportProgress == nil,
              exportProgress == nil, !aiProduction.locksProject, !production.isFinishingTakes else { return }
        guard production.project != nil, let folder = production.folder else {
            showToast("请先新建或打开一个项目，再导入口播视频", icon: "folder")
            return
        }
        let token = UUID()
        narrationImportID = token
        narrationImportProgress = 0
        narrationImportStatus = "正在保存当前素材…"
        production.finishOperations { [weak self] in
            guard let self, self.narrationImportID == token, self.narrationImportProgress != nil,
                  self.production.folder == folder, let snapshot = self.production.project else { return }
            let panel = NSOpenPanel()
            panel.title = "导入口播视频"
            panel.message = "选择带口播声音的 MP4、MOV 或 M4V。将保存项目副本，等比适配当前输出画幅；完整保留画面，不同比例补黑边。"
            panel.allowedContentTypes = [UTType.mpeg4Movie, UTType.quickTimeMovie, UTType(filenameExtension: "m4v")!]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.canChooseFiles = true
            guard panel.runModal() == .OK, let source = panel.url else {
                self.narrationImportProgress = nil
                self.narrationImportStatus = ""
                return
            }
            let canvas = self.settings.recording.outputSize
            if snapshot.hasNarration || !snapshot.cues.isEmpty || !snapshot.takes.isEmpty {
                let alert = NSAlert()
                alert.messageText = "导入并替换当前口播？"
                alert.informativeText = "成功后将清空当前时间线，重新配操作；旧口播、演示素材和时间线备份会保留。视频将适配为 \(Int(canvas.width))×\(Int(canvas.height))，完整保留画面，不同比例补黑边。取消或导入失败不改变当前项目。"
                alert.addButton(withTitle: "导入并替换")
                alert.addButton(withTitle: "取消")
                guard alert.runModal() == .alertFirstButtonReturn else {
                    self.narrationImportProgress = nil
                    self.narrationImportStatus = ""
                    return
                }
            }
            guard self.narrationImportID == token, self.production.folder == folder,
                  self.production.project == snapshot else {
                self.narrationImportProgress = nil
                self.narrationImportStatus = ""
                return
            }
            let importer = NarrationImporter()
            guard self.pausePreviewForNarrationImport(token: token) else {
                self.narrationImportProgress = nil
                self.narrationImportStatus = ""
                return
            }
            self.narrationImporter = importer
            self.narrationImportTask = Task { @MainActor [weak self] in
                guard let self else { return }
                defer {
                    if self.narrationImportID == token {
                        self.narrationImportProgress = nil
                        self.narrationImportStatus = ""
                        self.narrationImporter = nil
                        self.narrationImportTask = nil
                    }
                    self.resumePreviewAfterNarrationImport(token: token)
                }
                do {
                    let imported = try await importer.importVideo(from: source, projectFolder: folder, canvasSize: canvas) { [weak self] value, status in
                        DispatchQueue.main.async {
                            guard let self, self.narrationImportID == token,
                                  self.narrationImportTask?.isCancelled == false else { return }
                            self.narrationImportProgress = value
                            self.narrationImportStatus = status
                        }
                    }
                    defer { imported.discard() }
                    try Task.checkCancellation()
                    guard self.narrationImportID == token, self.production.folder == folder,
                          self.production.project == snapshot else {
                        throw NarrationImporter.ImportError(message: "项目在导入期间发生变化，已取消替换，请重新导入")
                    }
                    self.narrationImportProgress = 0.99
                    self.narrationImportStatus = "正在保存项目…"
                    let identity = UUID().uuidString
                    let backup = folder.appendingPathComponent("导入前备份", isDirectory: true).appendingPathComponent(identity, isDirectory: true)
                    try ProjectStore.save(snapshot, to: backup)
                    let filename = "口播-导入-\(identity).mp4"
                    let destination = folder.appendingPathComponent(filename)
                    try FileManager.default.moveItem(at: imported.url, to: destination)
                    var replacement = snapshot
                    replacement.narrationFile = filename
                    replacement.narrationDuration = imported.duration
                    replacement.narrationIsImported = true
                    replacement.narrationEditBackup = nil
                    replacement.subtitleFile = nil
                    replacement.cues = []
                    replacement.takes = []
                    replacement.cursor = []
                    replacement.clicks = []
                    replacement.outputFile = nil
                    do {
                        // The atomic project write is the commit point; all old media remains untouched.
                        try ProjectStore.save(replacement, to: folder)
                    } catch {
                        try? FileManager.default.removeItem(at: destination)
                        throw error
                    }
                    // close/open flushes current metadata, so install the committed value before reopening.
                    self.production.update(replacement)
                    self.production.open(replacement, folder: folder)
                    self.selectScene(.camera)
                    self.refreshProjects()
                    self.showToast("口播已导入（\(formatTimecode(imported.duration))），可以配操作或生成 AI 时间线", icon: "checkmark.circle")
                } catch is CancellationError {
                    if self.narrationImportID == token { self.showToast("已取消导入，原项目保持不变", icon: "xmark.circle") }
                } catch {
                    if self.narrationImportID == token {
                        let message = "导入失败，原项目保持不变：\(error.localizedDescription)"
                        self.production.reportError(message)
                        self.showToast(message, icon: "exclamationmark.triangle")
                    }
                }
            }
        }
    }

    func cancelNarrationImport() {
        guard narrationImportProgress != nil else { return }
        if narrationImportTask == nil {
            narrationImportID = UUID()
            narrationImportProgress = nil
            narrationImportStatus = ""
        } else {
            narrationImportStatus = "正在取消并清理本次导入…"
            narrationImportTask?.cancel()
            narrationImporter?.cancel()
        }
    }
}
