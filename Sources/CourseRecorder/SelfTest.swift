import Foundation
import AppKit
import AVFoundation
import CoreImage
import Metal

/// `CourseRecorder --selftest <outDir> [cameraImage]`
/// Renders every scene and key transition frames to PNG and records a short MP4 through the real pipeline.
enum SelfTest {
    static func run(_ args: [String]) -> Int32 {
        let outDir = URL(fileURLWithPath: args.first ?? "selftest-out", isDirectory: true)
        let cameraPath = args.count > 1 ? args[1] : nil
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else {
            print("Metal unavailable")
            return 1
        }
        let ctx = CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .name: "selftest"])
        let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
        let assets = AssetFactory(context: ctx)
        let store = FrameStore()
        let cursor = CursorTracker()
        let size = CGSize(width: 1920, height: 1080)
        let engine = RenderEngine(context: ctx, store: store, assets: assets, cursor: cursor, canvasSize: size)

        func save(_ image: CIImage, _ name: String) {
            let url = outDir.appendingPathComponent(name)
            do {
                try ctx.writePNGRepresentation(of: image.cropped(to: image.extent), to: url, format: .RGBA8, colorSpace: srgb)
            } catch {
                print("save failed \(name): \(error)")
            }
        }

        var overlay = OverlaySettings()
        overlay.watermarkEnabled = true
        overlay.watermarkScenes = [.demo]
        overlay.lowerThirdName = "Gene"
        overlay.lowerThirdTitle = "AI 协作系统课程主讲"
        let assetsDone = DispatchSemaphore(value: 0)
        engine.applyAssets(RenderEngine.AssetConfig(backdrop: "lavender", customBackdrop: "", overlay: overlay,
                                                    borderColor: RGBA(r: 1, g: 1, b: 1, a: 0.92), canvas: size)) {
            assetsDone.signal()
        }
        assetsDone.wait()

        // Camera through the real processing path (Vision segmentation + virtual background).
        let processor = CameraProcessor(context: ctx, assets: assets)
        var pc = CameraProcessingConfig()
        pc.background.mode = .image
        pc.background.preset = "studio-purple"
        pc.needCutout = true
        pc.camera.faceTracking = true
        processor.update(pc)
        let camImage = cameraPath.flatMap { assets.loadImage(path: $0) } ?? syntheticPerson(assets: assets)
        guard let camImage, let camPB = makePixelBuffer(camImage, ctx: ctx) else {
            print("no camera image")
            return 1
        }
        _ = processor.process(camPB, hostTime: 0)
        Thread.sleep(forTimeInterval: 1.2)
        var frame: CameraFrame?
        let tCam = CACurrentMediaTime()
        for _ in 0..<12 { frame = processor.process(camPB, hostTime: 0) }
        print(String(format: "camera processing: %.1f ms/frame (balanced, with cutout)", (CACurrentMediaTime() - tCam) / 12 * 1000))
        guard let frame else { return 1 }
        print("face:", frame.face.map { String(format: "%.3f, %.3f", $0.x, $0.y) } ?? "none")
        beautyAndMatteTest(processor: processor, input: camPB, base: pc, save: save)
        store.setCamera(frame)
        save(CIImage(cvPixelBuffer: frame.processed), "camera_processed.png")
        for preset in AssetCatalog.cameraBackgrounds {
            if let bg = assets.cameraBackground(id: preset.id, customPath: "", size: CGSize(width: 960, height: 540)) {
                save(CIImage(cgImage: bg), "bg_\(preset.id).png")
            }
        }
        for preset in AssetCatalog.demoBackdrops {
            if let bg = assets.demoBackdrop(id: preset.id, customPath: "", size: CGSize(width: 960, height: 540)) {
                save(CIImage(cgImage: bg), "backdrop_\(preset.id).png")
            }
        }

        // Screens
        if let ui = mockAppWindow(CGSize(width: 2880, height: 1800), assets: assets), let pb = makePixelBuffer(ui, ctx: ctx) {
            store.setScreen(ScreenFrame(pixelBuffer: pb, contentRect: CGRect(x: 0, y: 0, width: 2880, height: 1800), hostTime: 0), for: .display(1))
        }
        if let page = mockResultPage(CGSize(width: 3840, height: 2160), assets: assets), let pb = makePixelBuffer(page, ctx: ctx) {
            store.setScreen(ScreenFrame(pixelBuffer: pb, contentRect: CGRect(x: 0, y: 0, width: 3840, height: 2160), hostTime: 0), for: .display(2))
        }

        // Slides
        let pdfURL = outDir.appendingPathComponent("test-deck.pdf")
        makeDeck(pdfURL, assets: assets)
        guard let deck = SlideDeck(path: pdfURL.path) else {
            print("deck failed")
            return 1
        }
        _ = deck.renderNow(0, size: size)
        _ = deck.renderNow(1, size: size)
        engine.setDeck(deck)

        var lc = LayoutConfig()
        lc.overlay = overlay
        engine.update(config: lc, transitions: TransitionSettings())
        engine.setSources(SceneSources(slides: .slides, demo: .display(1)))

        func shot(_ name: String, _ t: Double) {
            if let pb = engine.renderFrame(at: t) { save(CIImage(cvPixelBuffer: pb), name) }
        }

        var T = CACurrentMediaTime()
        func settle(_ s: SceneKind) {
            engine.setScene(s, animated: false, at: T)
            _ = engine.renderFrame(at: T)
            T += 0.02
        }

        // Steady states
        for s in SceneKind.allCases {
            settle(s)
            shot("scene_\(s.number)_\(s.rawValue).png", T)
        }
        lc.overlay.watermarkEnabled = false
        engine.update(config: lc, transitions: TransitionSettings())
        settle(.camera)
        settle(.demo)
        shot("scene_3_demo_no_watermark.png", T)
        lc.overlay.watermarkEnabled = true
        engine.update(config: lc, transitions: TransitionSettings())
        let tPerf = CACurrentMediaTime()
        for i in 0..<60 { _ = engine.renderFrame(at: T + Double(i) / 60) }
        print(String(format: "compose+render (split): %.2f ms/frame", (CACurrentMediaTime() - tPerf) / 60 * 1000))
        settle(.demo)
        let tPerf2 = CACurrentMediaTime()
        for i in 0..<60 { _ = engine.renderFrame(at: T + Double(i) / 60) }
        print(String(format: "compose+render (demo): %.2f ms/frame", (CACurrentMediaTime() - tPerf2) / 60 * 1000))
        T += 1.2

        // 1 → 3: presenter shrinks into the bubble
        settle(.camera)
        T += 0.5
        engine.setScene(.demo, animated: true, at: T)
        for p in [0.15, 0.35, 0.5, 0.65, 0.85] { shot("tr_cam_to_demo_\(Int(p * 100)).png", T + 0.7 * p) }
        T += 1.0
        _ = engine.renderFrame(at: T)

        // Display switch (push)
        engine.setSources(SceneSources(slides: .slides, demo: .display(2)), direction: 1, at: T)
        for p in [0.3, 0.6] { shot("tr_push_\(Int(p * 100)).png", T + 0.55 * p) }
        T += 1.0
        _ = engine.renderFrame(at: T)

        // Hide / show bubble
        engine.setPIPVisible(false, at: T)
        shot("pip_hide_50.png", T + 0.2)
        shot("pip_hidden.png", T + 0.6)
        T += 1.0
        engine.setPIPVisible(true, at: T)
        shot("pip_show_60.png", T + 0.24)
        T += 1.0
        _ = engine.renderFrame(at: T)

        // Zoom follow
        engine.cursorOverride = CGPoint(x: 0.3, y: 0.35)
        engine.setZoom(true, at: T)
        shot("zoom_50.png", T + 0.3)
        shot("zoom_full.png", T + 0.9)
        engine.setZoom(false, at: T + 1.0)
        engine.cursorOverride = nil
        T += 2.0
        _ = engine.renderFrame(at: T)

        // Lower third
        engine.showLowerThird(seconds: 4, at: T)
        shot("lower_third.png", T + 0.8)
        T += 5
        _ = engine.renderFrame(at: T)

        // 3 → 4 → 1
        settle(.slides)
        T += 0.5
        engine.setScene(.split, animated: true, at: T)
        for p in [0.3, 0.6] { shot("tr_slides_to_split_\(Int(p * 100)).png", T + 0.7 * p) }
        T += 1.0
        _ = engine.renderFrame(at: T)
        engine.setScene(.camera, animated: true, at: T)
        for p in [0.4] { shot("tr_split_to_cam_\(Int(p * 100)).png", T + 0.7 * p) }
        T += 1.0
        _ = engine.renderFrame(at: T)

        // 2 → 3 content crossfade
        settle(.slides)
        T += 0.5
        engine.setScene(.demo, animated: true, at: T)
        shot("tr_slides_to_demo_50.png", T + 0.35)
        T += 1.0
        _ = engine.renderFrame(at: T)

        // Slide change
        settle(.slides)
        engine.setSlide(1, at: T)
        shot("slide_change_50.png", T + 0.17)
        T += 1
        _ = engine.renderFrame(at: T)

        // Variants: rounded bubble, cutout bubble, split with cutout
        lc.pip.shape = .rounded
        engine.update(config: lc, transitions: TransitionSettings())
        settle(.demo)
        shot("variant_pip_rounded.png", T)
        lc.pip.shape = .cutout
        engine.update(config: lc, transitions: TransitionSettings())
        shot("variant_pip_cutout.png", T + 0.05)
        lc.pip.shape = .circle
        settle(.split)
        T += 1
        let splitVariants: [(String, (inout SplitSettings) -> Void)] = [
            ("split_left_fit", { $0.cameraOnRight = false }),
            ("split_left_card", { $0.cameraOnRight = false; $0.cardStyle = true }),
            ("split_right_fit_cutout", { $0.cutout = true }),
            ("split_right_overlay", { $0.fitContent = false; $0.edgeSoftness = 0.13; $0.personWidth = 0.46 }),
        ]
        for (name, apply) in splitVariants {
            var s = SplitSettings()
            apply(&s)
            lc.split = s
            engine.update(config: lc, transitions: TransitionSettings())
            T += 0.05
            shot("variant_\(name).png", T)
        }
        lc.split = SplitSettings()
        engine.update(config: lc, transitions: TransitionSettings())

        // Demo screen alignment (left / center / right, and avoiding the bubble)
        store.setScreen(store.screen(.display(1))!, for: .display(1))
        engine.setSources(SceneSources(slides: .slides, demo: .display(1)), style: .cut)
        settle(.demo)
        for (name, align, avoid) in [("left", -1.0, false), ("right", 1.0, false), ("avoid", 0.0, true)] {
            lc.demo.contentAlign = align
            lc.demo.avoidPIP = avoid
            engine.update(config: lc, transitions: TransitionSettings())
            T += 1
            shot("demo_align_\(name).png", T)
        }
        lc.demo.contentAlign = 0
        lc.demo.avoidPIP = false
        engine.update(config: lc, transitions: TransitionSettings())

        // Portrait PDF page: default view (top of page), pan down, zoom in
        let docURL = outDir.appendingPathComponent("test-portrait.pdf")
        makePortraitDoc(docURL, assets: assets)
        if let doc = SlideDeck(path: docURL.path) {
            _ = doc.renderNow(0, size: size)
            engine.setDeck(doc)
            engine.setSources(SceneSources(slides: .slides, demo: .display(1)), style: .cut)
            settle(.slides)
            T += 0.5
            shot("pdf_default_top.png", T)
            engine.slideView(.pan(CGVector(dx: 0, dy: -0.8)))
            T += 0.1
            shot("pdf_panned_down.png", T)
            engine.slideView(.zoom(1.8, CGPoint(x: 0.3, y: 0.4)))
            T += 0.1
            shot("pdf_zoomed.png", T)
            engine.slideView(.reset)
            engine.setDeck(deck)
        }

        let readerOK = audioReaderTest()

        // Recording through the real writer + mixer
        let ok = recordTest(engine: engine, outDir: outDir, size: size) && readerOK
        print("selftest finished, output in \(outDir.path)")
        return ok ? 0 : 2
    }

    private static func recordTest(engine: RenderEngine, outDir: URL, size: CGSize) -> Bool {
        let url = outDir.appendingPathComponent("record-test.mp4")
        let wav = outDir.appendingPathComponent("bgm-test.wav")
        makeTone(wav, seconds: 8)
        let recorder = Recorder()
        do {
            try recorder.start(RecorderOptions(url: url, size: size, fps: 60, codec: .h264, bitrate: 16_000_000))
        } catch {
            print("recorder start failed: \(error)")
            return false
        }
        let mixer = AudioMixer()
        mixer.onMixed = { recorder.appendAudio($0) }
        var mc = MixerConfig()
        mc.bgmGain = 0.25
        mixer.update(mc)
        mixer.bgm.setTracks([wav.path])
        mixer.bgm.setFadeSeconds(0.5)
        mixer.bgm.play()

        let base = CACurrentMediaTime()
        engine.setScene(.camera, animated: false, at: base)
        engine.setSources(SceneSources(slides: .slides, demo: .display(1)), at: base)
        var voice = [Float](repeating: 0, count: 800)
        var phase: Double = 0
        for i in 0..<300 {
            let t = base + Double(i) / 60
            if i == 60 { engine.setScene(.demo, animated: true, at: t) }
            if i == 150 { engine.setSources(SceneSources(slides: .slides, demo: .display(2)), direction: 1, at: t) }
            if i == 220 { engine.setPIPVisible(false, at: t) }
            if i == 120 { recorder.pause(at: t) }
            if i == 160 { recorder.resume(at: t) }
            if let pb = engine.renderFrame(at: t) { recorder.consume(pb, hostTime: t) }
            let speaking = (Int(Double(i) / 30) % 2) == 0
            for k in 0..<800 {
                phase += 2 * Double.pi * 220 / 48000
                voice[k] = speaking ? Float(sin(phase) * 0.25) : 0
            }
            voice.withUnsafeBufferPointer { mixer.processMic($0.baseAddress!, frames: 800, pts: t) }
            usleep(5000)
        }
        var finished = false
        var result: URL?
        recorder.stop(markers: [RecordingMarker(time: 1.0, kind: .chapter, note: "进入演示"),
                                RecordingMarker(time: 3.2, kind: .mistake, note: "测试口误")]) { r in
            result = r.files.first
            if let e = r.error { print("finish error: \(e)") }
            finished = true
        }
        let deadline = Date().addingTimeInterval(20)
        while !finished && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let stats = recorder.currentStats()
        print("record test: \(result?.path ?? "FAILED"), frames written \(stats.framesWritten), dropped \(stats.framesDropped)")
        return result != nil
    }

    /// `--camera-bench <image>`: per-frame cost of the presenter pipeline for the main setting combinations.
    static func cameraBench(_ imagePath: String) -> Int32 {
        guard let device = MTLCreateSystemDefaultDevice() else { return 1 }
        let ctx = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let assets = AssetFactory(context: ctx)
        guard let cg = assets.loadImage(path: imagePath), let pb = makePixelBuffer(cg, ctx: ctx) else { return 1 }
        let processor = CameraProcessor(context: ctx, assets: assets)
        var base = CameraProcessingConfig()
        base.background.mode = .image
        processor.update(base)
        _ = processor.process(pb, hostTime: 0)
        Thread.sleep(forTimeInterval: 1)
        let cases: [(String, (inout CameraProcessingConfig) -> Void)] = [
            ("均衡 · 无美颜", { $0.beauty.enabled = false }),
            ("均衡 · 自然美颜", { $0.beauty = BeautySettings() }),
            ("均衡 · 美颜+大眼", { $0.beauty = BeautySettings(enabled: true, smooth: 0.6, whiten: 0.45, rosy: 0.25, slim: 0.35, eyes: 0.25, clarity: 0.3) }),
            ("精细 · 无美颜", { $0.beauty.enabled = false; $0.background.quality = .accurate }),
            ("精细 · 自然美颜", { $0.beauty = BeautySettings(); $0.background.quality = .accurate }),
        ]
        for (name, apply) in cases {
            var c = base
            apply(&c)
            processor.update(c)
            for i in 0..<4 { _ = processor.process(pb, hostTime: Double(i) / 30) }
            let t0 = CACurrentMediaTime()
            let n = 20
            for i in 0..<n { _ = processor.process(pb, hostTime: Double(i) / 30) }
            print(String(format: "%@: %.1f ms/frame", name, (CACurrentMediaTime() - t0) / Double(n) * 1000))
        }
        return 0
    }

    /// `--writer-test <dir>`: the real Recorder + AudioMixer fed in real time across several movie fragments.
    static func writerTest(_ dir: String, seconds: Double, offset: Double, mode: String) -> Int32 {
        let duplicateFrames = mode.contains("dup")
        let jitter = mode.contains("jitter")
        // Noise frames encode at the bitrate cap, like real camera + screen content.
        let noise = mode.contains("noise")
        let failMidway = mode.contains("fail")
        let noiseImage = CIFilter(name: "CIRandomGenerator")!.outputImage!
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { return 1 }
        let ctx = CIContext(mtlDevice: device)
        let size = mode.contains("portrait") ? CGSize(width: 1440, height: 2560) : CGSize(width: 2560, height: 1440)
        guard let pool = CameraProcessor.makePool(size) else { return 1 }
        let name = "writer-\(Int(seconds))s-offset\(Int(offset * 1000))-\(mode).mp4"
        let url = outDir.appendingPathComponent(name)
        let recorder = Recorder()
        let segment = mode.range(of: #"seg\d+"#, options: .regularExpression).flatMap { Double(mode[$0].dropFirst(3)) }
        do {
            try recorder.start(RecorderOptions(url: url, size: size, fps: 60, codec: .h264, bitrate: 28_000_000,
                                               segmentSeconds: segment))
        } catch {
            print("start failed: \(error)")
            return 1
        }
        var failure: Error?
        var events: [String] = []
        recorder.onFailure = { failure = $0 }
        recorder.onSegmentStarted = { u, n, why in events.append("start #\(n) \(u.lastPathComponent)\(why.map { " (\($0.localizedDescription))" } ?? "")") }
        recorder.onSegmentSaved = { _, n, e in events.append("saved #\(n) \(e.map { "error \($0)" } ?? "ok")") }
        let mixer = AudioMixer()
        mixer.onMixed = { recorder.appendAudio($0) }
        var mc = MixerConfig()
        mc.avOffset = offset
        mixer.update(mc)

        let start = CACurrentMediaTime()
        var frame = 0
        var lastBuffer: CVPixelBuffer?
        var micPhase = 0.0
        var nextAudio = start
        var tone = [Float](repeating: 0, count: 1024)
        while CACurrentMediaTime() - start < seconds {
            let now = CACurrentMediaTime()
            // Video at 60 fps
            if Double(frame) / 60 <= now - start {
                var pb: CVPixelBuffer?
                if duplicateFrames, frame % 2 == 1, let last = lastBuffer {
                    pb = last
                } else {
                    CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
                    if let pb {
                        let hue = CGFloat(frame % 120) / 120
                        let image = noise
                            ? noiseImage.transformed(by: CGAffineTransform(translationX: CGFloat(frame * 37 % 997), y: CGFloat(frame * 53 % 991)))
                            : CIImage(color: CIColor(red: hue, green: 0.4, blue: 1 - hue))
                        ctx.render(image.cropped(to: CGRect(origin: .zero, size: size)),
                                   to: pb, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
                    }
                }
                // A late render tick skips a frame index, as the live render loop occasionally does.
                if mode.contains("skip"), frame % 97 == 50 { frame += 1 }
                if let pb { recorder.consume(pb, hostTime: start + Double(frame) / 60) }
                lastBuffer = pb
                frame += 1
                if failMidway, frame == Int(seconds * 30) { recorder.simulateWriterFailure() }
            }
            // Microphone: 20 ms buffers stamped like capture buffers (slightly in the past). With jitter, buffer
            // sizes and timestamps wobble the way a resampled hardware microphone does.
            if now >= nextAudio {
                let n = jitter ? 960 + Int.random(in: -12...12) : 960
                for k in 0..<n {
                    micPhase += 2 * Double.pi * 330 / 48000
                    tone[k] = Float(sin(micPhase) * 0.2)
                }
                let pts = nextAudio - 0.03 + (jitter ? Double.random(in: -0.0015...0.0015) : 0)
                tone.withUnsafeBufferPointer { mixer.processMic($0.baseAddress!, frames: n, pts: pts) }
                nextAudio += 0.02
            }
            usleep(1000)
        }
        var done = false
        var result = RecordingResult()
        let marks = stride(from: 2.5, to: seconds, by: 5).map { RecordingMarker(time: $0, kind: .chapter, note: "第 \($0) 秒") }
        let stopAt = recorder.recordingTime()
        recorder.stop(markers: marks) { r in
            result = r
            done = true
        }
        let deadline = Date().addingTimeInterval(30)
        while !done && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        let st = recorder.currentStats()
        for e in events { print("  \(e)") }
        print("\(name): files=\(result.files.map(\.lastPathComponent)) failedSegments=\(result.failedSegments) error=\(result.error.map { "\($0)" } ?? "none") failure=\(failure.map { "\($0)" } ?? "none") written=\(st.framesWritten) dropped=\(st.framesDropped) recorded=\(String(format: "%.2f", stopAt))s")
        return !result.files.isEmpty && result.failedSegments.isEmpty && failure == nil ? 0 : 2
    }

    // MARK: - Narration-first production

    /// `--production-test <dir> [cameraImage] [deck]`: records a synthetic narration, runs a real production pass
    /// (playback + cues + a take), exports the project and prints the result.
    static func productionTest(_ dir: String, camImage: String?, deck deckPath: String) -> Int32 {
        let outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.removeItem(at: outDir.appendingPathComponent("项目"))
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { return 1 }
        let ctx = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let assets = AssetFactory(context: ctx)
        var settings = AppSettings()
        settings.recording.resolution = .p1080
        settings.recording.fps = 30
        settings.recording.quality = .standard
        settings.slides.deckPath = deckPath
        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

        // Presenter: a processed camera frame (static picture) as the narration.
        let camURL = camImage.map { URL(fileURLWithPath: $0) }
        guard let camCG = camURL.flatMap({ assets.loadImage(path: $0.path) }) ?? syntheticPerson(assets: assets), let camPB = makePixelBuffer(camCG, ctx: ctx) else {
            print("need a camera image")
            return 1
        }
        let processor = CameraProcessor(context: ctx, assets: assets)
        processor.update(CameraProcessingConfig(background: settings.background, camera: settings.camera, beauty: settings.beauty, needCutout: false))
        var presenter: CameraFrame?
        for _ in 0..<6 { presenter = processor.process(camPB, hostTime: 0) }
        guard let presenter else { return 1 }

        // 1. Project with a 10 s narration (tone as the voice).
        let (project0, folder): (CourseProject, URL)
        do { (project0, folder) = try ProjectStore.create(named: "测试项目", deckPath: deckPath, in: outDir) } catch {
            print("project: \(error)")
            return 1
        }
        let narration = Recorder()
        let narrationURL = folder.appendingPathComponent(CourseProject.narrationFileName)
        do {
            try narration.start(RecorderOptions(url: narrationURL, size: presenter.size, fps: 30, codec: .h264, bitrate: 8_000_000, offline: true))
        } catch {
            print("narration: \(error)")
            return 1
        }
        let mixer = AudioMixer()
        mixer.trustsTimestamps = true
        mixer.onMixed = { [weak narration] sb in narration?.appendAudio(sb) }
        var phase = 0.0
        var audioAt = 0.0
        var tone = [Float](repeating: 0, count: 480)
        for i in 0..<300 {
            let t = Double(i) / 30
            narration.consume(presenter.processed, hostTime: t)
            while audioAt < t + 0.05 {
                for k in 0..<480 {
                    phase += 2 * Double.pi * 330 / 48000
                    tone[k] = Float(sin(phase) * 0.25)
                }
                tone.withUnsafeBufferPointer { mixer.processMic($0.baseAddress!, frames: 480, pts: audioAt) }
                audioAt += 0.01
            }
        }
        var narrationSaved = false
        narration.stop(markers: []) { r in narrationSaved = !r.files.isEmpty }
        var waited = 0.0
        while !narrationSaved && waited < 20 { spin(0.1); waited += 0.1 }
        guard narrationSaved else {
            print("narration not saved")
            return 1
        }
        print("narration saved: \(narrationURL.lastPathComponent)")

        // 2. A real production pass: play the narration, record cues and a take from synthetic screen frames.
        let store = FrameStore()
        let screens = ScreenCaptureManager(store: store)
        let session = ProductionSession(store: store, processor: processor, screens: screens)
        session.demoSource = { .display(1) }
        processor.update(CameraProcessingConfig(background: settings.background, camera: settings.camera, beauty: settings.beauty,
                                                needCutout: false, preprocessed: true))
        var p = project0
        p.narrationFile = CourseProject.narrationFileName
        p.narrationDuration = 10
        try? ProjectStore.save(p, to: folder)
        session.open(p, folder: folder)
        waited = 0
        while !session.isLoaded && waited < 10 { spin(0.1); waited += 0.1 }
        guard session.isLoaded else {
            print("narration did not load")
            return 1
        }
        guard let ui = mockAppWindow(CGSize(width: 2880, height: 1800), assets: assets), let uiPB = makePixelBuffer(ui, ctx: ctx) else { return 1 }
        let screenRect = CGRect(x: 0, y: 0, width: 2880, height: 1800)
        session.record(.scene(.camera))
        session.record(.demoSource(.display(1)))
        if !deckPath.isEmpty { session.record(.slidesSource(.slides)); session.record(.slide(0)) }
        session.play()
        var fired: Set<Int> = []
        let passStart = Date()
        while Date().timeIntervalSince(passStart) < 6.5 {
            store.setScreen(ScreenFrame(pixelBuffer: uiPB, contentRect: screenRect, hostTime: CACurrentMediaTime()), for: .display(1))
            let t = session.currentTime
            if t >= 1.5, !fired.contains(1) { fired.insert(1); session.record(.scene(deckPath.isEmpty ? .demo : .slides)); session.record(.slide(1)) }
            if t >= 3.0, !fired.contains(2) { fired.insert(2); session.record(.scene(.demo)) }
            if t >= 4.5, !fired.contains(3) { fired.insert(3); session.record(.scene(.split)) }
            spin(1.0 / 30)
        }
        // Export must be safe immediately after pause, without an arbitrary sleep.
        var drained = false
        session.finishOperations { drained = true }
        waited = 0
        while !drained && waited < 20 { spin(0.05); waited += 0.05 }
        guard drained, let recorded = session.project else {
            print("take finalization did not complete")
            return 1
        }
        for take in recorded.takes {
            guard VideoFrameReader(url: folder.appendingPathComponent(take.file)) != nil else {
                print("take was published before its MP4 was ready")
                return 1
            }
        }
        // Review must replay cues and must never add takes or editing actions.
        var reviewedDemo = false
        session.onReviewTime = { time, cues, _ in
            if time >= 3, cues.contains(where: { $0.action == .scene(.demo) }) { reviewedDemo = true }
        }
        session.review(cues: recorded.cues)
        spin(0.2)
        session.seek(to: 3.2)
        spin(0.3)
        session.record(.scene(.camera))
        session.play()
        spin(0.3)
        session.stopReview()
        guard reviewedDemo, session.project == recorded else {
            print("review mutated the timeline or failed to seek to the demo cue")
            return 1
        }
        print("review: seek and non-mutating playback passed")
        // One unchanged screen buffer creates a sub-0.2 s take, regardless of wall-clock scheduling.
        // The drain callback must wait for its writer and deletion, even though it never enters the project.
        let takeFolder = folder.appendingPathComponent(CourseProject.takesFolder)
        func takeFiles() -> Set<String> {
            Set((try? FileManager.default.contentsOfDirectory(atPath: takeFolder.path)) ?? [])
        }
        let filesBeforeShortTake = takeFiles()
        store.setScreen(ScreenFrame(pixelBuffer: uiPB, contentRect: screenRect, hostTime: CACurrentMediaTime()), for: .display(1))
        session.play()
        waited = 0
        while !session.recordingTake && waited < 3 { spin(0.01); waited += 0.01 }
        guard session.recordingTake, takeFiles().count > filesBeforeShortTake.count else {
            print("short take did not start")
            return 1
        }
        var shortDrained = false
        var shortFilesAfter: Set<String> = []
        session.finishOperations {
            shortFilesAfter = takeFiles()
            shortDrained = true
        }
        waited = 0
        while !shortDrained && waited < 20 { spin(0.01); waited += 0.01 }
        guard shortDrained, !session.isFinishingTakes, shortFilesAfter == filesBeforeShortTake,
              session.project?.takes == recorded.takes else {
            print("short take drain returned before its MP4 was closed and discarded")
            return 1
        }
        print("short take: drain waited for close and discard")
        print("pass: \(recorded.cues.count) cues, \(recorded.takes.count) takes \(recorded.takes.map { String(format: "%.2f-%.2f", $0.start, $0.end) }), \(recorded.cursor.count) cursor samples")
        guard !recorded.takes.isEmpty else {
            print("no take recorded")
            return 1
        }
        session.close()

        // 3. Export.
        let exporter = ProjectExporter(project: recorded, folder: folder, settings: settings, assets: assets, context: ctx)
        var exported: Result<URL, Error>?
        let t0 = CACurrentMediaTime()
        var lastShown = -1
        exporter.run(progress: { p in
            let pct = Int(p * 10)
            if pct != lastShown { lastShown = pct; print("export \(pct * 10)%") }
        }) { exported = $0 }
        waited = 0
        while exported == nil && waited < 300 { spin(0.2); waited += 0.2 }
        switch exported {
        case .success(let url):
            print(String(format: "exported %@ in %.1f s", url.path, CACurrentMediaTime() - t0))
            let originalBytes = try? Data(contentsOf: url)
            let cancelledExport = ProjectExporter(project: recorded, folder: folder, settings: settings, assets: assets, context: ctx)
            var cancellation: Result<URL, Error>?
            cancelledExport.run(progress: { progress in
                if progress >= 0.05 { cancelledExport.cancel() }
            }) { cancellation = $0 }
            waited = 0
            while cancellation == nil && waited < 90 { spin(0.1); waited += 0.1 }
            guard case .failure = cancellation, let originalBytes,
                  (try? Data(contentsOf: url)) == originalBytes else {
                print("cancelled re-export failed to preserve the original movie")
                return 2
            }
            print("cancelled re-export: original movie preserved byte-for-byte")
            return 0
        case .failure(let e):
            print("export failed: \(e)")
            return 2
        case nil:
            print("export timed out")
            return 2
        }
    }

    // MARK: - Beauty & matte

    private static func beautyAndMatteTest(processor: CameraProcessor, input: CVPixelBuffer, base: CameraProcessingConfig,
                                           save: (CIImage, String) -> Void) {
        func run(_ name: String, _ cfg: CameraProcessingConfig, frames: Int = 6) {
            processor.update(cfg)
            var f: CameraFrame?
            let t0 = CACurrentMediaTime()
            for i in 0..<frames { f = processor.process(input, hostTime: Double(i) / 30) }
            let ms = (CACurrentMediaTime() - t0) / Double(frames) * 1000
            print(String(format: "camera %@: %.1f ms/frame", name, ms))
            if let f { save(CIImage(cvPixelBuffer: f.processed), "cam_\(name).png") }
        }
        var off = base
        off.needCutout = false
        off.beauty.enabled = false
        // Green background makes any leftover of the original background obvious.
        off.background.mode = .color
        off.background.fillHoles = false
        off.background.matteClean = 0
        off.background.edgeTighten = 0
        run("matte_old", off)
        var matte = off
        matte.background = BackgroundSettings()
        matte.background.mode = .color
        run("matte_new", matte)
        var accurate = matte
        accurate.background.quality = .accurate
        run("matte_accurate", accurate)
        var natural = matte
        natural.background = base.background
        natural.beauty = BeautySettings()
        run("beauty_natural", natural)
        var strong = natural
        strong.beauty = BeautySettings(enabled: true, smooth: 0.8, whiten: 0.6, rosy: 0.3, slim: 1, eyes: 1, clarity: 0.3)
        run("beauty_strong", strong)
        processor.update(base)
    }

    // MARK: - Audio reader

    /// Builds LPCM sample buffers in the layouts capture devices deliver and checks the decoded values.
    static func audioReaderTest() -> Bool {
        func makeBuffer(channels: Int, planar: Bool, int16: Bool, frames: Int, value: (Int, Int) -> Float) -> CMSampleBuffer? {
            let bytes = int16 ? 2 : 4
            var asbd = AudioStreamBasicDescription()
            asbd.mSampleRate = 48000
            asbd.mFormatID = kAudioFormatLinearPCM
            asbd.mFormatFlags = (int16 ? kAudioFormatFlagIsSignedInteger : kAudioFormatFlagIsFloat) | kAudioFormatFlagIsPacked
                | (planar ? kAudioFormatFlagIsNonInterleaved : 0)
            asbd.mBitsPerChannel = UInt32(bytes * 8)
            asbd.mChannelsPerFrame = UInt32(channels)
            asbd.mFramesPerPacket = 1
            asbd.mBytesPerFrame = UInt32(planar ? bytes : bytes * channels)
            asbd.mBytesPerPacket = asbd.mBytesPerFrame
            var fmt: CMAudioFormatDescription?
            guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                                 magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt) == noErr, let fmt else { return nil }
            var data = [UInt8](repeating: 0, count: frames * channels * bytes)
            for f in 0..<frames {
                for c in 0..<channels {
                    let idx = planar ? c * frames + f : f * channels + c
                    let v = value(f, c)
                    data.withUnsafeMutableBytes { p in
                        if int16 { p.storeBytes(of: Int16(v * 32767), toByteOffset: idx * 2, as: Int16.self) }
                        else { p.storeBytes(of: v, toByteOffset: idx * 4, as: Float.self) }
                    }
                }
            }
            var block: CMBlockBuffer?
            guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: data.count, blockAllocator: nil,
                                                     customBlockSource: nil, offsetToData: 0, dataLength: data.count,
                                                     flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
                  let block else { return nil }
            _ = data.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count) }
            var sb: CMSampleBuffer?
            guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt, sampleCount: frames,
                                                                       presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
            return sb
        }
        var allOK = true
        for (channels, planar, int16) in [(1, false, false), (2, true, false), (2, false, false), (2, false, true)] {
            let frames = 960
            let expected: (Int, Int) -> Float = { f, c in Float(sin(Double(f) * 0.05 + Double(c))) * 0.5 }
            guard let sb = makeBuffer(channels: channels, planar: planar, int16: int16, frames: frames, value: expected) else {
                print("audio reader: could not build buffer"); allOK = false; continue
            }
            var reader = AudioSampleReader()
            var out: [Float] = []
            guard let r = reader.read(sb, into: &out) else {
                print("audio reader FAILED \(channels)ch planar=\(planar) int16=\(int16): \(reader.lastError ?? "?")"); allOK = false; continue
            }
            var maxErr: Float = 0
            for f in 0..<frames { for c in 0..<channels { maxErr = max(maxErr, abs(out[f * channels + c] - expected(f, c))) } }
            let ok = r.frames == frames && r.channels == channels && maxErr < (int16 ? 0.001 : 0.000_01)
            allOK = allOK && ok
            print("audio reader \(channels)ch planar=\(planar) int16=\(int16): \(ok ? "OK" : "WRONG") (max error \(maxErr))")
        }
        return allOK
    }

    // MARK: - Synthetic content

    static func makePixelBuffer(_ cg: CGImage, ctx: CIContext) -> CVPixelBuffer? {
        let size = CGSize(width: cg.width, height: cg.height)
        guard let pool = CameraProcessor.makePool(size) else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        guard let pb else { return nil }
        ctx.render(CIImage(cgImage: cg), to: pb, bounds: CGRect(origin: .zero, size: size), colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return pb
    }

    static func syntheticPerson(assets: AssetFactory) -> CGImage? {
        let size = CGSize(width: 1920, height: 1080)
        guard let c = assets.makeContext(size) else { return nil }
        c.setFillColor(CGColor(srgbRed: 0.35, green: 0.3, blue: 0.4, alpha: 1))
        c.fill(CGRect(origin: .zero, size: size))
        c.setFillColor(CGColor(srgbRed: 0.95, green: 0.85, blue: 0.75, alpha: 1))
        c.fillEllipse(in: CGRect(x: 860, y: 560, width: 200, height: 250))
        c.setFillColor(CGColor(srgbRed: 0.9, green: 0.88, blue: 0.8, alpha: 1))
        c.fillEllipse(in: CGRect(x: 700, y: -200, width: 520, height: 800))
        return c.makeImage()
    }

    static func mockAppWindow(_ size: CGSize, assets: AssetFactory) -> CGImage? {
        guard let c = assets.makeContext(size) else { return nil }
        let W = size.width, H = size.height, u = H / 1080
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fill(CGRect(origin: .zero, size: size))
        c.setFillColor(CGColor(srgbRed: 0.92, green: 0.97, blue: 0.94, alpha: 1))
        c.fill(CGRect(x: 0, y: 0, width: W * 0.18, height: H))
        let dark = RGBA(r: 0.15, g: 0.15, b: 0.2)
        assets.draw(assets.line("Agent", font: assets.font(size: 40 * u, weight: .bold), color: dark), at: CGPoint(x: 40 * u, y: H - 120 * u), in: c)
        for (i, item) in ["新对话", "Pull Request", "定时任务", "插件", "探索"].enumerated() {
            assets.draw(assets.line(item, font: assets.font(size: 26 * u, weight: .regular), color: dark), at: CGPoint(x: 60 * u, y: H - 200 * u - CGFloat(i) * 56 * u), in: c)
        }
        c.setFillColor(CGColor(gray: 0.9, alpha: 1))
        c.fill(CGRect(x: W * 0.18, y: H - 90 * u, width: W, height: 2 * u))
        assets.draw(assets.line("新对话", font: assets.font(size: 28 * u, weight: .medium), color: dark), at: CGPoint(x: W * 0.2, y: H - 50 * u), in: c)
        let bubble = CGRect(x: W * 0.62, y: H * 0.72, width: W * 0.32, height: 80 * u)
        c.addPath(CGPath(roundedRect: bubble, cornerWidth: 20 * u, cornerHeight: 20 * u, transform: nil))
        c.setFillColor(CGColor(srgbRed: 0.93, green: 0.92, blue: 0.98, alpha: 1))
        c.fillPath()
        assets.draw(assets.line("帮我读取这张图片的内容", font: assets.font(size: 28 * u, weight: .regular), color: dark), at: CGPoint(x: bubble.minX + 30 * u, y: bubble.midY), in: c)
        c.setFillColor(CGColor(gray: 0.86, alpha: 1))
        for i in 0..<6 {
            let w = W * (0.55 - CGFloat(i % 3) * 0.08)
            c.addPath(CGPath(roundedRect: CGRect(x: W * 0.22, y: H * 0.62 - CGFloat(i) * 46 * u, width: w, height: 22 * u), cornerWidth: 8 * u, cornerHeight: 8 * u, transform: nil))
            c.fillPath()
        }
        let input = CGRect(x: W * 0.22, y: 60 * u, width: W * 0.74, height: 130 * u)
        c.addPath(CGPath(roundedRect: input, cornerWidth: 26 * u, cornerHeight: 26 * u, transform: nil))
        c.setStrokeColor(CGColor(gray: 0.82, alpha: 1))
        c.setLineWidth(2 * u)
        c.strokePath()
        assets.draw(assets.line("帮我批准  ·  GPT-6 Astra", font: assets.font(size: 24 * u, weight: .regular), color: RGBA(r: 0.5, g: 0.5, b: 0.55)), at: CGPoint(x: input.minX + 30 * u, y: input.midY), in: c)
        return c.makeImage()
    }

    static func mockResultPage(_ size: CGSize, assets: AssetFactory) -> CGImage? {
        guard let c = assets.makeContext(size) else { return nil }
        let W = size.width, H = size.height, u = H / 1080
        let colors = [CGColor(srgbRed: 0.08, green: 0.1, blue: 0.16, alpha: 1), CGColor(srgbRed: 0.12, green: 0.16, blue: 0.26, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
            c.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
        }
        assets.draw(assets.line("迷宫小游戏 · 生成结果", font: assets.font(size: 64 * u, weight: .bold), color: RGBA.white), at: CGPoint(x: 120 * u, y: H - 140 * u), in: c)
        let cell = 46 * u
        c.setStrokeColor(CGColor(srgbRed: 0.85, green: 0.82, blue: 0.7, alpha: 1))
        c.setLineWidth(10 * u)
        var rng = SeededRandom(seed: 7)
        for i in 0..<20 {
            for j in 0..<14 {
                let x = W * 0.3 + CGFloat(i) * cell, y = H * 0.12 + CGFloat(j) * cell
                if rng.next() > 0.5 {
                    c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x + cell, y: y))
                } else {
                    c.move(to: CGPoint(x: x, y: y)); c.addLine(to: CGPoint(x: x, y: y + cell))
                }
            }
        }
        c.strokePath()
        return c.makeImage()
    }

    static func makeDeck(_ url: URL, assets: AssetFactory) {
        var box = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        let pages: [(String, String)] = [("从认识，到完成", "把一个想法，变成能打开的成果。"), ("收费 ≠ 更适合", "选择模型，先看自己的任务。")]
        for (title, sub) in pages {
            pdf.beginPDFPage(nil)
            let colors = [CGColor(srgbRed: 0.99, green: 0.98, blue: 1, alpha: 1), CGColor(srgbRed: 0.92, green: 0.89, blue: 0.98, alpha: 1)] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
                pdf.drawLinearGradient(g, start: CGPoint(x: 0, y: 1080), end: CGPoint(x: 1920, y: 0), options: [])
            }
            let dark = RGBA(r: 0.12, g: 0.1, b: 0.2)
            assets.draw(assets.line("WORK AGENT  |  入门课", font: assets.font(size: 26, weight: .medium), color: dark.withAlpha(0.8)), at: CGPoint(x: 70, y: 1010), in: pdf)
            assets.draw(assets.line(title, font: assets.font(size: 76, weight: .bold), color: dark), at: CGPoint(x: 70, y: 820), in: pdf)
            assets.draw(assets.line(sub, font: assets.font(size: 34, weight: .regular), color: dark.withAlpha(0.65)), at: CGPoint(x: 70, y: 730), in: pdf)
            for i in 0..<2 {
                let r = CGRect(x: 70 + CGFloat(i) * 30, y: 480 - CGFloat(i) * 150, width: 900, height: 120)
                pdf.addPath(CGPath(roundedRect: r, cornerWidth: 16, cornerHeight: 16, transform: nil))
                pdf.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.9))
                pdf.fillPath()
                assets.draw(assets.line(i == 0 ? "01  认识 Agent" : "02  完成一个小任务", font: assets.font(size: 34, weight: .semibold), color: dark), at: CGPoint(x: r.minX + 40, y: r.midY), in: pdf)
            }
            pdf.endPDFPage()
        }
        pdf.closePDF()
    }

    /// An A4 report-like page with headings and charts, to test pan / zoom of tall pages.
    static func makePortraitDoc(_ url: URL, assets: AssetFactory) {
        var box = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let pdf = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
        pdf.beginPDFPage(nil)
        pdf.setFillColor(CGColor(gray: 1, alpha: 1))
        pdf.fill(box)
        let dark = RGBA(r: 0.12, g: 0.12, b: 0.15)
        let titles = ["一、黄金持仓情况（页首）", "二、CFTC 白银持仓情况（中部）", "三、结论与展望（页尾）"]
        for (i, t) in titles.enumerated() {
            let top = 842 - 40 - CGFloat(i) * 270
            assets.draw(assets.line(t, font: assets.font(size: 20, weight: .bold), color: dark), at: CGPoint(x: 40, y: top), in: pdf)
            let chart = CGRect(x: 40, y: top - 230, width: 515, height: 200)
            pdf.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
            pdf.stroke(chart)
            pdf.setStrokeColor(i == 1 ? CGColor(srgbRed: 0.85, green: 0.2, blue: 0.2, alpha: 1) : CGColor(srgbRed: 0.2, green: 0.45, blue: 0.85, alpha: 1))
            pdf.setLineWidth(3)
            for k in 0..<40 {
                let x = chart.minX + CGFloat(k) * chart.width / 39
                let y = chart.midY + sin(CGFloat(k) * 0.4 + CGFloat(i)) * 60
                k == 0 ? pdf.move(to: CGPoint(x: x, y: y)) : pdf.addLine(to: CGPoint(x: x, y: y))
            }
            pdf.strokePath()
        }
        pdf.endPDFPage()
        pdf.closePDF()
    }

    static func makeTone(_ url: URL, seconds: Double) {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!
        guard let file = try? AVAudioFile(forWriting: url, settings: fmt.settings),
              let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(44100 * seconds)) else { return }
        let n = Int(44100 * seconds)
        buf.frameLength = AVAudioFrameCount(n)
        let notes: [Double] = [261.6, 329.6, 392.0]
        for i in 0..<n {
            let t = Double(i) / 44100
            var s = 0.0
            for f in notes { s += sin(2 * .pi * f * t) }
            let v = Float(s / 3 * 0.5)
            buf.floatChannelData![0][i] = v
            buf.floatChannelData![1][i] = v
        }
        try? file.write(from: buf)
    }
}
