import Foundation
import AppKit
import AVFoundation
import Carbon
import Combine
import Metal
import OSLog
import UniformTypeIdentifiers

private let perfLog = Logger(subsystem: "com.gene.course-recorder", category: "perf")

enum RecState: Equatable {
    case idle
    case countdown(Int)
    case recording
    case paused
    case finishing

    var isActive: Bool { self == .recording || self == .paused }
}

struct Toast: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let icon: String
}

enum TeleprompterCommand {
    case show, hide, toggleVisible, togglePlay, rewind
}

/// High-frequency status values, kept separate so that only the views showing them re-render.
final class LiveStatus: ObservableObject {
    @Published var elapsed: Double = 0
    @Published var fileSize: Int64 = 0
    @Published var renderFPS: Double = 0
    @Published var renderMs: Double = 0
    @Published var cameraFPS: Double = 0
    @Published var cameraMs: Double = 0
    @Published var dropped = 0
    @Published var micDB: Float = -120
    @Published var outDB: Float = -120
    @Published var ducking: Float = 1
    @Published var bgm = BGMStatus()
    @Published var countdown = 0
}

final class AppState: ObservableObject {
    @Published var settings: AppSettings {
        didSet { if settings != oldValue && !restoringOutputFormat { settingsDidChange(from: oldValue) } }
    }
    private var restoringOutputFormat = false
    private var restoringProjectOutput = false

    // Runtime state
    @Published var scene: SceneKind = .camera
    @Published var pipHidden = false
    @Published var zoomed = false
    @Published var demoSources: [SourceRef] = []
    @Published var demoIndex = 0
    @Published var displays: [CaptureSourceInfo] = []
    @Published var windows: [CaptureSourceInfo] = []
    @Published var cameras: [DeviceInfo] = []
    @Published var mics: [DeviceInfo] = []
    @Published var cameraStatus = CameraStatus()
    @Published var micName = ""
    @Published var micError: String?
    @Published var screenPermission = Permissions.screen
    @Published var screenError: String?
    @Published var deck: SlideDeck?
    @Published var deckConverting = false
    @Published var deckThumbnails: [NSImage] = []
    @Published var slideIndex = 0
    /// Zoom of the current page when the user zoomed / panned it, nil for the default view.
    @Published var slideZoom: CGFloat?
    @Published var recState: RecState = .idle
    @Published var markers: [RecordingMarker] = []
    @Published var lastRecording: URL?
    @Published var recentRecordings: [URL] = []
    @Published var micMuted = false
    @Published private(set) var cameraEnabled = true
    @Published private(set) var cameraSwitchInProgress = false
    @Published var toast: Toast?
    @Published var hotkeyFailures: [HotkeyAction] = []
    @Published var thumbnails: [String: NSImage] = [:]
    @Published var inspectorTab: InspectorTab = .scenes

    let live = LiveStatus()

    // Pipeline
    let ciContext: CIContext
    let assets: AssetFactory
    let store = FrameStore()
    let cursor = CursorTracker()
    let engine: RenderEngine
    let processor: CameraProcessor
    let camera: CameraCapture
    let mic = MicCapture()
    let screens: ScreenCaptureManager
    let mixer = AudioMixer()
    let recorder = Recorder()

    // Narration-first production
    enum WorkMode: String { case live, production }
    @Published var workMode: WorkMode = .live
    let production: ProductionSession
    let aiProduction = AIProductionController()
    let narrationEdit = NarrationEditController()
    private let productionPreview = ProductionPreview()
    @Published var projectNames: [String] = []
    @Published var projectActionInProgress = false
    let projectMusicImport = ProjectMusicImportController()
    var canManageProject: Bool {
        !isShuttingDown && recState == .idle && exportProgress == nil && narrationImportProgress == nil
            && !aiProduction.locksProject && !production.isPlaying && !production.recordingTake
            && !production.isFinishingTakes && !projectActionInProgress
    }
    /// A writer and an active production pass must keep one fixed output format.
    var canChangeOutputFormat: Bool {
        canManageProject && !narrationImportPreviewPaused && !production.isReviewing
            && !narrationEdit.isBusy && narrationEdit.draft == nil
    }

    func setOutputAspect(_ aspect: OutputAspect) {
        guard aspect != settings.recording.aspect else { return }
        guard canChangeOutputFormat else {
            showToast("请先结束录制、播放或当前制作操作，再切换横竖屏", icon: "lock")
            return
        }
        settings.recording.aspect = aspect
    }
    /// Export progress 0…1 while a 成片 is being rendered.
    @Published var exportProgress: Double?
    @Published var narrationImportProgress: Double?
    @Published var narrationImportStatus = ""
    @Published private(set) var narrationImportPreviewPaused = false
    private var narrationImportPreviewToken: UUID?
    private var previewStarted = false
    var narrationImporter: NarrationImporter?
    var narrationImportTask: Task<Void, Never>?
    var narrationImportID = UUID()
    private var exporter: ProjectExporter?
    /// Records the processed camera frames + microphone as the narration video.
    let narrationRecorder = Recorder()
    private let narrationLock = NSLock()
    private var narrationPending: RecorderOptions?
    private var narrationOutputURL: URL?
    private var productionObservers: [AnyCancellable] = []
    private var isShuttingDown = false
    @Published var recordingMergeProgress: Double?
    @Published var recordingMergeStatus = ""
    var recordingMerger: RecordingSegmentMerger?
    var recordingMergeTask: Task<Void, Never>?
    var suppressRecordingMerge = false

    // Hooks set by the app delegate
    var onTeleprompter: ((TeleprompterCommand) -> Void)?
    var onToggleControlBar: (() -> Void)?
    var onShowMainWindow: (() -> Void)?
    var onShowProgram: (() -> Void)?

    private var statusTimer: Timer?
    private var countdownTimer: Timer?
    /// Keeps App Nap from throttling the render loop while our windows are hidden or covered.
    private var liveActivity: NSObjectProtocol?
    private var recordingActivity: NSObjectProtocol?
    /// Camera latency measured when the recording started; audio is delayed by it.
    private(set) var autoAVOffset: Double = 0
    private var saveWork: DispatchWorkItem?
    private var statusTick = 0
    private var observers: [NSObjectProtocol] = []

    init() {
        let loaded = SettingsStore.load()
        settings = loaded
        if let device = MTLCreateSystemDefaultDevice() {
            ciContext = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "CourseRecorder"])
        } else {
            ciContext = CIContext(options: [.cacheIntermediates: false])
        }
        assets = AssetFactory(context: ciContext)
        engine = RenderEngine(context: ciContext, store: store, assets: assets, cursor: cursor,
                              canvasSize: loaded.recording.outputSize)
        processor = CameraProcessor(context: ciContext, assets: assets)
        camera = CameraCapture(processor: processor, store: store)
        screens = ScreenCaptureManager(store: store)
        engine.screens = screens
        production = ProductionSession(store: store, processor: processor, screens: screens)
        wire()
    }

    private func wire() {
        camera.onStatus = { [weak self] s in self?.cameraStatus = s }
        mic.onStatus = { [weak self] err, name in
            self?.micError = err
            self?.micName = name
        }
        let mixer = self.mixer
        let recorder = self.recorder
        let narration = self.narrationRecorder
        mic.onSamples = { [weak mixer] p, n, pts in mixer?.processMic(p, frames: n, pts: pts) }
        mixer.onMixed = { [weak recorder, weak narration] sb in
            recorder?.appendAudio(sb)
            narration?.appendAudio(sb)
        }
        camera.onFrame = { [weak self] f in self?.narrationFrame(f) }
        screens.onAudio = { [weak mixer] sb in mixer?.pushSystemAudio(sb) }
        screens.onSourcesChanged = { [weak self] d, w in self?.sourcesUpdated(d, w) }
        screens.onError = { [weak self] msg in self?.screenError = msg }
        cursor.onClick = { [weak self] e in
            self?.engine.autoZoom(click: e)
            self?.production.recordClick(e)
        }
        production.demoSource = { [weak self] in self?.currentDemoSource }
        production.takeBitrate = { size in
            // Screen content at 30 fps: ~16 Mbps at 1080p, scaled with the area, capped for 4K-class windows.
            min(40_000_000, max(6_000_000, Int(16_000_000 * Double(size.width * size.height) / (1920 * 1080))))
        }
        production.editingAllowed = { [weak self] in self?.aiProduction.locksProject == false && self?.exportProgress == nil && self?.narrationImportProgress == nil && self?.projectActionInProgress == false }
        production.onPlayStarted = { [weak self] in self?.pinStateAsCues() }
        production.onReviewTime = { [weak self] time, cues, reset in
            guard let self else { return }
            self.productionPreview.apply(time: time, cues: cues, reset: reset, app: self)
        }
        aiProduction.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &productionObservers)
        narrationEdit.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &productionObservers)
        production.$isReviewing.removeDuplicates().dropFirst().sink { [weak self] reviewing in
            DispatchQueue.main.async {
                guard let self else { return }
                self.updateWantedStreams()
                if !reviewing {
                    self.productionPreview.reset()
                    self.engine.cursorOverride = nil
                    self.pushSources()
                }
            }
        }.store(in: &productionObservers)
        // While a narration is loaded it stands in for the camera: stop the live camera and skip re-processing.
        production.$isLoaded.dropFirst().removeDuplicates().sink { [weak self] loaded in
            // Published emits before assignment; read the new state on the next main-queue turn.
            DispatchQueue.main.async {
                guard let self, !self.isShuttingDown, self.production.isLoaded == loaded else { return }
                if loaded { self.camera.stop() }
                else if self.production.project?.hasNarration != true || self.recState != .idle { self.startCamera() }
                self.applyProcessing()
                self.applyLayout()
                self.updateWantedStreams()
                self.objectWillChange.send()
            }
        }.store(in: &productionObservers)
        // Views bound to the app state refresh when the project changes (e.g. the record button's label).
        production.$project.dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &productionObservers)
        Publishers.CombineLatest4(production.$isPlaying, production.$recordingTake,
                                  production.$isFinishingTakes, production.$isReviewing)
            .dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &productionObservers)
        HotkeyManager.shared.onAction = { [weak self] a in self?.perform(a) }
        recorder.onSegmentStarted = { [weak self] url, number, reason in
            guard let self, self.recState.isActive else { return }
            self.recordingFiles.append(url)
            if let reason {
                perfLog.error("segment \(number - 1) failed, continuing in \(url.lastPathComponent, privacy: .public): \(String(describing: reason), privacy: .public)")
                self.showToast("第 \(number - 1) 段写入出错，已自动续录到第 \(number) 段，录制没有中断", icon: "exclamationmark.triangle")
            }
        }
        recorder.onSegmentSaved = { [weak self] url, number, error in
            guard let self, self.recState.isActive else { return }
            if let error {
                perfLog.error("segment \(number) could not be saved: \(String(describing: error), privacy: .public)")
                self.showToast("第 \(number) 段保存失败（\(error.localizedDescription)），录制仍在继续", icon: "exclamationmark.triangle")
            } else {
                self.showToast("第 \(number) 段已安全保存，继续录制中", icon: "checkmark.shield")
            }
        }
        recorder.onFailure = { [weak self] error in
            guard let self, self.recState.isActive else { return }
            self.showToast("录制无法继续写入：\(error?.localizedDescription ?? "未知错误")", icon: "exclamationmark.triangle")
            self.stopRecording()
        }
    }

    // MARK: - Startup

    func start() {
        previewStarted = true
        liveActivity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .latencyCritical],
                                                             reason: "实时合成预览与录制")
        HotkeyManager.shared.install()
        registerHotkeys()
        cursor.start()
        refreshDevices()
        screens.fps = settings.recording.fps
        screens.maxCaptureWidth = maxCaptureWidth
        screens.showsCursor = settings.demo.showCursor
        applyProcessing()
        applyLayout()
        applyAssets()
        applyMixer()
        mixer.bgm.setTracks(settings.bgm.tracks)
        mixer.monitor.setEnabled(settings.bgm.monitor)
        engine.start(fps: settings.recording.fps)
        mixer.startFallbackClock()
        if !CommandLine.arguments.contains("--no-capture") {
            startCamera()
            mic.start(deviceID: settings.audio.micDeviceID)
            refreshSources()
            if settings.audio.systemAudio { screens.setSystemAudio(true) }
        }
        if !settings.slides.deckPath.isEmpty { loadDeck(settings.slides.deckPath) }
        startStatusTimer()
        makeThumbnails()
        refreshRecent()

        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshSources()
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasConnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
        })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshDevices()
            self?.startCamera(force: true)
        })
        // Keep the window list current: apps coming and going, desktops switching, windows hidden or shown.
        observers.append(nc.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.scheduleSourceRefresh()
        })
        let wc = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didActivateApplicationNotification, NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification, NSWorkspace.activeSpaceDidChangeNotification,
                     NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observers.append(wc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.scheduleSourceRefresh()
            })
        }
    }

    private var sourceRefreshWork: DispatchWorkItem?

    /// Re-reads displays and windows shortly, merging bursts of notifications into one refresh.
    func scheduleSourceRefresh(after delay: Double = 0.4) {
        guard !isShuttingDown, !narrationImportPreviewPaused, !CommandLine.arguments.contains("--no-capture") else { return }
        sourceRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshSources() }
        sourceRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func shutdown() {
        aiProduction.cancel()
        narrationEdit.cancel(in: self)
        guard !isShuttingDown else { return }
        isShuttingDown = true
        previewStarted = false
        cancelNarrationImport()
        cancelProjectMusicImport()
        cancelRecordingMerge()
        // Use the normal completion path, including committing a newly recorded narration file.
        if recState.isActive { stopRecording(mergeSegments: false) }
        let deadline = Date().addingTimeInterval(5)
        while recState == .finishing, Date() < deadline {
            // Recorder delivers completion on main; a semaphore here would prevent saving the project.
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        narrationLock.lock()
        narrationPending = nil
        narrationLock.unlock()
        production.close()
        flushSave()
        HotkeyManager.shared.unregisterAll()
        screens.stopAll()
        camera.stop()
        mic.stop()
        engine.stop()
    }

    var maxCaptureWidth: Int {
        // Keep the complete desktop sharp even when the output canvas is portrait.
        Int(settings.recording.resolution.size.width) * 2
    }

    func refreshDevices() {
        cameras = CameraCapture.availableDevices()
        mics = MicCapture.availableDevices()
    }

    func refreshSources() {
        guard !isShuttingDown, !narrationImportPreviewPaused else { return }
        screenPermission = Permissions.screen
        screens.refresh()
    }

    private func startCamera(force: Bool = false) {
        guard !isShuttingDown, cameraEnabled, !narrationImportPreviewPaused, !production.isLoaded,
              !CommandLine.arguments.contains("--no-capture") else { return }
        if force { camera.stop() }
        // 1080p is plenty for the presenter at any output size and keeps background removal within budget.
        camera.start(deviceID: settings.camera.deviceID, preferredFPS: settings.camera.frameRate, targetHeight: 1080)
    }

    /// Called only after take writers finish and the user confirms the import.
    @discardableResult
    func pausePreviewForNarrationImport(token: UUID) -> Bool {
        guard !isShuttingDown, recState == .idle, !production.isPlaying,
              !production.isFinishingTakes, narrationImportPreviewToken == nil else { return false }
        narrationImportPreviewToken = token
        narrationImportPreviewPaused = true
        sourceRefreshWork?.cancel()
        production.setPreviewSuspended(true)
        engine.stop()
        // A loaded narration owns the current camera frame; keep its paused frame intact.
        if !production.isLoaded { camera.stop() }
        updateWantedStreams()
        live.renderFPS = 0
        live.renderMs = 0
        live.cameraFPS = 0
        live.cameraMs = 0
        return true
    }

    func resumePreviewAfterNarrationImport(token: UUID) {
        guard narrationImportPreviewToken == token else { return }
        narrationImportPreviewToken = nil
        narrationImportPreviewPaused = false
        guard !isShuttingDown else { return }
        production.setPreviewSuspended(false)
        guard previewStarted else { return }
        engine.start(fps: settings.recording.fps)
        // A newly imported narration can still be loading asynchronously.
        if production.project?.hasNarration != true { startCamera() }
        updateWantedStreams()
        if !CommandLine.arguments.contains("--no-capture") { refreshSources() }
    }

    // MARK: - Settings propagation

    private func settingsDidChange(from old: AppSettings) {
        let outputChanged = old.recording.aspect != settings.recording.aspect
            || old.recording.resolution != settings.recording.resolution
            || old.recording.fps != settings.recording.fps
            || old.recording.codec != settings.recording.codec
            || old.recording.quality != settings.recording.quality
        if outputChanged && !canChangeOutputFormat && !restoringProjectOutput {
            var corrected = settings
            corrected.recording.aspect = old.recording.aspect
            corrected.recording.resolution = old.recording.resolution
            corrected.recording.fps = old.recording.fps
            corrected.recording.codec = old.recording.codec
            corrected.recording.quality = old.recording.quality
            restoringOutputFormat = true
            settings = corrected
            restoringOutputFormat = false
        }
        let s = settings
        guard old != s else { return }
        if old.camera.deviceID != s.camera.deviceID || old.camera.frameRate != s.camera.frameRate {
            startCamera()
        }
        if old.audio.micDeviceID != s.audio.micDeviceID { mic.start(deviceID: s.audio.micDeviceID) }
        if old.background != s.background || old.camera != s.camera || old.beauty != s.beauty
            || old.pip.shape != s.pip.shape || old.split.cutout != s.split.cutout {
            applyProcessing()
        }
        applyLayout()
        if old.recording.outputSize != s.recording.outputSize {
            engine.setCanvasSize(s.recording.outputSize)
            engine.invalidateAssets()
            screens.maxCaptureWidth = maxCaptureWidth
        }
        if old.recording.aspect != s.recording.aspect, workMode == .production,
           var project = production.project {
            project.outputAspect = s.recording.aspect
            production.update(project)
        }
        applyAssets()
        if old.audio != s.audio || old.bgm != s.bgm { applyMixer() }
        if old.bgm.tracks != s.bgm.tracks { mixer.bgm.setTracks(s.bgm.tracks) }
        if old.bgm.monitor != s.bgm.monitor { mixer.monitor.setEnabled(s.bgm.monitor) }
        if old.audio.systemAudio != s.audio.systemAudio { screens.setSystemAudio(s.audio.systemAudio) }
        if old.recording.fps != s.recording.fps {
            if !isShuttingDown, !narrationImportPreviewPaused { engine.start(fps: s.recording.fps) }
            screens.fps = s.recording.fps
        }
        if old.demo.showCursor != s.demo.showCursor { screens.showsCursor = s.demo.showCursor }
        if old.demo.sources != s.demo.sources || old.slides.source != s.slides.source || old.split.content != s.split.content
            || old.demo.showCursor != s.demo.showCursor || old.demo.throttleInactive != s.demo.throttleInactive
            || old.recording.fps != s.recording.fps {
            resolveSources(direction: nextSourceDirection)
        }
        if old.slides.deckPath != s.slides.deckPath {
            loadDeck(s.slides.deckPath)
            if var p = production.project, p.deckPath != s.slides.deckPath {
                p.deckPath = s.slides.deckPath
                production.update(p)
            }
        }
        if old.slides.source != s.slides.source, let src = slidesSource { production.record(.slidesSource(src)) }
        if old.hotkeys != s.hotkeys || old.slides.clickerKeys != s.slides.clickerKeys || old.slides.arrowKeys != s.slides.arrowKeys
            || old.slides.source != s.slides.source || old.split.content != s.split.content {
            registerHotkeys()
        }
        if old.background.customImagePath != s.background.customImagePath || old.demo.customBackdropPath != s.demo.customBackdropPath {
            makeThumbnails()
        }
        scheduleSave()
    }

    private func applyProcessing() {
        let s = settings
        processor.update(CameraProcessingConfig(background: s.background, camera: s.camera, beauty: s.beauty,
                                                needCutout: s.pip.shape == .cutout || s.split.cutout,
                                                preprocessed: production.isLoaded))
    }

    private func applyLayout() {
        var config = settings.layoutConfig(for: production.isLoaded ? production.project : nil)
        config.presenterVisible = cameraEnabled || production.isLoaded
        engine.update(config: config, transitions: settings.transitions)
    }

    private func applyAssets() {
        engine.applyAssets(settings.assetConfig)
    }

    private func applyMixer() {
        let a = settings.audio, b = settings.bgm
        mixer.update(MixerConfig(micGain: dbToLinear(a.micGainDB), highPass: a.highPass, gate: a.noiseGate,
                                 gateThresholdDB: a.gateThresholdDB, limiter: a.limiter,
                                 systemGain: dbToLinear(a.systemGainDB), bgmGain: dbToLinear(b.volumeDB),
                                 ducking: b.ducking, duckGain: dbToLinear(b.duckDB), micMuted: micMuted,
                                 avOffset: a.avOffsetMs / 1000 + (a.autoSync ? autoAVOffset : 0)))
        mixer.bgm.loopMode = b.loopMode
        mixer.bgm.setFadeSeconds(b.fadeSeconds)
        mixer.monitor.volume = Float(b.monitorVolume)
    }

    /// Off for offscreen tools (UI snapshots) so they never overwrite the user's settings file.
    var persistsSettings = true

    private func scheduleSave() {
        saveWork?.cancel()
        guard persistsSettings else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            SettingsStore.save(self.settings)
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    func flushSave() {
        saveWork?.cancel()
        guard persistsSettings else { return }
        SettingsStore.save(settings)
    }

    // MARK: - Sources

    private func sourcesUpdated(_ d: [CaptureSourceInfo], _ w: [CaptureSourceInfo]) {
        displays = d
        windows = w
        screenPermission = Permissions.screen || !d.isEmpty
        if !d.isEmpty { screenError = nil }
        resolveSources(direction: 1)
    }

    private var availableRefs: Set<SourceRef> { Set((displays + windows).map(\.ref)) }

    func resolveSources(direction: CGFloat, style: TransitionStyle? = nil) {
        let available = availableRefs
        var list = settings.demo.sources.filter { available.contains($0) }
        if list.isEmpty { list = displays.map(\.ref) }
        let current = currentDemoSource
        demoSources = list
        if let current, let i = list.firstIndex(of: current) { demoIndex = i } else { demoIndex = 0 }
        pushSources(direction: direction, style: style)
    }

    var currentDemoSource: SourceRef? {
        demoSources.indices.contains(demoIndex) ? demoSources[demoIndex] : nil
    }

    var slidesSource: SourceRef? {
        if let s = settings.slides.source {
            if s == .slides { return deck != nil ? .slides : nil }
            if availableRefs.contains(s) { return s }
        }
        if deck != nil { return .slides }
        return displays.first?.ref
    }

    /// The bottom strip and the "switch source" hotkey act on whatever content the current scene shows:
    /// the 讲解 content while the slides are on screen, otherwise the demo screen.
    var stripShowsSlides: Bool {
        scene == .slides || (scene == .split && settings.split.content == .slides)
    }

    /// What the 讲解 content cycles through: the imported file, each display, and a window once one is chosen.
    var slidesChoices: [SourceRef] {
        var list: [SourceRef] = deck != nil ? [.slides] : []
        list += displays.map(\.ref)
        if let s = settings.slides.source, case .window = s, availableRefs.contains(s) { list.append(s) }
        return list
    }

    func selectSlidesSource(_ ref: SourceRef) {
        guard !production.isReviewing else { return }
        guard settings.slides.source != ref else { return }
        let old = slidesSource
        nextSourceDirection = pushDirection(from: old, to: ref, forward: true)
        settings.slides.source = ref
        nextSourceDirection = 1
        if slidesSource != old { showToast("讲解画面 → \(shortSourceName(slidesSource))", icon: "rectangle.2.swap") }
        if let s = slidesSource { production.record(.slidesSource(s)) }
    }

    func nextSlidesSource() {
        let choices = slidesChoices
        guard choices.count > 1 else {
            showToast("讲解画面只有一个来源：导入文件，或接上第二块屏幕", icon: "rectangle.inset.bottomleft.filled")
            return
        }
        let i = slidesSource.flatMap { choices.firstIndex(of: $0) } ?? -1
        selectSlidesSource(choices[(i + 1) % choices.count])
    }

    /// Hotkey / control bar: cycles the content of the scene on screen.
    func nextSource() {
        if stripShowsSlides { nextSlidesSource() } else { nextDemoSource() }
    }

    /// Direction for the push transition of the next source change made through `settings`.
    private var nextSourceDirection: CGFloat = 1

    private func pushSources(direction: CGFloat = 1, style: TransitionStyle? = nil) {
        engine.setSources(SceneSources(slides: slidesSource, demo: currentDemoSource), direction: direction, style: style)
        updateWantedStreams()
    }

    private func updateWantedStreams() {
        if isShuttingDown || narrationImportPreviewPaused || production.isReviewing {
            screens.setWanted([], focus: nil, throttle: settings.demo.throttleInactive)
            return
        }
        var want = demoSources
        if let s = slidesSource, s.isCapture, !want.contains(s) { want.append(s) }
        let focus: SourceRef?
        if production.isLoaded {
            // The demo screen is being recorded as a take whatever the scene shows: keep it at full rate.
            focus = currentDemoSource
        } else {
            switch scene {
            case .camera: focus = nil
            case .slides: focus = slidesSource
            case .demo: focus = currentDemoSource
            case .split: focus = settings.split.content == .slides ? slidesSource : currentDemoSource
            }
        }
        screens.setWanted(want, focus: focus, throttle: settings.demo.throttleInactive)
    }

    func sourceName(_ ref: SourceRef?) -> String {
        guard let ref else { return "无" }
        if ref == .slides { return deck.map { "幻灯片 · \($0.title)" } ?? "幻灯片" }
        guard let info = (displays + windows).first(where: { $0.ref == ref }) else { return "已断开的画面" }
        return info.onScreen ? info.name : "\(info.name)（后台）"
    }

    func shortSourceName(_ ref: SourceRef?) -> String {
        guard let ref else { return "无" }
        switch ref {
        case .slides: return "幻灯片"
        case .display:
            if let i = displays.firstIndex(where: { $0.ref == ref }) { return "显示器 \(i + 1)" }
            return "显示器"
        case .window:
            let name = windows.first { $0.ref == ref }?.name ?? "窗口"
            return String(name.split(separator: "—").first ?? Substring(name)).trimmingCharacters(in: .whitespaces)
        }
    }

    func toggleDemoSource(_ ref: SourceRef, included: Bool) {
        var list = settings.demo.sources
        if list.isEmpty { list = displays.map(\.ref) }
        if included {
            if !list.contains(ref) { list.append(ref) }
        } else {
            list.removeAll { $0 == ref }
        }
        settings.demo.sources = list
    }

    func isDemoSource(_ ref: SourceRef) -> Bool {
        settings.demo.sources.isEmpty ? displays.contains { $0.ref == ref } : settings.demo.sources.contains(ref)
    }

    func moveDemoSource(_ ref: SourceRef, by delta: Int) {
        var list = settings.demo.sources.isEmpty ? displays.map(\.ref) : settings.demo.sources
        guard let i = list.firstIndex(of: ref) else { return }
        let j = max(0, min(list.count - 1, i + delta))
        guard i != j else { return }
        list.swapAt(i, j)
        settings.demo.sources = list
    }

    // MARK: - Actions

    func perform(_ action: HotkeyAction) {
        switch action {
        case .sceneCamera: selectScene(.camera)
        case .sceneSlides: selectScene(.slides)
        case .sceneDemo: selectScene(.demo)
        case .sceneSplit: selectScene(.split)
        case .togglePIP: togglePIP()
        case .nextSource: nextSource()
        case .toggleZoom: toggleZoom()
        case .record: toggleRecording()
        case .pause: togglePause()
        case .marker: addMarker(.chapter)
        case .markerNG: addMarker(.mistake)
        case .bgm: toggleBGM()
        case .lowerThird: showLowerThird()
        case .slideNext: nextSlide()
        case .slidePrev: previousSlide()
        case .teleprompter: onTeleprompter?(.togglePlay)
        case .controlBar: onToggleControlBar?()
        case .micMute: toggleMicMute()
        }
    }

    func selectScene(_ s: SceneKind) {
        guard !production.isReviewing else { return }
        guard s != scene else { return }
        scene = s
        engine.setScene(s)
        production.record(.scene(s))
        if s == .camera && engine.isZoomed {
            engine.setZoom(false)
            zoomed = false
            production.record(.zoom(false))
        }
        updateWantedStreams()
        registerHotkeys()
        if (s == .slides || (s == .split && settings.split.content == .slides)) && slidesSource == nil {
            showToast("还没有讲解内容：在「镜头」页导入幻灯片或选择一块屏幕", icon: "exclamationmark.triangle")
        } else if (s == .demo || (s == .split && settings.split.content == .demo)) && currentDemoSource == nil {
            showToast("没有可用的屏幕画面：请检查录屏权限", icon: "exclamationmark.triangle")
        }
    }

    func togglePIP() {
        guard !production.isReviewing else { return }
        pipHidden.toggle()
        engine.setPIPVisible(!pipHidden)
        production.record(.pip(!pipHidden))
        showToast(pipHidden ? "小窗人像已隐藏" : "小窗人像已显示", icon: pipHidden ? "person.crop.circle.badge.xmark" : "person.crop.circle")
    }

    func nextDemoSource() {
        guard demoSources.count > 1 else {
            showToast("只有一个演示画面，可在「画面源」页加入第二块屏幕或窗口", icon: "display")
            return
        }
        selectDemoSource((demoIndex + 1) % demoSources.count)
    }

    func selectDemoSource(_ i: Int) {
        guard !production.isReviewing else { return }
        guard demoSources.indices.contains(i), i != demoIndex else { return }
        let old = currentDemoSource
        demoIndex = i
        let new = currentDemoSource
        pushSources(direction: pushDirection(from: old, to: new, forward: true))
        if let new { production.record(.demoSource(new)) }
        zoomed = false
        showToast("演示画面 → \(shortSourceName(new))", icon: "rectangle.2.swap")
    }

    private func pushDirection(from a: SourceRef?, to b: SourceRef?, forward: Bool) -> CGFloat {
        guard let a, let b, let fa = screens.info(for: a)?.frame, let fb = screens.info(for: b)?.frame else { return forward ? 1 : -1 }
        if case .display = a, case .display = b {
            if abs(fb.midX - fa.midX) > 1 { return fb.midX > fa.midX ? 1 : -1 }
            return fb.midY > fa.midY ? 1 : -1
        }
        return forward ? 1 : -1
    }

    func toggleZoom() {
        guard !production.isReviewing else { return }
        let on = !engine.isZoomed
        engine.setZoom(on)
        zoomed = on
        production.record(.zoom(on))
        showToast(on ? "跟随放大 \(String(format: "%.1f", settings.demo.zoomFactor))×" : "取消放大", icon: on ? "plus.magnifyingglass" : "minus.magnifyingglass")
    }

    func showLowerThird() {
        guard !production.isReviewing else { return }
        engine.showLowerThird(seconds: settings.overlay.lowerThirdSeconds)
        production.record(.lowerThird)
    }

    func toggleMicMute() {
        micMuted.toggle()
        applyMixer()
        showToast(micMuted ? "麦克风已静音" : "麦克风已打开", icon: micMuted ? "mic.slash.fill" : "mic.fill")
    }

    var canToggleCamera: Bool {
        !isShuttingDown && !cameraSwitchInProgress && !narrationImportPreviewPaused && narrationImportProgress == nil
            && exportProgress == nil && !projectActionInProgress && !production.isLoaded
            && !(workMode == .production && recState != .idle)
    }

    var cameraToggleHelp: String {
        if cameraSwitchInProgress { return "摄像头正在关闭，请稍候" }
        if narrationImportProgress != nil { return "导入视频期间暂时关闭摄像头预览" }
        if workMode == .production && recState != .idle { return "录口播需要摄像头持续提供画面；结束录制后可关闭" }
        if production.isLoaded { return "当前显示已录口播，实时摄像头已停用" }
        if !canToggleCamera { return "请等待当前操作完成后切换摄像头" }
        return cameraEnabled ? "关闭摄像头并停止人像处理，屏幕录制继续" : "开启摄像头并恢复人像画面"
    }

    func toggleCamera() {
        guard canToggleCamera else { return }
        cameraEnabled.toggle()
        // Hide the presenter immediately, including frames already queued by the capture session.
        applyLayout()
        if cameraEnabled { startCamera() }
        else {
            cameraSwitchInProgress = true
            camera.stop { [weak self] in self?.cameraSwitchInProgress = false }
            live.cameraFPS = 0
            live.cameraMs = 0
        }
        showToast(cameraEnabled ? "摄像头已开启" : "摄像头已关闭，人像处理已停止", icon: cameraEnabled ? "video.fill" : "video.slash.fill")
    }

    func toggleBGM() {
        guard !settings.bgm.tracks.isEmpty else {
            showToast("还没有 BGM：在「音频」页添加音乐", icon: "music.note")
            return
        }
        mixer.bgm.toggle()
        let st = mixer.bgm.status()
        live.bgm = st
        showToast(st.playing ? "BGM ▶ \(st.trackName)" : "BGM 已暂停", icon: "music.note")
    }

    // MARK: - Slides

    func loadDeck(_ path: String) {
        guard !path.isEmpty else {
            deck = nil
            engine.setDeck(nil)
            pushSources()
            return
        }
        let name = (path as NSString).lastPathComponent
        let needsConversion = PresentationConverter.isPresentation(path)
        if needsConversion {
            let cached = FileManager.default.fileExists(atPath: PresentationConverter.cachedPDF(for: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)).path)
            deckConverting = true
            if !cached { showToast("正在把「\(name)」转成幻灯片，第一次大约 10 秒…", icon: "hourglass") }
        }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var deckPath = path
            var failure: String?
            if needsConversion {
                do {
                    deckPath = try PresentationConverter.convert(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)).path
                } catch {
                    failure = error.localizedDescription
                }
            }
            let d = failure == nil ? SlideDeck(path: deckPath, title: needsConversion ? name : nil) : nil
            DispatchQueue.main.async {
                guard let self, self.settings.slides.deckPath == path else { return }
                self.deckConverting = false
                self.deck = d
                self.slideIndex = 0
                self.deckThumbnails = []
                self.engine.setDeck(d)
                self.pushSources()
                self.registerHotkeys()
                if let d { self.makeDeckThumbnails(d) }
                if let failure {
                    self.showToast("PPT 转换失败：\(failure)", icon: "exclamationmark.triangle")
                } else if let d {
                    if needsConversion { self.showToast("已导入「\(name)」，共 \(d.pageCount) 页", icon: "checkmark.circle") }
                } else {
                    self.showToast("无法打开幻灯片：\(name)", icon: "exclamationmark.triangle")
                }
            }
        }
    }

    /// Re-reads the current deck; a presentation edited since the last import is converted again.
    func reloadDeck() {
        loadDeck(settings.slides.deckPath)
    }

    private func makeDeckThumbnails(_ d: SlideDeck) {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let size = CGSize(width: 192, height: 108)
            let images = (0..<d.pageCount).map { i -> NSImage in
                guard let cg = d.thumbnail(i, size: size) else { return NSImage(size: size) }
                return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            }
            DispatchQueue.main.async {
                guard let self, self.deck === d else { return }
                self.deckThumbnails = images
            }
        }
    }

    /// The imported slides are what the current scene is showing.
    var slidesOnScreen: Bool {
        guard deck != nil, slidesSource == .slides else { return false }
        return scene == .slides || (scene == .split && settings.split.content == .slides)
    }

    /// Keyboard navigation while one of our windows is focused (text fields keep their keys).
    func handleLocalKey(_ e: NSEvent) -> Bool {
        guard !HotkeyRecorder.isRecording, e.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        if let tv = NSApp.keyWindow?.firstResponder as? NSTextView, tv.isEditable { return false }
        // Production: space plays / pauses the narration.
        if workMode == .production, production.isLoaded, Int(e.keyCode) == kVK_Space {
            if !aiProduction.isBusy, exportProgress == nil, narrationImportProgress == nil, !projectActionInProgress { production.togglePlay() }
            return true
        }
        guard deck != nil, slidesSource == .slides else { return false }
        switch Int(e.keyCode) {
        case kVK_RightArrow, kVK_DownArrow, kVK_Space, kVK_PageDown, kVK_Return:
            nextSlide()
        case kVK_LeftArrow, kVK_UpArrow, kVK_PageUp:
            previousSlide()
        case kVK_Home:
            goToSlide(0)
        case kVK_End:
            goToSlide((deck?.pageCount ?? 1) - 1)
        default:
            return false
        }
        return true
    }

    func nextSlide() {
        guard !production.isReviewing else { return }
        guard let deck else { return }
        slideIndex = engine.setSlide(min(deck.pageCount - 1, slideIndex + 1))
        production.record(.slide(slideIndex))
        slideZoom = engine.slideViewZoom()
    }

    func previousSlide() {
        guard !production.isReviewing else { return }
        guard deck != nil else { return }
        slideIndex = engine.setSlide(max(0, slideIndex - 1))
        production.record(.slide(slideIndex))
        slideZoom = engine.slideViewZoom()
    }

    func goToSlide(_ i: Int) {
        guard !production.isReviewing else { return }
        guard deck != nil else { return }
        slideIndex = engine.setSlide(i)
        production.record(.slide(slideIndex))
        slideZoom = engine.slideViewZoom()
    }

    /// Zoom / pan of the current page from preview gestures.
    func slideView(_ action: RenderEngine.SlideViewAction) {
        let z = engine.slideView(action)
        if z != slideZoom { slideZoom = z }
    }

    // MARK: - Recording

    func toggleRecording() {
        guard !projectActionInProgress else { return }
        if workMode == .production {
            toggleNarrationRecording()
            return
        }
        switch recState {
        case .idle: startCountdown { [weak self] in self?.beginRecording() }
        case .countdown: cancelCountdown()
        case .recording, .paused: stopRecording()
        case .finishing: break
        }
    }

    private func startCountdown(then begin: @escaping () -> Void) {
        let n = settings.recording.countdown
        guard n > 0 else {
            begin()
            return
        }
        recState = .countdown(n)
        live.countdown = n
        tick()
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { return t.invalidate() }
            guard case .countdown(let c) = self.recState else { return t.invalidate() }
            if c <= 1 {
                t.invalidate()
                self.live.countdown = 0
                begin()
            } else {
                self.recState = .countdown(c - 1)
                self.live.countdown = c - 1
                self.tick()
            }
        }
        RunLoop.main.add(countdownTimer!, forMode: .common)
    }

    private func tick() {
        if settings.recording.countdownSound { NSSound(named: "Tink")?.play() }
    }

    private func cancelCountdown() {
        countdownTimer?.invalidate()
        recState = .idle
        live.countdown = 0
        restoreNarrationPlayback()
        showToast("已取消录制", icon: "xmark.circle")
    }

    private func beginRecording() {
        suppressRecordingMerge = false
        recordingMergeStatus = ""
        let r = settings.recording
        let folder = testRecordingFolder ?? r.folderURL
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            recState = .idle
            showToast("无法创建保存目录：\(error.localizedDescription)", icon: "exclamationmark.triangle")
            return
        }
        if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage,
           free < 2_000_000_000 {
            showToast("磁盘剩余空间不足 2GB，请注意", icon: "externaldrive.badge.exclamationmark")
        }
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let prefix = r.filePrefix.trimmingCharacters(in: .whitespaces).isEmpty ? "课程录制" : r.filePrefix
        let url = folder.appendingPathComponent("\(prefix) \(df.string(from: Date())).mp4")
        autoAVOffset = cameraStatus.running ? min(0.25, max(0, engine.videoLag)) : 0
        applyMixer()
        // A just-selected canvas must reach the render queue before it feeds this writer.
        engine.synchronize()
        do {
            let segment = testSegmentSeconds ?? (r.segmentMinutes > 0 ? Double(r.segmentMinutes * 60) : nil)
            try recorder.start(RecorderOptions(url: url, size: r.outputSize, fps: r.fps, codec: r.codec, bitrate: r.videoBitrate,
                                               segmentSeconds: segment))
        } catch {
            recState = .idle
            showToast("开始录制失败：\(error.localizedDescription)", icon: "exclamationmark.triangle")
            return
        }
        markers = []
        live.elapsed = 0
        live.fileSize = 0
        recordingFiles = [url]
        engine.addSink(recorder)
        recState = .recording
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "正在录制课程")
        if settings.bgm.autoStart && !settings.bgm.tracks.isEmpty && !mixer.bgm.status().playing { mixer.bgm.play() }
        showToast("开始录制", icon: "record.circle")
    }

    /// Files of the current recording, one per segment.
    private var recordingFiles: [URL] = []
    var onRecordingFinished: ((RecordingResult) -> Void)?

    // MARK: - Automated recording check

    private var testRecordingFolder: URL?
    private var testSegmentSeconds: Double?
    private var autoReport: [String] = []

    /// `--auto-record`: records through every scene with the live sources, writes a report next to the file and quits.
    func runAutoRecordTest(seconds: Double, folder: URL, segmentSeconds: Double?) {
        testRecordingFolder = folder
        testSegmentSeconds = segmentSeconds
        let original = scene
        let order: [SceneKind] = [.camera, .slides, .demo, .split, .camera]
        autoReport = ["segments \(segmentSeconds.map { "\($0)s" } ?? "from settings")"]
        selectScene(order[0])
        beginRecording()
        let step = seconds / Double(order.count)
        for (i, s) in order.enumerated() where i > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + step * Double(i)) { [weak self] in
                guard let self else { return }
                self.selectScene(s)
                self.autoReport.append(String(format: "%.2f s -> %@", self.recorder.recordingTime(), s.rawValue))
            }
        }
        onRecordingFinished = { [weak self] result in
            guard let self else { return }
            let st = self.recorder.currentStats()
            self.autoReport.append("saved \(result.files.map(\.lastPathComponent)) failed \(result.failedSegments) error \(result.error.map { "\($0)" } ?? "none")")
            self.autoReport.append("written \(st.framesWritten) dropped \(st.framesDropped)")
            try? self.autoReport.joined(separator: "\n").write(to: folder.appendingPathComponent("auto-record.txt"),
                                                               atomically: true, encoding: .utf8)
            self.selectScene(original)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stopRecording() }
    }

    func togglePause() {
        if workMode == .production, recState == .recording {
            narrationLock.lock()
            let waiting = narrationPending != nil
            narrationLock.unlock()
            if waiting {
                showToast("正在等待摄像头画面，请稍后暂停", icon: "camera")
                return
            }
        }
        let active = workMode == .production ? narrationRecorder : recorder
        switch recState {
        case .recording:
            active.pause()
            recState = .paused
            showToast("已暂停录制", icon: "pause.circle")
        case .paused:
            active.resume()
            recState = .recording
            showToast("继续录制", icon: "record.circle")
        default:
            if workMode == .production, production.isLoaded, !aiProduction.isBusy, exportProgress == nil, narrationImportProgress == nil, !projectActionInProgress { production.togglePlay() }
        }
    }

    // MARK: - Narration-first production

    func setWorkMode(_ mode: WorkMode) {
        guard mode != workMode else { return }
        guard recState == .idle else {
            showToast("录制中不能切换模式", icon: "exclamationmark.triangle")
            return
        }
        guard exportProgress == nil, narrationImportProgress == nil, !projectActionInProgress, !production.isFinishingTakes, !aiProduction.locksProject else { return }
        workMode = mode
        if mode == .production {
            projectNames = ProjectStore.list(in: settings.recording.folderURL)
            inspectorTab = .production
            if production.project == nil, let name = projectNames.first { openProject(named: name) }
        } else {
            production.close()
            if inspectorTab == .production { inspectorTab = .scenes }
        }
    }

    func refreshProjects() {
        projectNames = ProjectStore.list(in: settings.recording.folderURL)
    }

    @discardableResult
    func createProject(named name: String) -> Bool {
        guard !isShuttingDown, recState == .idle, exportProgress == nil, narrationImportProgress == nil, !projectActionInProgress, !production.isFinishingTakes, !aiProduction.locksProject else { return false }
        do {
            let (p, folder) = try ProjectStore.create(named: name, deckPath: settings.slides.deckPath,
                                                     in: settings.recording.folderURL, outputAspect: settings.recording.aspect)
            production.open(p, folder: folder)
            refreshProjects()
            showToast("已新建项目「\(p.name)」，先录制或导入口播", icon: "folder.badge.plus")
            return true
        } catch {
            showToast("无法新建项目：\(error.localizedDescription)", icon: "exclamationmark.triangle")
            return false
        }
    }

    /// A single entry point for the toolbar, production page and recording hotkey.
    private func createProjectBeforeNarration() {
        guard canManageProject, workMode == .production, production.project == nil else { return }
        refreshProjects()
        inspectorTab = .production
        let recordings = settings.recording.folderURL
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH-mm"
        let nameField = NSTextField(string: "课程 \(formatter.string(from: Date()))")
        nameField.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        nameField.placeholderString = "课程项目名称"
        nameField.setAccessibilityLabel("课程项目名称")

        // The modal runs a nested main loop; block duplicate hotkeys and project changes.
        projectActionInProgress = true
        let alert = NSAlert()
        alert.messageText = "开始录口播前，先建立课程项目"
        alert.informativeText = "项目用来保存这节课的口播、镜头和成片。可以修改下面的名称，创建后将按录制设置倒计时开始。也可以取消，或到制作页打开已有项目。"
        alert.accessoryView = nameField
        alert.addButton(withTitle: "创建并开始录制")
        alert.addButton(withTitle: "打开已有项目")
        alert.addButton(withTitle: "取消")
        alert.buttons.last?.keyEquivalent = "\u{1b}"
        alert.window.initialFirstResponder = nameField
        let response = alert.runModal()
        projectActionInProgress = false

        guard !isShuttingDown, canManageProject, workMode == .production,
              production.project == nil, settings.recording.folderURL == recordings else { return }
        switch response {
        case .alertFirstButtonReturn:
            guard createProject(named: nameField.stringValue) else { return }
            toggleNarrationRecording()
        case .alertSecondButtonReturn:
            refreshProjects()
            inspectorTab = .production
            showToast(projectNames.isEmpty ? "还没有已保存的项目，可以在制作页新建" : "请在制作页的「打开已有项目」中选择课程", icon: "folder")
        default:
            break
        }
    }

    func openProject(named name: String) {
        guard recState == .idle, exportProgress == nil, narrationImportProgress == nil, !projectActionInProgress, !production.isFinishingTakes, !aiProduction.locksProject else { return }
        let folder = ProjectStore.folder(named: name, in: settings.recording.folderURL)
        guard let p = ProjectStore.load(folder) else {
            showToast("无法读取项目「\(name)」", icon: "exclamationmark.triangle")
            refreshProjects()
            return
        }
        // Close the old project before changing settings so its saved aspect is never overwritten.
        production.close()
        restoringProjectOutput = true
        settings.recording.aspect = p.outputAspect ?? .landscape
        restoringProjectOutput = false
        production.open(p, folder: folder)
        if !p.deckPath.isEmpty, p.deckPath != settings.slides.deckPath, FileManager.default.fileExists(atPath: p.deckPath) {
            settings.slides.deckPath = p.deckPath
        }
    }

    func revealProject() {
        guard let folder = production.folder else { return }
        NSWorkspace.shared.open(folder)
    }

    /// Records every aspect of the current state at the current time, so the timeline is self-consistent
    /// wherever playback starts.
    private func pinStateAsCues() {
        production.record(.scene(scene))
        production.record(.slide(slideIndex))
        if let d = currentDemoSource { production.record(.demoSource(d)) }
        if let s = slidesSource { production.record(.slidesSource(s)) }
        production.record(.pip(!pipHidden))
        production.record(.zoom(zoomed))
    }

    private func toggleNarrationRecording() {
        switch recState {
        case .idle:
            guard !cameraSwitchInProgress else {
                showToast("摄像头正在关闭，请稍后开始录口播", icon: "video.slash.fill")
                return
            }
            guard !isShuttingDown, exportProgress == nil, narrationImportProgress == nil, !projectActionInProgress, !production.isFinishingTakes, !aiProduction.locksProject else { return }
            guard production.project != nil else {
                createProjectBeforeNarration()
                return
            }
            // Starting a camera-based narration is an explicit request to use the camera again.
            if !cameraEnabled {
                cameraEnabled = true
                applyLayout()
                startCamera()
            }
            if production.isLoaded {
                // Re-recording: the live camera takes over again.
                production.finishOperations { [weak self] in
                    guard let self else { return }
                    self.production.unloadNarration()
                    self.startCountdown { [weak self] in self?.beginNarration() }
                }
                return
            }
            startCountdown { [weak self] in self?.beginNarration() }
        case .countdown:
            cancelCountdown()
        case .recording, .paused:
            stopNarration()
        case .finishing:
            break
        }
    }

    private func beginNarration() {
        guard let folder = production.folder else {
            recState = .idle
            return
        }
        selectScene(.camera)
        // Record to a new file; a camera or writer failure must preserve the previous narration.
        let url = folder.appendingPathComponent(".口播-\(UUID().uuidString).mp4")
        narrationOutputURL = url
        // The size comes from the first camera frame; the writer is created on arrival.
        let template = RecorderOptions(url: url, size: .zero, fps: settings.camera.frameRate, codec: .h264, bitrate: 0)
        narrationLock.lock()
        narrationPending = template
        narrationLock.unlock()
        if mixer.bgm.status().playing { mixer.bgm.pause() }
        markers = []
        live.elapsed = 0
        live.fileSize = 0
        recordingFiles = [url]
        recState = .recording
        recordingActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "正在录制口播")
        showToast("开始录口播：对着镜头把整节课讲完，不用操作电脑", icon: "record.circle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.narrationOutputURL == url, self.recState.isActive else { return }
            self.narrationLock.lock()
            let waiting = self.narrationPending != nil
            self.narrationLock.unlock()
            if waiting { self.stopNarration() }
        }
    }

    /// Camera capture thread.
    private func narrationFrame(_ f: CameraFrame) {
        narrationLock.lock()
        defer { narrationLock.unlock() }
        if var o = narrationPending {
            narrationPending = nil
            o.size = f.size
            // A talking head at 1080p: 12 Mbps is transparent and keeps hour-long narrations manageable.
            o.bitrate = Int(12_000_000 * max(0.5, Double(f.size.width * f.size.height) / (1920 * 1080)))
            do {
                try narrationRecorder.start(o)
            } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.recState = .idle
                    if let activity = self?.recordingActivity { ProcessInfo.processInfo.endActivity(activity) }
                    self?.recordingActivity = nil
                    self?.narrationOutputURL = nil
                    self?.restoreNarrationPlayback()
                    self?.showToast("无法开始录口播：\(error.localizedDescription)", icon: "exclamationmark.triangle")
                }
                return
            }
        }
        narrationRecorder.consume(f.processed, hostTime: f.captureTime)
    }

    private func stopNarration() {
        guard recState.isActive else { return }
        recState = .finishing
        narrationLock.lock()
        narrationPending = nil
        narrationLock.unlock()
        let pendingURL = narrationOutputURL
        narrationOutputURL = nil
        let duration = narrationRecorder.currentStats().duration
        narrationRecorder.stop(markers: []) { [weak self] result in
            guard let self else { return }
            self.recState = .idle
            if let a = self.recordingActivity { ProcessInfo.processInfo.endActivity(a) }
            self.recordingActivity = nil
            if result.files.count == 1, result.failedSegments.isEmpty,
               let recorded = result.files.first, let folder = self.production.folder {
                let destination = folder.appendingPathComponent(CourseProject.narrationFileName)
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        let backup = "口播-备份-\(Int(Date().timeIntervalSince1970)).mp4"
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: recorded, backupItemName: backup, options: .withoutDeletingBackupItem)
                    } else {
                        try FileManager.default.moveItem(at: recorded, to: destination)
                    }
                    let savedDuration = CMTimeGetSeconds(AVURLAsset(url: destination).duration)
                    let actualDuration = savedDuration.isFinite && savedDuration > 0 ? savedDuration : duration
                    self.production.setNarration(file: CourseProject.narrationFileName, duration: actualDuration)
                    self.showToast("口播已保存（\(formatTimecode(actualDuration))）。按播放开始配操作", icon: "checkmark.circle")
                } catch {
                    self.showToast("口播已录好，但更新项目失败：\(error.localizedDescription)。原口播仍保留", icon: "exclamationmark.triangle")
                }
            } else {
                self.restoreNarrationPlayback()
                let location = self.production.folder?.path ?? pendingURL?.deletingLastPathComponent().path ?? "当前项目"
                let detail = result.error?.localizedDescription
                    ?? (result.files.isEmpty && result.failedSegments.isEmpty ? "没有收到摄像头画面，请检查摄像头权限或设备" : "成功保存 \(result.files.count) 段，失败 \(result.failedSegments.count) 段")
                let message = "口播未能完整保存，未替换原口播。\(detail)。新录到的文件已保留，请检查项目：\(location)"
                self.production.reportError(message)
                self.showToast(message, icon: "exclamationmark.triangle")
            }
        }
    }

    private func restoreNarrationPlayback() {
        guard workMode == .production, !production.isLoaded,
              let project = production.project, project.hasNarration, let folder = production.folder else { return }
        production.open(project, folder: folder)
    }

    func exportProject() {
        guard let p = production.project, let folder = production.folder else { return }
        guard p.hasNarration else {
            showToast("先录口播，再导出", icon: "exclamationmark.triangle")
            return
        }
        guard exporter == nil else { return }
        guard exportProgress == nil, narrationImportProgress == nil, !projectActionInProgress, recState == .idle, !aiProduction.locksProject else { return }
        exportProgress = 0
        production.finishOperations { [weak self] in
            guard let self, self.production.folder == folder, let project = self.production.project else { return }
            self.beginProjectExport(project, folder: folder)
        }
    }

    private func beginProjectExport(_ project: CourseProject, folder: URL) {
        let ex = ProjectExporter(project: project, folder: folder, settings: settings, assets: assets, context: ciContext)
        exporter = ex
        exportProgress = 0
        ex.run(progress: { [weak self] p in self?.exportProgress = p }) { [weak self] result in
            guard let self else { return }
            self.exporter = nil
            self.exportProgress = nil
            switch result {
            case .success(let url):
                if var current = self.production.project {
                    current.outputFile = url.lastPathComponent
                    self.production.update(current)
                }
                self.lastRecording = url
                do {
                    try NarrationSubtitles.publish(for: project, folder: folder, movie: url)
                    let captionNote = project.subtitleFile == nil ? "" : "，SRT 字幕已同时保存"
                    self.showToast("成片已导出：\(url.lastPathComponent)\(captionNote)", icon: "checkmark.circle")
                } catch {
                    let message = "视频已导出，但字幕未能同步：\(error.localizedDescription)"
                    self.production.reportError(message)
                    self.showToast(message, icon: "exclamationmark.triangle")
                }
            case .failure(let error):
                self.showToast("导出失败：\(error.localizedDescription)", icon: "exclamationmark.triangle")
            }
        }
    }

    func cancelExport() {
        exporter?.cancel()
    }

    var exportedFileURL: URL? {
        guard let p = production.project, let f = p.outputFile, let folder = production.folder else { return nil }
        let url = folder.appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func stopRecording(mergeSegments: Bool = true) {
        guard recState.isActive else { return }
        if workMode == .production {
            stopNarration()
            return
        }
        recState = .finishing
        recorder.stop(markers: markers) { [weak self] result in
            guard let self else { return }
            self.engine.removeSink(self.recorder)
            if mergeSegments, !self.suppressRecordingMerge, self.settings.recording.mergeSegmentsOnStop, !self.isShuttingDown,
               self.testRecordingFolder == nil, result.files.count > 1, result.error == nil,
               result.failedSegments.isEmpty {
                self.mergeFinishedRecording(result, markers: self.markers) { [weak self] mergedResult in
                    self?.finishRecordingResult(mergedResult, showDefaultToast: false)
                }
                return
            }
            self.finishRecordingResult(result)
        }
    }

    private func finishRecordingResult(_ result: RecordingResult, showDefaultToast: Bool = true) {
            self.recState = .idle
            if let a = self.recordingActivity { ProcessInfo.processInfo.endActivity(a) }
            self.recordingActivity = nil
            if let first = result.files.first {
                self.lastRecording = first
                self.refreshRecent()
                let failed = result.failedSegments.isEmpty ? "" : "（第 \(result.failedSegments.map(String.init).joined(separator: "、")) 段没能保存）"
                let text = result.files.count == 1
                    ? "已保存：\(first.lastPathComponent)"
                    : "已保存 \(result.files.count) 段：\(first.deletingPathExtension().lastPathComponent) 等"
                if showDefaultToast { self.showToast(text + failed, icon: failed.isEmpty ? "checkmark.circle" : "exclamationmark.triangle") }
            } else {
                self.showToast("保存失败：\(result.error?.localizedDescription ?? "未知错误")", icon: "exclamationmark.triangle")
            }
            self.onRecordingFinished?(result)
    }

    func addMarker(_ kind: RecordingMarker.Kind) {
        guard recState.isActive else {
            showToast("录制中才能打点", icon: "flag")
            return
        }
        let t = recorder.recordingTime()
        let note = kind == .chapter ? "\(scene.title) · \(shortSourceName(sceneContent))" : "这里需要剪掉"
        markers.append(RecordingMarker(time: t, kind: kind, note: note))
        showToast("\(kind == .chapter ? "章节" : "口误")标记 \(formatTimecode(t))", icon: kind == .chapter ? "flag.fill" : "scissors")
    }

    private var sceneContent: SourceRef? {
        switch scene {
        case .camera: return nil
        case .slides: return slidesSource
        case .demo: return currentDemoSource
        case .split: return settings.split.content == .slides ? slidesSource : currentDemoSource
        }
    }

    func refreshRecent() {
        let folder = settings.recording.folderURL
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        recentRecordings = files.filter { $0.pathExtension.lowercased() == "mp4" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return a > b
            }
            .prefix(8).map { $0 }
    }

    // MARK: - Hotkeys

    func registerHotkeys() {
        var bindings = HotkeyAction.allCases.map { ($0, settings.combo(for: $0)) }.filter { !$0.1.isUnassigned }
        if settings.slides.clickerKeys {
            bindings.append((.slideNext, .pageDown))
            bindings.append((.slidePrev, .pageUp))
        }
        // While another app is in front and the slides are on screen, plain ← → flip slides.
        // When this app is in front, the local key monitor handles them so text fields keep working.
        if settings.slides.arrowKeys && slidesOnScreen && !NSApp.isActive {
            bindings.append((.slideNext, KeyCombo(keyCode: UInt32(kVK_RightArrow), modifiers: 0)))
            bindings.append((.slidePrev, KeyCombo(keyCode: UInt32(kVK_LeftArrow), modifiers: 0)))
        }
        let failed = HotkeyManager.shared.register(bindings)
        var seen = Set<HotkeyAction>()
        hotkeyFailures = failed.filter { seen.insert($0).inserted }
    }

    /// Assigns a combo; another action already using it becomes unbound.
    func setHotkey(_ action: HotkeyAction, _ combo: KeyCombo) {
        var map = settings.hotkeys
        for a in HotkeyAction.allCases where a != action && settings.combo(for: a) == combo {
            map[a.rawValue] = KeyCombo.unassigned
        }
        map[action.rawValue] = combo
        settings.hotkeys = map
    }

    // MARK: - Status

    private func startStatusTimer() {
        statusTimer?.invalidate()
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.updateStatus() }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    private func updateStatus() {
        statusTick += 1
        let lv = mixer.levels()
        live.micDB = lv.mic
        live.outDB = lv.output
        live.ducking = lv.ducking
        if recState.isActive || recState == .finishing {
            let rs = (workMode == .production ? narrationRecorder : recorder).currentStats()
            live.elapsed = rs.duration
            if live.dropped != rs.framesDropped { live.dropped = rs.framesDropped }
        }
        if statusTick % 5 == 0 {
            let st = engine.currentStats()
            live.renderFPS = narrationImportPreviewPaused ? 0 : st.fps
            live.renderMs = narrationImportPreviewPaused ? 0 : st.renderMs
            live.cameraFPS = narrationImportPreviewPaused || !cameraEnabled || !cameraStatus.running ? 0 : camera.measuredFPS
            live.cameraMs = narrationImportPreviewPaused || !cameraEnabled || !cameraStatus.running ? 0 : live.cameraMs * 0.6 + processor.lastProcessingMs * 0.4
            let b = mixer.bgm.status()
            if b != live.bgm { live.bgm = b }
            let z = engine.isZoomed
            if z != zoomed { zoomed = z }
        }
        if statusTick % 50 == 0, narrationImportPreviewPaused {
            perfLog.notice("preview paused for narration import; camera, playback processing and video rendering suspended")
        } else if statusTick % 50 == 0 {
            let st = engine.currentStats()
            let stages = processor.stageMs
            perfLog.notice("""
                camera \(self.live.cameraFPS, format: .fixed(precision: 1), privacy: .public) fps, \
                processing \(self.processor.lastProcessingMs, format: .fixed(precision: 1), privacy: .public) ms \
                [warp \(stages.warp, format: .fixed(precision: 1), privacy: .public), \
                wait \(stages.wait, format: .fixed(precision: 1), privacy: .public), \
                render \(stages.render, format: .fixed(precision: 1), privacy: .public)], \
                segmentation \(self.processor.lastSegmentationMs, format: .fixed(precision: 1), privacy: .public) ms | \
                output \(st.fps, format: .fixed(precision: 1), privacy: .public) fps, \
                render \(st.renderMs, format: .fixed(precision: 1), privacy: .public) ms, late \(st.late, privacy: .public)
                """)
        }
        if statusTick % 10 == 0, recState.isActive {
            live.fileSize = recordingFiles.reduce(Int64(0)) { sum, url in
                sum + (((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0)
            }
        }
        if statusTick % 300 == 0, recState.isActive,
           let free = try? settings.recording.folderURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
               .volumeAvailableCapacityForImportantUsage, free < 1_500_000_000 {
            showToast("磁盘只剩 \(free / 1_000_000) MB，请尽快结束录制或清理空间", icon: "externaldrive.badge.exclamationmark")
        }
    }

    func showToast(_ text: String, icon: String) {
        let t = Toast(text: text, icon: icon)
        toast = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            if self?.toast == t { self?.toast = nil }
        }
    }

    // MARK: - Thumbnails

    func makeThumbnails() {
        let assets = self.assets
        let s = settings
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var out: [String: NSImage] = [:]
            let size = CGSize(width: 192, height: 108)
            for p in AssetCatalog.cameraBackgrounds {
                if let cg = assets.cameraBackground(id: p.id, customPath: "", size: size) {
                    out["cam:\(p.id)"] = NSImage(cgImage: cg, size: size)
                }
            }
            if !s.background.customImagePath.isEmpty, let cg = assets.cameraBackground(id: "custom", customPath: s.background.customImagePath, size: size) {
                out["cam:custom"] = NSImage(cgImage: cg, size: size)
            }
            for p in AssetCatalog.demoBackdrops {
                if let cg = assets.demoBackdrop(id: p.id, customPath: "", size: size) {
                    out["demo:\(p.id)"] = NSImage(cgImage: cg, size: size)
                }
            }
            if !s.demo.customBackdropPath.isEmpty, let cg = assets.demoBackdrop(id: "custom", customPath: s.demo.customBackdropPath, size: size) {
                out["demo:custom"] = NSImage(cgImage: cg, size: size)
            }
            DispatchQueue.main.async { self?.thumbnails = out }
        }
    }

    // MARK: - Pickers

    func pickFiles(types: [UTType], multiple: Bool, directories: Bool = false, message: String) -> [URL] {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = multiple
        panel.canChooseDirectories = directories
        panel.canChooseFiles = true
        panel.message = message
        return panel.runModal() == .OK ? panel.urls : []
    }

    func importDeck() {
        let presentations = PresentationConverter.extensions.compactMap { UTType(filenameExtension: $0) }
        if let url = pickFiles(types: [.pdf, .image, .folder, .presentation] + presentations, multiple: false, directories: true,
                               message: "选择 PPT / PPTX / Keynote / PDF、一张图片，或一个装满幻灯片图片的文件夹").first {
            if settings.slides.deckPath == url.path {
                reloadDeck()
            } else {
                settings.slides.deckPath = url.path
            }
            if settings.slides.source == nil || settings.slides.source?.isCapture == true { settings.slides.source = .slides }
        }
    }

    func addBGM() {
        let urls = pickFiles(types: [.audio, .mp3, .mpeg4Audio, .wav, .aiff], multiple: true, message: "选择背景音乐（可多选）")
        guard !urls.isEmpty else { return }
        settings.bgm.tracks.append(contentsOf: urls.map(\.path).filter { !settings.bgm.tracks.contains($0) })
    }

    func chooseCameraBackground() {
        if let url = pickFiles(types: [.image], multiple: false, message: "选择一张虚拟背景图（建议 16:9，1920×1080 以上）").first {
            settings.background.customImagePath = url.path
            settings.background.preset = "custom"
            settings.background.mode = .image
        }
    }

    func chooseDemoBackdrop() {
        if let url = pickFiles(types: [.image], multiple: false, message: "选择演示场景的背景图").first {
            settings.demo.customBackdropPath = url.path
            settings.demo.backdrop = "custom"
        }
    }

    func chooseRecordingFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "选择录制文件的保存位置"
        if panel.runModal() == .OK, let url = panel.url {
            settings.recording.folder = url.path
            refreshRecent()
        }
    }

    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func openRecordingFolder() {
        let folder = settings.recording.folderURL
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
