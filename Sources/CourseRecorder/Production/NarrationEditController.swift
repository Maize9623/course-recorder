import Foundation
import Combine
import AppKit
import AVKit

/// Reviews conservative deletions, renders a new media version, and preserves the source project.
final class NarrationEditController: ObservableObject {
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var error: String?
    @Published private(set) var draft: NarrationEditDraft?
    @Published private(set) var selected: Set<UUID> = []
    private var original: CourseProject?
    private var folder: URL?
    private var transcript: NarrationTranscript?
    private var task: Task<Void, Never>?
    private var transcriber: NarrationTranscriber?
    private var planner: AINarrationEditPlanner?
    private var editor: NarrationEditor?
    private var prepared: NarrationEditor.PreparedVideo?
    private var preparedCuts: [NarrationCut] = []
    private var generation = UUID()
    private var sourceSize: Int?
    private var sourceModified: Date?
    private let preview = NarrationEditPreview()

    var cuts: [NarrationCut] { draft?.cuts.filter { selected.contains($0.id) } ?? [] }
    var removedDuration: Double { cuts.reduce(0) { $0 + $1.end - $1.start } }

    func generate(in app: AppState, subtitlesOnly: Bool = false) {
        guard !isBusy, draft == nil, app.recState == .idle, app.exportProgress == nil,
              app.narrationImportProgress == nil, !app.projectActionInProgress, !app.aiProduction.locksProject,
              app.production.isLoaded else { return }
        if !subtitlesOnly && (!app.aiProduction.connection.isChatGPT || app.aiProduction.connection.isBusy) {
            error = "请先在本页顶部连接 ChatGPT / Codex，再生成剪辑建议。"
            return
        }
        app.projectActionInProgress = true
        isBusy = true
        error = nil
        progress = 0
        status = "正在保存当前素材…"
        let token = UUID()
        generation = token
        app.production.finishOperations { [weak self, weak app] in
            guard let self, let app, self.generation == token, self.isBusy,
                  let project = app.production.project, let folder = app.production.folder,
                  let file = project.narrationFile else { return }
            self.original = project
            self.folder = folder
            let recognizer = NarrationTranscriber()
            let planner = AINarrationEditPlanner()
            self.transcriber = recognizer
            self.planner = planner
            self.task = Task { @MainActor [weak self, weak app] in
                guard let self, let app else { return }
                do {
                    let source = try NarrationEditStore.localFile(file, in: folder)
                    let identity = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                    self.sourceSize = identity.fileSize
                    self.sourceModified = identity.contentModificationDate
                    let text = try await recognizer.transcribe(url: source, projectFolder: folder,
                                                               duration: project.narrationDuration) { [weak self] value, message in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token else { return }
                            self.progress = value * 0.6
                            self.status = message
                        }
                    }
                    try Task.checkCancellation()
                    self.transcript = text
                    let result: NarrationEditDraft
                    if subtitlesOnly {
                        result = NarrationEditDraft(cuts: [], summary: "文字稿已准备好，将为完整口播生成字幕。", warnings: [])
                    } else {
                        result = try await planner.generate(transcript: text) { [weak self] message in
                            DispatchQueue.main.async {
                                guard let self, self.generation == token else { return }
                                self.progress = 0.7
                                self.status = message
                            }
                        }
                    }
                    try Task.checkCancellation()
                    try self.checkSnapshot(in: app)
                    self.draft = result
                    // Recognition gaps are not proof of silence; review them before selecting.
                    self.selected = Set(result.cuts.filter { $0.text != "（较长停顿）" }.map(\.id))
                    self.status = subtitlesOnly ? "可以保存 SRT 字幕，口播不做剪切" : "请试听删除建议；正常停顿默认保留"
                    self.progress = 1
                    self.finishWork()
                } catch {
                    guard self.generation == token else { return }
                    self.error = error is CancellationError ? nil : error.localizedDescription
                    self.status = error is CancellationError ? "已取消，原口播未修改" : "未生成剪辑建议，原口播未修改"
                    self.release(in: app)
                }
            }
        }
    }

    func select(_ cut: NarrationCut, enabled: Bool) {
        guard !isBusy else { return }
        if enabled { selected.insert(cut.id) } else { selected.remove(cut.id) }
        clearPreview()
    }

    func audition(_ cut: NarrationCut, in app: AppState) {
        do {
            try checkSnapshot(in: app)
            guard let folder, let file = original?.narrationFile else { return }
            preview.show(try NarrationEditStore.localFile(file, in: folder), title: "试听原片段 · \(cut.text)",
                         start: max(0, cut.start - 0.8), end: min(original!.narrationDuration, cut.end + 0.8))
        } catch { self.error = error.localizedDescription }
    }

    func renderPreview(in app: AppState) { render(in: app, adopt: false) }
    func adopt(in app: AppState) {
        guard !isBusy else { return }
        if !cuts.isEmpty, let project = original, !project.cues.isEmpty || !project.takes.isEmpty {
            let alert = NSAlert()
            alert.messageText = "应用剪辑并重新配操作？"
            alert.informativeText = "剪辑后口播时长会改变，当前镜头、演示和鼠标时间线需要重新配。原口播、演示素材和项目备份都会保留，可恢复剪辑前版本。"
            alert.addButton(withTitle: "应用剪辑")
            alert.addButton(withTitle: "取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        render(in: app, adopt: true)
    }

    private func render(in app: AppState, adopt: Bool) {
        guard !isBusy, draft != nil, let original, let folder, let transcript else { return }
        do { try checkSnapshot(in: app) } catch { self.error = error.localizedDescription; return }
        preview.close()
        let selectedCuts = cuts
        let worker = NarrationEditor()
        editor = worker
        isBusy = true
        progress = 0
        error = nil
        status = "正在准备剪辑后的口播与字幕…"
        let token = generation
        task = Task { @MainActor [weak self, weak app] in
            guard let self, let app else { return }
            do {
                let subtitles = try NarrationSubtitles.prepare(transcript: transcript, cuts: selectedCuts)
                let source = try NarrationEditStore.localFile(original.narrationFile!, in: folder)
                if !selectedCuts.isEmpty, self.prepared == nil || self.preparedCuts != selectedCuts {
                    self.clearPreview()
                    let rendered = try await worker.edit(source: source, projectFolder: folder,
                                                         duration: original.narrationDuration, cuts: selectedCuts) { [weak self] value, message in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token else { return }
                            self.progress = value
                            self.status = message
                        }
                    }
                    if Task.isCancelled { rendered.discard(); throw CancellationError() }
                    self.prepared = rendered
                    self.preparedCuts = selectedCuts
                }
                try Task.checkCancellation()
                try self.checkSnapshot(in: app)
                if adopt {
                    let changed = try NarrationEditStore.apply(original: original, folder: folder,
                                                               editedURL: self.prepared?.url,
                                                               duration: subtitles.transcript.duration,
                                                               srt: subtitles.srt, cuts: selectedCuts)
                    // Cache failures never roll back an already committed, playable narration version.
                    var cacheWarning = ""
                    do {
                        try NarrationTranscriber.saveCache(transcript: subtitles.transcript,
                                                         url: folder.appendingPathComponent(changed.narrationFile!), projectFolder: folder)
                    } catch { cacheWarning = "；文字稿缓存未保存，配镜头时会重新识别" }
                    app.production.update(changed)
                    if !selectedCuts.isEmpty { app.production.open(changed, folder: folder) }
                    app.refreshProjects()
                    self.status = selectedCuts.isEmpty ? "SRT 字幕已保存，口播保持完整" : "剪辑和字幕已保存，可以开始配操作"
                    self.status += cacheWarning
                    app.showToast(self.status, icon: "checkmark.circle")
                    self.release(in: app)
                } else {
                    self.preview.show(self.prepared?.url ?? source, title: "剪后预览 · 尚未应用", start: 0,
                                      end: subtitles.transcript.duration)
                    self.status = "正在预览剪后版本；原口播未修改"
                    self.finishWork()
                }
            } catch {
                guard self.generation == token else { return }
                self.error = error is CancellationError ? nil : error.localizedDescription
                self.status = error is CancellationError ? "已取消处理，原口播未修改" : "处理未完成，原口播未修改"
                self.clearPreview()
                self.finishWork()
            }
        }
    }

    func cancel(in app: AppState) {
        guard isBusy || draft != nil else { return }
        preview.close()
        if isBusy, let task {
            status = "正在取消并清理本次处理…"
            task.cancel()
            transcriber?.cancel()
            planner?.cancel()
            editor?.cancel()
        } else {
            generation = UUID()
            status = "已放弃，原口播未修改"
            release(in: app)
        }
    }

    func restore(in app: AppState) {
        guard app.canManageProject, let project = app.production.project,
              project.narrationEditBackup != nil, let folder = app.production.folder else { return }
        app.projectActionInProgress = true
        defer { app.projectActionInProgress = false }
        let alert = NSAlert()
        alert.messageText = "恢复上次剪辑前的项目？"
        alert.informativeText = "恢复当时的口播、时间线、演示素材引用和字幕设置。当前版本也会另存备份；现有媒体文件不会删除。"
        alert.addButton(withTitle: "恢复")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            guard app.production.project == project, app.production.folder == folder else {
                throw NarrationEditStore.Failure(message: "项目已切换，请重试。")
            }
            app.production.flushSave()
            let restored = try NarrationEditStore.restore(current: project, folder: folder)
            app.production.update(restored)
            app.production.open(restored, folder: folder)
            status = "已恢复剪辑前版本"
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func checkSnapshot(in app: AppState) throws {
        guard let original, let folder, app.production.folder == folder, app.production.project == original,
              let file = original.narrationFile else { throw NarrationEditStore.Failure(message: "项目已变化，请放弃后重新生成。") }
        var source = try NarrationEditStore.localFile(file, in: folder)
        source.removeAllCachedResourceValues()
        let values = try source.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        guard values.fileSize == sourceSize, values.contentModificationDate == sourceModified else {
            throw NarrationEditStore.Failure(message: "口播文件在处理期间发生了变化，原项目没有替换。")
        }
    }

    private func clearPreview() {
        preview.close()
        prepared?.discard()
        prepared = nil
        preparedCuts = []
    }

    private func finishWork() {
        generation = UUID()
        isBusy = false
        task = nil
        transcriber = nil
        planner = nil
        editor = nil
    }

    private func release(in app: AppState) {
        clearPreview()
        draft = nil
        transcript = nil
        original = nil
        folder = nil
        selected = []
        finishWork()
        app.projectActionInProgress = false
    }
}

/// An independent player auditions source or temporary media without recording production operations.
private final class NarrationEditPreview: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var player: AVPlayer?
    private var token = UUID()

    func show(_ url: URL, title: String, start: Double, end: Double) {
        close()
        let current = UUID()
        token = current
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = CMTime(seconds: end, preferredTimescale: 600)
        let player = AVPlayer(playerItem: item)
        self.player = player
        let view = AVPlayerView(frame: NSRect(x: 0, y: 0, width: 800, height: 480))
        view.player = player
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = view
        window.isReleasedWhenClosed = false
        window.delegate = self
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            DispatchQueue.main.async {
                if finished, self?.token == current { self?.player?.play() }
            }
        }
    }

    func close() {
        token = UUID()
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        window?.orderOut(nil)
        window?.delegate = nil
        window?.close()
        window = nil
    }

    func windowWillClose(_ notification: Notification) { close() }
}
