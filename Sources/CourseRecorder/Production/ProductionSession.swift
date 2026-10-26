import Foundation
import AVFoundation
import AppKit
import CoreGraphics

/// The "配操作" pass of a narration-first course: plays the narration as the presenter while the user operates,
/// and records the scene changes as cues and the demo screen as takes, both on the narration's timeline.
final class ProductionSession: ObservableObject {
    @Published private(set) var project: CourseProject?
    @Published private(set) var folder: URL?
    @Published private(set) var time: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var isPlaying = false
    /// The narration is loaded and its frames flow into the preview.
    @Published private(set) var isLoaded = false
    @Published private(set) var recordingTake = false
    @Published private(set) var isFinishingTakes = false
    @Published private(set) var isReviewing = false
    @Published private(set) var error: String?
    var onError: ((String) -> Void)?

    private let store: FrameStore
    private let processor: CameraProcessor
    private let screens: ScreenCaptureManager
    private let player = NarrationPlayer()
    private let queue = DispatchQueue(label: "production.tick", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var previewSuspended = false

    /// Supplied by the app: the demo source selected right now.
    var demoSource: () -> SourceRef? = { nil }
    /// Supplied by the app: encoder bitrate for a screen capture of this size.
    var takeBitrate: (CGSize) -> Int = { _ in 16_000_000 }
    /// Called on the main thread when playback starts, so the app can pin the current state as cues.
    var onPlayStarted: (() -> Void)?
    var editingAllowed: () -> Bool = { true }
    /// Main-thread timeline preview updates. The final flag requests a full state rebuild after seeking.
    var onReviewTime: ((Double, [Cue], Bool) -> Void)?

    // Take recording and cursor sampling: only touched on `queue`.
    private var takeRecorder: Recorder?
    private var take: Take?
    private var lastScreenFrame: ScreenFrame?
    private var lastCursorSample: Double = -1
    private var cursorBuffer: [TimedPoint] = []
    private var takeNumber = 0
    private var pendingTakes: [Take] = []
    private var pendingCursor: [TimedPoint] = []
    private let takeFinishes = DispatchGroup()
    private var finishingCount = 0
    private var reviewCues: [Cue]?
    private var reviewProject: CourseProject?
    private var reviewReader: (take: Take, reader: VideoFrameReader)?
    private var reviewLastTime = -1.0
    private var generation = UUID()
    private var reviewRequest = UUID()
    private var lastPlaying = false
    private var lastPublish: Double = 0

    private var saveWork: DispatchWorkItem?

    init(store: FrameStore, processor: CameraProcessor, screens: ScreenCaptureManager) {
        self.store = store
        self.processor = processor
        self.screens = screens
        player.onEnded = { [weak self] in self?.pause() }
    }

    var hasProject: Bool { project != nil }
    var isPreviewSuspended: Bool { previewSuspended }

    // MARK: - Project

    func open(_ project: CourseProject, folder: URL) {
        close()
        error = nil
        self.project = project
        self.folder = folder
        // File numbers are not counts: trimming a pass can leave gaps and old files on disk.
        takeNumber = project.takes.compactMap { Int(URL(fileURLWithPath: $0.file).deletingPathExtension().lastPathComponent.replacingOccurrences(of: "take-", with: "")) }.max() ?? 0
        let token = generation
        guard project.hasNarration, let file = project.narrationFile else { return }
        player.load(folder.appendingPathComponent(file)) { [weak self] ok in
            guard let self, ok, self.folder == folder, self.generation == token else { return }
            self.duration = self.player.duration
            self.isLoaded = true
            self.startTimer()
            self.player.seek(to: 0)
        }
    }

    func close() {
        if isLoaded { pause() }
        stopTimer()
        drainPendingChanges()
        flushSave()
        player.unload()
        store.setCamera(nil)
        isLoaded = false
        isPlaying = false
        time = 0
        duration = 0
        project = nil
        folder = nil
        generation = UUID()
        isReviewing = false
        queue.sync { resetReview() }
    }

    func update(_ p: CourseProject) {
        project = p
        scheduleSave()
    }

    /// Keeps recording failures visible until the user opens another project.
    func reportError(_ message: String) {
        error = message
        onError?(message)
    }

    /// Stops standing in for the camera (before the narration is re-recorded); the project stays open.
    func unloadNarration() {
        if isLoaded { pause() }
        stopTimer()
        drainPendingChanges()
        flushSave()
        player.unload()
        store.setCamera(nil)
        isLoaded = false
        isPlaying = false
        time = 0
        duration = 0
        isReviewing = false
        queue.sync { resetReview() }
    }

    /// The narration was (re)recorded: forget the old timeline and load the new file.
    func setNarration(file: String, duration: Double) {
        guard var p = project, let folder else { return }
        for t in p.takes { try? FileManager.default.removeItem(at: folder.appendingPathComponent(t.file)) }
        p.narrationFile = file
        p.narrationDuration = duration
        p.narrationIsImported = false
        p.narrationEditBackup = nil
        p.subtitleFile = nil
        p.cues = []
        p.takes = []
        p.cursor = []
        p.clicks = []
        p.outputFile = nil
        project = p
        flushSave()
        open(p, folder: folder)
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flushSave() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        guard let project, let folder else { return }
        try? ProjectStore.save(project, to: folder)
    }

    // MARK: - Playback

    var currentTime: Double { isLoaded ? player.currentTime : 0 }

    func play() {
        guard isLoaded, !isFinishingTakes, isReviewing || editingAllowed() else { return }
        if player.currentTime >= duration - 0.05 {
            player.seek(to: 0) { [weak self] in self?.startPlaying() }
        } else {
            startPlaying()
        }
    }

    private func startPlaying() {
        if !isReviewing { onPlayStarted?() }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
        queue.async { [weak self] in
            self?.closeTake()
            self?.flushCursor()
            DispatchQueue.main.async { [weak self] in self?.drainPendingChanges() }
        }
    }

    /// Pauses operations and waits until the last MP4 has its index and metadata saved.
    func finishOperations(completion: @escaping () -> Void) {
        pause()
        isFinishingTakes = true
        queue.async { [weak self] in
            guard let self else { return }
            self.takeFinishes.notify(queue: .main) {
                self.drainPendingChanges()
                self.flushSave()
                self.isFinishingTakes = self.finishingCount > 0
                completion()
            }
        }
    }

    func review(cues: [Cue], at time: Double = 0) {
        guard isLoaded else { return }
        let request = UUID()
        reviewRequest = request
        let token = generation
        finishOperations { [weak self] in
            guard let self, self.isLoaded, self.generation == token, self.reviewRequest == request else { return }
            self.isReviewing = true
            self.queue.sync {
                self.resetReview()
                self.reviewCues = cues.sorted { $0.time < $1.time }
                self.reviewProject = self.project
                for take in self.project?.takes ?? [] { self.store.removeScreen(take.source) }
            }
            self.seek(to: time)
        }
    }

    func stopReview() {
        reviewRequest = UUID()
        pause()
        isReviewing = false
        queue.sync { resetReview() }
    }

    private func resetReview() {
        reviewReader?.reader.cancel()
        reviewReader = nil
        reviewCues = nil
        reviewProject = nil
        reviewLastTime = -1
    }

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to t: Double) {
        guard isLoaded else { return }
        let resume = isPlaying
        if resume { pause() }
        let target = max(0, min(duration, t))
        time = target
        player.seek(to: target) { [weak self] in
            guard let self else { return }
            if self.isReviewing {
                self.queue.sync {
                    self.reviewReader?.reader.cancel()
                    self.reviewReader = nil
                    self.reviewLastTime = -1
                }
            }
            if resume { self.play() }
        }
    }

    // MARK: - Recording the timeline

    /// Pins a state change at the current narration time.
    func record(_ action: Cue.Action) {
        guard isLoaded, !isReviewing, editingAllowed(), var p = project else { return }
        p.add(action, at: player.currentTime)
        update(p)
    }

    func recordClick(_ e: ClickEvent) {
        guard isLoaded, isPlaying, !isReviewing, editingAllowed(), var p = project, let ref = demoSource(),
              let n = Self.normalized(e.point, on: ref, screens: screens) else { return }
        p.clicks.append(TimedPoint(t: player.currentTime, x: n.x, y: n.y))
        p.clicks.sort { $0.t < $1.t }
        update(p)
    }

    /// Everything recorded after the current position is dropped, so the pass can be redone from here.
    func clearAfterCurrentTime() {
        guard isLoaded, !isReviewing, editingAllowed() else { return }
        let t = player.currentTime + 0.01
        finishOperations { [weak self] in self?.clear(after: t) }
    }

    private func clear(after t: Double) {
        guard var p = project, let folder else { return }
        p.cues.removeAll { $0.time > t }
        p.cursor.removeAll { $0.t > t }
        p.clicks.removeAll { $0.t > t }
        for take in p.takes where take.start > t {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(take.file))
        }
        p.takes.removeAll { $0.start > t }
        for i in p.takes.indices where p.takes[i].end > t { p.takes[i].end = t }
        p.outputFile = nil
        update(p)
    }

    func deleteAllTakes() {
        guard !isReviewing, editingAllowed() else { return }
        finishOperations { [weak self] in self?.removeAllTakes() }
    }

    private func removeAllTakes() {
        guard var p = project, let folder else { return }
        for take in p.takes { try? FileManager.default.removeItem(at: folder.appendingPathComponent(take.file)) }
        p.takes = []
        update(p)
    }

    /// Total size of the recorded takes.
    var takeBytes: Int64 {
        guard let project, let folder else { return 0 }
        return project.takes.reduce(0) { sum, t in
            sum + (((try? FileManager.default.attributesOfItem(atPath: folder.appendingPathComponent(t.file).path))?[.size] as? NSNumber)?.int64Value ?? 0)
        }
    }

    // MARK: - Tick (30 fps, on `queue`)

    /// Preserve the paused narration and playhead while an import uses the video hardware.
    func setPreviewSuspended(_ suspended: Bool) {
        guard previewSuspended != suspended else { return }
        previewSuspended = suspended
        if suspended { stopTimer() }
        else if isLoaded { startTimer() }
    }

    private func startTimer() {
        stopTimer()
        guard !previewSuspended else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: 1.0 / 30, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        queue.sync {
            closeTake()
            flushCursor()
        }
    }

    private func tick() {
        if let pb = player.pullFrame(), let frame = processor.process(pb, hostTime: CACurrentMediaTime()) {
            store.setCamera(frame)
        }
        let t = player.currentTime
        let playing = player.isPlaying
        if let cues = reviewCues {
            let reset = reviewLastTime < 0 || t < reviewLastTime
            if let take = reviewProject?.take(at: t), let folder {
                if reviewReader?.take.id != take.id || reset {
                    reviewReader = VideoFrameReader(url: folder.appendingPathComponent(take.file), from: max(0, t - take.start)).map { (take, $0) }
                }
                if let pb = reviewReader?.reader.frame(at: t - take.start) {
                    store.setScreen(ScreenFrame(pixelBuffer: pb, contentRect: take.contentRect, hostTime: CACurrentMediaTime()), for: take.source)
                }
            } else {
                if let previous = reviewReader?.take { store.removeScreen(previous.source) }
                reviewReader?.reader.cancel()
                reviewReader = nil
            }
            if reset || abs(t - reviewLastTime) > 0.001 {
                let token = generation
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.generation == token, self.isReviewing else { return }
                    self.onReviewTime?(t, cues, reset)
                }
            }
            reviewLastTime = t
        } else if playing, let ref = demoSource() {
            if let f = store.screen(ref), f !== lastScreenFrame {
                lastScreenFrame = f
                recordTakeFrame(f, source: ref, at: t)
            }
            if t - lastCursorSample >= 0.1 || t < lastCursorSample {
                lastCursorSample = t
                if let n = Self.normalized(CGEvent(source: nil)?.location ?? .zero, on: ref, screens: screens) {
                    cursorBuffer.append(TimedPoint(t: t, x: n.x, y: n.y))
                }
            }
        } else if !playing, takeRecorder != nil {
            closeTake()
        }
        let now = CACurrentMediaTime()
        if playing != lastPlaying || now - lastPublish > 0.1 {
            lastPlaying = playing
            lastPublish = now
            let token = generation
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.drainPendingChanges()
                self.time = t
                if self.isPlaying != playing { self.isPlaying = playing }
            }
        }
    }

    private func recordTakeFrame(_ f: ScreenFrame, source: SourceRef, at t: Double) {
        let w = CVPixelBufferGetWidth(f.pixelBuffer), h = CVPixelBufferGetHeight(f.pixelBuffer)
        if let cur = take, cur.source != source || cur.width != w || cur.height != h
            || abs(cur.contentRect.width - f.contentRect.width) > 2 || abs(cur.contentRect.height - f.contentRect.height) > 2 {
            closeTake()
        }
        if takeRecorder == nil {
            guard let folder else { return }
            var rel: String
            repeat {
                takeNumber += 1
                rel = "\(CourseProject.takesFolder)/take-\(String(format: "%03d", takeNumber)).mp4"
            } while FileManager.default.fileExists(atPath: folder.appendingPathComponent(rel).path)
            let rec = Recorder()
            do {
                try rec.start(RecorderOptions(url: folder.appendingPathComponent(rel), size: CGSize(width: w, height: h),
                                              fps: 30, codec: .h264, bitrate: takeBitrate(CGSize(width: w, height: h))))
            } catch {
                NSLog("[Production] cannot start take: \(error)")
                return
            }
            takeRecorder = rec
            take = Take(file: rel, source: source, start: t, end: t, width: w, height: h, contentRect: f.contentRect)
            DispatchQueue.main.async { [weak self] in self?.recordingTake = true }
        }
        takeRecorder?.consume(f.pixelBuffer, hostTime: t)
        take?.end = t + 1.0 / 30
    }

    private func closeTake() {
        guard let rec = takeRecorder, let t = take else { return }
        takeRecorder = nil
        take = nil
        lastScreenFrame = nil
        DispatchQueue.main.async { [weak self] in self?.recordingTake = false }
        let finishes = takeFinishes
        finishes.enter()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.finishingCount += 1
            self.isFinishingTakes = true
        }
        guard t.end - t.start >= 0.2 else {
            let targetFolder = folder
            rec.stop(markers: []) { [weak self] r in
                defer { finishes.leave() }
                if r.files.count <= 1, r.failedSegments.isEmpty {
                    for f in r.files { try? FileManager.default.removeItem(at: f) }
                } else {
                    self?.reportError("短演示素材写入异常，已保留录到的文件，未加入时间线。请检查项目：\(targetFolder?.path ?? "当前项目")")
                }
                if let self {
                    self.finishingCount = max(0, self.finishingCount - 1)
                    self.isFinishingTakes = self.finishingCount > 0
                }
            }
            return
        }
        pendingTakes.append(t)
        let targetFolder = folder
        let id = t.id
        rec.stop(markers: []) { [weak self] result in
            defer { finishes.leave() }
            guard let self else { return }
            self.drainPendingChanges()
            if (result.files.count != 1 || !result.failedSegments.isEmpty), let targetFolder {
                // An old project's completion must never mutate a newly opened project.
                if self.folder == targetFolder, var p = self.project {
                    p.takes.removeAll { $0.id == id }
                    self.update(p)
                } else if var p = ProjectStore.load(targetFolder) {
                    p.takes.removeAll { $0.id == id }
                    try? ProjectStore.save(p, to: targetFolder)
                }
                self.reportError("演示素材写入异常，不能作为完整片段使用，已从时间线移除；已录到的文件仍保留。请检查项目：\(targetFolder.path)（成功保存 \(result.files.count) 段，失败 \(result.failedSegments.count) 段）")
            }
            self.finishingCount = max(0, self.finishingCount - 1)
            self.isFinishingTakes = self.finishingCount > 0
            self.flushSave()
        }
    }

    private func flushCursor() {
        guard !cursorBuffer.isEmpty else { return }
        pendingCursor.append(contentsOf: cursorBuffer)
        cursorBuffer = []
    }

    /// The queue only stages metadata. Main drains it before changing project identity or exporting.
    private func drainPendingChanges() {
        let changes: ([Take], [TimedPoint]) = queue.sync {
            let changes = (pendingTakes, pendingCursor)
            pendingTakes = []
            pendingCursor = []
            return changes
        }
        guard var p = project, !changes.0.isEmpty || !changes.1.isEmpty else { return }
        p.takes.append(contentsOf: changes.0)
        p.cursor.append(contentsOf: changes.1)
        p.cursor.sort { $0.t < $1.t }
        update(p)
    }

    /// Converts a global Quartz point into normalized coordinates of a capture source.
    static func normalized(_ p: CGPoint, on ref: SourceRef, screens: ScreenCaptureManager) -> CGPoint? {
        let frame: CGRect
        switch ref {
        case .display(let id): frame = CGDisplayBounds(id)
        case .window(let id):
            guard let f = screens.windowFrame(id) else { return nil }
            frame = f
        case .slides: return nil
        }
        guard frame.width > 0, frame.height > 0 else { return nil }
        let n = CGPoint(x: (p.x - frame.minX) / frame.width, y: (p.y - frame.minY) / frame.height)
        guard n.x >= 0, n.x <= 1, n.y >= 0, n.y <= 1 else { return nil }
        return n
    }
}
