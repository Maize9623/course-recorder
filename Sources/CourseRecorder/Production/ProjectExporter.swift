import Foundation
import AVFoundation
import CoreImage
import CoreGraphics
import Darwin

extension AppSettings {
    /// Whether the presenter's background is dark, so the watermark over it uses light text.
    var cameraBackgroundIsDark: Bool {
        switch background.mode {
        case .image: return background.preset == "custom" || (AssetCatalog.cameraBackgrounds.first { $0.id == background.preset }?.isDark ?? true)
        case .color: return (0.2126 * background.color.r + 0.7152 * background.color.g + 0.0722 * background.color.b) < 0.55
        case .off, .blur: return true
        }
    }

    var layoutConfig: LayoutConfig {
        LayoutConfig(pip: pip, camera: camera, demo: demo, slides: slides, split: split, overlay: overlay)
    }

    /// Preserve imported narration framing without changing the user's live-camera settings.
    func layoutConfig(for project: CourseProject?) -> LayoutConfig {
        var config = layoutConfig
        if project?.narrationIsImported == true {
            config.camera.fullZoom = 1
            config.camera.fullOffsetX = 0
            config.camera.fullOffsetY = 0
        }
        return config
    }

    var assetConfig: RenderEngine.AssetConfig {
        RenderEngine.AssetConfig(backdrop: demo.backdrop, customBackdrop: demo.customBackdropPath, overlay: overlay,
                                 borderColor: pip.borderColor, canvas: recording.outputSize,
                                 cameraBackgroundDark: cameraBackgroundIsDark)
    }
}

/// Renders a narration-first project offline: the narration stands in for the camera, the recorded takes for the
/// demo screen and the imported deck for the slides, all driven by the cues on the narration timeline and composed
/// by the same engine as the live preview.
final class ProjectExporter {
    struct ExportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private let project: CourseProject
    private let folder: URL
    private let settings: AppSettings
    private let assets: AssetFactory
    private let context: CIContext
    private let cancelLock = NSLock()
    private var cancelled = false

    init(project: CourseProject, folder: URL, settings: AppSettings, assets: AssetFactory, context: CIContext) {
        self.project = project
        self.folder = folder
        var effectiveSettings = settings
        effectiveSettings.recording.aspect = project.outputAspect ?? .landscape
        self.settings = effectiveSettings
        self.assets = assets
        self.context = context
    }

    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    /// `progress` and `completion` are called on the main thread.
    func run(progress: @escaping (Double) -> Void, completion: @escaping (Result<URL, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let result = Result { try execute(progress: progress) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func execute(progress: @escaping (Double) -> Void) throws -> URL {
        guard let narrationFile = project.narrationFile, project.narrationDuration > 0 else { throw ExportError(message: "还没有录口播") }
        let narrationURL = folder.appendingPathComponent(narrationFile)
        guard let video = VideoFrameReader(url: narrationURL) else { throw ExportError(message: "无法读取口播视频") }
        defer { video.cancel() }
        guard let audio = AudioSampleStream(url: narrationURL) else { throw ExportError(message: "口播没有可读取的音轨，请先回放检查口播文件。") }
        defer { audio.cancel() }
        func checkCancellation() throws {
            if isCancelled { throw ExportError(message: "已取消导出") }
        }
        try checkCancellation()
        // Resolve project-local music before creating any writer or render resources.
        let musicTracks = try ProjectMusicFiles.tracks(for: project, folder: folder, defaults: settings.bgm.tracks)
        let duration = project.narrationDuration
        let fps = settings.recording.fps
        let dt = 1.0 / Double(fps)
        let canvas = settings.recording.outputSize

        // The same pipeline as the live preview, fed from files instead of devices.
        let store = FrameStore()
        let processor = CameraProcessor(context: context, assets: assets)
        var pc = CameraProcessingConfig(background: settings.background, camera: settings.camera, beauty: settings.beauty,
                                        needCutout: settings.pip.shape == .cutout || settings.split.cutout)
        pc.preprocessed = true
        processor.update(pc)
        let engine = RenderEngine(context: context, store: store, assets: assets, cursor: CursorTracker(), canvasSize: canvas)
        engine.update(config: settings.layoutConfig(for: project), transitions: settings.transitions)
        let ready = DispatchSemaphore(value: 0)
        engine.applyAssets(settings.assetConfig) { ready.signal() }
        guard ready.wait(timeout: .now() + 30) == .success else { throw ExportError(message: "准备导出画面超时，请重试。") }
        try checkCancellation()

        var deck: SlideDeck?
        if !project.deckPath.isEmpty {
            let url = URL(fileURLWithPath: project.deckPath)
            var path = project.deckPath
            if PresentationConverter.extensions.contains(url.pathExtension.lowercased()) {
                path = try PresentationConverter.convert(url).path
            }
            deck = SlideDeck(path: path, title: url.deletingPathExtension().lastPathComponent)
            engine.setDeck(deck)
            _ = deck?.renderNow(0, size: canvas)
        }
        engine.resetAnimations()
        engine.cursorOverride = CGPoint(x: 0.5, y: 0.5)

        let output = folder.appendingPathComponent(CourseProject.outputFileName)
        // Keep all writer recovery segments together; the previous finished movie stays untouched.
        let temporaryFolder = folder.appendingPathComponent(".course-export-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryFolder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let temporaryOutput = temporaryFolder.appendingPathComponent(CourseProject.outputFileName)
        let recorder = Recorder()
        let finalization = ExportWriterFinalization()
        var stopRequested = false
        var writerClosed = false
        var preserveTemporary = false
        func finishWriter() throws -> RecordingResult {
            if !stopRequested {
                stopRequested = true
                recorder.stop(markers: []) { finalization.resolve($0) }
            }
            guard let result = finalization.wait(seconds: 60) else {
                preserveTemporary = true
                throw ExportError(message: "编码器保存超时，原成片未改动。为避免删除仍在写入的文件，临时文件保留在：\(temporaryFolder.path)")
            }
            writerClosed = true
            return result
        }

        do {
            try checkCancellation()
            try recorder.start(RecorderOptions(url: temporaryOutput, size: canvas, fps: fps, codec: settings.recording.codec,
                                               bitrate: settings.recording.videoBitrate, segmentSeconds: nil, offline: true))

            let mixer = AudioMixer()
            defer { mixer.onMixed = nil; mixer.bgm.pause() }
            mixer.trustsTimestamps = true
            let bgm = settings.bgm
            let useBGM = !musicTracks.isEmpty
            mixer.update(MixerConfig(micGain: 1, highPass: false, gate: false, gateThresholdDB: settings.audio.gateThresholdDB,
                                     limiter: true, systemGain: 0, bgmGain: useBGM ? dbToLinear(bgm.volumeDB) : 0,
                                     ducking: bgm.ducking, duckGain: dbToLinear(bgm.duckDB), micMuted: false, avOffset: 0))
            if useBGM {
                mixer.bgm.setTracks(musicTracks)
                mixer.bgm.loopMode = bgm.loopMode
                mixer.bgm.setFadeSeconds(bgm.fadeSeconds)
                mixer.bgm.play()
            }
            mixer.onMixed = { [weak recorder] sb in recorder?.appendAudio(sb) }

            var audioTime = 0.0
            var audioDone = false
            func feedAudioChunk() {
                guard !audioDone, let chunk = audio.next() else {
                    audioDone = true
                    recorder.finishAudioInput()
                    return
                }
                chunk.samples.withUnsafeBufferPointer { p in
                    mixer.processMic(p.baseAddress!, frames: chunk.samples.count, pts: chunk.pts)
                }
                audioTime = chunk.pts + Double(chunk.samples.count) / 48000
            }
            /// Audio is kept a little ahead of the picture, but only while the writer accepts it.
            func feedAudio(until limit: Double) {
                while !audioDone, audioTime < limit, recorder.inputReadiness.audio { feedAudioChunk() }
            }

            let cues = project.sortedCues
            var sources = SceneSources()
            var cueIndex = 0
            var cursorIndex = 0
            var clickIndex = 0
            var takeReader: (take: Take, reader: VideoFrameReader)?
            defer { takeReader?.reader.cancel() }
            var lastNarration: CVPixelBuffer?
            var lastTake: CVPixelBuffer?
            var lastProgress = -1.0
            let frames = Int((duration * Double(fps)).rounded(.up))

            for i in 0..<frames {
                try checkCancellation()
                let t = Double(i) * dt

                while cueIndex < cues.count, cues[cueIndex].time <= t {
                    let cue = cues[cueIndex]
                    let instant = cue.time <= 0.001
                    switch cue.action {
                    case .scene(let s):
                        engine.setScene(s, animated: !instant, at: t)
                    case .slide(let index):
                        _ = deck?.renderNow(index, size: canvas)
                        engine.setSlide(index, at: instant ? t - 10 : t)
                    case .demoSource(let ref):
                        sources.demo = ref
                        engine.setSources(sources, at: t)
                    case .slidesSource(let ref):
                        sources.slides = ref
                        engine.setSources(sources, at: t)
                    case .pip(let visible):
                        engine.setPIPVisible(visible, at: instant ? t - 10 : t)
                    case .zoom(let on):
                        engine.setZoom(on, at: t)
                    case .lowerThird:
                        engine.showLowerThird(seconds: settings.overlay.lowerThirdSeconds, at: t)
                    }
                    cueIndex += 1
                }

                if let pb = video.frame(at: t), pb !== lastNarration {
                    lastNarration = pb
                    if let frame = processor.process(pb, hostTime: t) { store.setCamera(frame) }
                }

                if let take = project.take(at: t) {
                    if takeReader?.take.id != take.id {
                        takeReader?.reader.cancel()
                        takeReader = VideoFrameReader(url: folder.appendingPathComponent(take.file), from: max(0, t - take.start))
                            .map { (take, $0) }
                        lastTake = nil
                    }
                    if let tr = takeReader, let pb = tr.reader.frame(at: t - take.start), pb !== lastTake {
                        lastTake = pb
                        store.setScreen(ScreenFrame(pixelBuffer: pb, contentRect: take.contentRect, hostTime: t), for: take.source)
                    }
                }

                while cursorIndex < project.cursor.count, project.cursor[cursorIndex].t <= t {
                    let c = project.cursor[cursorIndex]
                    engine.cursorOverride = CGPoint(x: c.x, y: c.y)
                    cursorIndex += 1
                }
                while clickIndex < project.clicks.count, project.clicks[clickIndex].t <= t {
                    let c = project.clicks[clickIndex]
                    engine.injectClick(CGPoint(x: c.x, y: c.y), at: c.t)
                    clickIndex += 1
                }

                guard let pb = engine.renderFrame(at: t) else { continue }
                // The writer interleaves video and audio: while it holds the video input, give it the audio it is waiting for.
                var stalled = 0
                while !recorder.inputReadiness.video {
                    if !audioDone, audioTime < t + 2, recorder.inputReadiness.audio {
                        feedAudioChunk()
                    } else {
                        usleep(1000)
                        stalled += 1
                        if stalled > 15000 { throw ExportError(message: "编码器没有响应") }
                    }
                    try checkCancellation()
                }
                try checkCancellation()
                recorder.consume(pb, hostTime: t)
                feedAudio(until: t + dt + 0.25)

                let p = Double(i) / Double(frames)
                if p - lastProgress >= 0.005 {
                    lastProgress = p
                    DispatchQueue.main.async { progress(p) }
                }
            }
            var tail = 0
            while !audioDone, audioTime < duration, tail < 15000 {
                try checkCancellation()
                if recorder.inputReadiness.audio { feedAudioChunk() } else { usleep(1000); tail += 1 }
            }
            if !audioDone && audioTime < duration { throw ExportError(message: "编码器没有响应，口播声音未能写完。") }
            recorder.finishAudioInput()

            let result = try finishWriter()
            try checkCancellation()
            guard result.error == nil, result.failedSegments.isEmpty,
                  result.files.count == 1, result.files.first == temporaryOutput else {
                throw result.error ?? ExportError(message: "成片没能写完")
            }
            // Both paths are on the project volume. POSIX rename replaces an existing file atomically.
            let moved = temporaryOutput.withUnsafeFileSystemRepresentation { source in
                output.withUnsafeFileSystemRepresentation { target in Darwin.rename(source!, target!) }
            }
            if moved != 0 {
                let reason = NSError(domain: NSPOSIXErrorDomain, code: Int(errno)).localizedDescription
                throw ExportError(message: "无法保存新成片，原成片未改动：\(reason)")
            }
            try? FileManager.default.removeItem(at: temporaryFolder)
            return output
        } catch {
            let originalError = error
            if !writerClosed && !preserveTemporary {
                do { _ = try finishWriter() }
                catch { throw ExportError(message: "\(originalError.localizedDescription)；\(error.localizedDescription)") }
            }
            if preserveTemporary { throw originalError }
            do { try FileManager.default.removeItem(at: temporaryFolder) }
            catch {
                throw ExportError(message: "\(originalError.localizedDescription)。原成片未改动，临时文件清理失败，请稍后清理：\(temporaryFolder.path)")
            }
            throw originalError
        }
    }
}

/// The stop callback runs on the main thread; the export worker joins it without unsynchronized state.
private final class ExportWriterFinalization {
    private let condition = NSCondition()
    private var result: RecordingResult?

    func resolve(_ value: RecordingResult) {
        condition.lock()
        result = value
        condition.broadcast()
        condition.unlock()
    }

    func wait(seconds: TimeInterval) -> RecordingResult? {
        condition.lock()
        defer { condition.unlock() }
        let deadline = Date().addingTimeInterval(seconds)
        while result == nil {
            if !condition.wait(until: deadline) { break }
        }
        return result
    }
}
