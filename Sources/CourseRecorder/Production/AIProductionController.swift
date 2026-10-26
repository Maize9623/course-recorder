import Foundation
import Combine

/// Owns a proposed timeline until the user explicitly adopts it.
final class AIProductionController: ObservableObject {
    let connection = CodexConnection()
    private var connectionObserver: AnyCancellable?
    @Published private(set) var isBusy = false
    @Published private(set) var progress = 0.0
    @Published private(set) var status = ""
    @Published private(set) var elapsed = 0
    @Published private(set) var error: String?
    @Published private(set) var draft: AIShotDraft?
    private var task: Task<Void, Never>?
    private var transcriber: NarrationTranscriber?
    private var planner: AIShotPlanner?
    private var timer: Timer?
    private var generation = UUID()
    private var original: CourseProject?
    private var originalFolder: URL?
    private var originalSplit: SplitContent?

    var hasDraft: Bool { draft != nil }
    var locksProject: Bool { isBusy || hasDraft }

    init() {
        connectionObserver = connection.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    func generate(for app: AppState) {
        guard !locksProject, app.recState == .idle, app.exportProgress == nil, app.narrationImportProgress == nil, !app.projectActionInProgress,
              app.production.isLoaded, app.production.project?.hasNarration == true else { return }
        guard connection.isChatGPT, !connection.isBusy else {
            error = "请先在「连接 ChatGPT / Codex」中完成登录并检查连接，再生成时间线。"
            if !connection.isBusy { connection.refresh() }
            return
        }
        isBusy = true
        error = nil
        progress = 0
        status = "正在保存演示素材…"
        elapsed = 0
        let started = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.elapsed = Int(Date().timeIntervalSince(started))
        }
        let token = UUID()
        generation = token
        app.production.finishOperations { [weak self, weak app] in
            guard let self, let app, self.generation == token, self.isBusy,
                  let project = app.production.project, let folder = app.production.folder,
                  let narration = project.narrationFile else { return }
            self.original = project
            self.originalFolder = folder
            self.originalSplit = app.settings.split.content
            let transcriber = NarrationTranscriber()
            let planner = AIShotPlanner()
            self.transcriber = transcriber
            self.planner = planner
            self.task = Task { @MainActor [weak self, weak app] in
                guard let self, let app else { return }
                do {
                    let transcript = try await transcriber.transcribe(
                        url: folder.appendingPathComponent(narration), projectFolder: folder,
                        duration: project.narrationDuration
                    ) { [weak self] value, message in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token else { return }
                            self.progress = value * 0.6
                            self.status = message
                        }
                    }
                    try Task.checkCancellation()
                    self.progress = 0.65
                    let result = try await planner.generate(
                        project: project,
                        transcript: transcript.segments.map { AITranscriptSegment(time: $0.time, duration: $0.duration, text: $0.text) },
                        splitContent: app.settings.split.content
                    ) { [weak self] message in
                        DispatchQueue.main.async {
                            guard let self, self.generation == token else { return }
                            self.status = message
                        }
                    }
                    try Task.checkCancellation()
                    guard self.generation == token else { return }
                    guard app.production.folder == folder, app.production.project == project,
                          app.settings.split.content == self.originalSplit else {
                        throw AIProductionError("生成期间项目发生变化，请重新生成；原时间线没有修改。")
                    }
                    self.present(result, project: project, folder: folder, splitContent: app.settings.split.content)
                    self.progress = 1
                    self.status = "初稿已生成，请预览后采纳"
                    self.finish()
                } catch {
                    guard self.generation == token else { return }
                    self.error = error is CancellationError ? nil : error.localizedDescription
                    self.status = error is CancellationError ? "已取消" : "生成未完成，原时间线没有修改"
                    self.finish()
                }
            }
        }
    }

    func cancel() {
        if connection.isBusy { connection.cancel() }
        generation = UUID()
        task?.cancel()
        transcriber?.cancel()
        planner?.cancel()
        status = "已取消，原时间线没有修改"
        finish()
    }

    /// Presents a validated draft; project data is unchanged until adoption.
    func present(_ result: AIShotDraft, project: CourseProject, folder: URL, splitContent: SplitContent) {
        original = project
        originalFolder = folder
        originalSplit = splitContent
        draft = result
    }

    func preview(in app: AppState, at time: Double = 0) {
        guard let draft, !isBusy, app.production.folder == originalFolder else { return }
        app.production.review(cues: draft.cues, at: time)
    }

    func discard(in app: AppState) {
        app.production.stopReview()
        draft = nil
        original = nil
        originalFolder = nil
        status = "已放弃初稿，原时间线没有修改"
        error = nil
    }

    func adopt(in app: AppState) {
        guard let draft, let original, let folder = originalFolder,
              app.production.folder == folder, app.production.project == original,
              app.settings.split.content == originalSplit, app.recState == .idle,
              app.exportProgress == nil else {
            error = "项目或分屏设置已变化，请放弃初稿后重新生成。"
            return
        }
        app.production.stopReview()
        var adopted = original
        adopted.cues = draft.cues
        adopted.outputFile = nil
        do {
            // Save a recoverable copy before replacing the timeline.
            let backup = folder.appendingPathComponent("时间线备份", isDirectory: true)
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try ProjectStore.save(original, to: backup)
            try ProjectStore.save(adopted, to: folder)
            app.production.update(adopted)
            self.draft = nil
            self.original = nil
            originalFolder = nil
            error = nil
            status = "已采纳 \(adopted.cues.count) 条切换，可预览或继续手动配操作"
            app.production.review(cues: adopted.cues)
        } catch {
            self.error = "保存时间线失败：\(error.localizedDescription)"
        }
    }

    private func finish() {
        isBusy = false
        timer?.invalidate()
        timer = nil
        task = nil
        transcriber = nil
        planner = nil
    }
}

private struct AIProductionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

extension Cue.Action {
    var reviewTitle: String {
        switch self {
        case .scene(let value): return "镜头 → \(value.title)"
        case .slide(let index): return "幻灯片 → 第 \(index + 1) 页"
        case .demoSource(let source): return "演示来源 → \(source.id)"
        case .slidesSource: return "讲解来源 → 幻灯片"
        case .pip(let visible): return visible ? "显示人像小窗" : "隐藏人像小窗"
        case .zoom(let on): return on ? "开启跟随放大" : "关闭跟随放大"
        case .lowerThird: return "显示人名条"
        }
    }
}
