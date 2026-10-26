import Foundation
import AppKit
import AVFoundation
import CoreImage
import CoreVideo

/// Uses synthetic colors and PCM only; never opens an input/output device in CPU checks.
enum DeviceQuickToggleSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runCPU() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else { throw Failure(message: "设备开关自测失败：\(name)") }
            checks += 1
        }
        let canvas = Canvas(width: 1920, height: 1080)
        var config = LayoutConfig()
        config.demo.avoidPIP = true
        config.pip.shape = .rounded
        config.pip.corner = .bottomLeft
        config.camera.fullZoom = 1.4
        config.split.fitContent = true
        let savedPIP = config.pip, savedCamera = config.camera, savedSplit = config.split
        for scene in SceneKind.allCases {
            config.presenterVisible = true
            let on = LayoutBuilder.layout(for: scene, canvas: canvas, config: config, pipVisibility: 1, face: nil)
            config.presenterVisible = false
            let off = LayoutBuilder.layout(for: scene, canvas: canvas, config: config, pipVisibility: 1, face: nil)
            try check(on.camera.opacity > 0 && off.camera.opacity == 0, "\(scene.rawValue)关闭人像")
            if scene == .demo {
                try check(on.content.avoidLeft > 0 && off.content.avoidLeft == 0 && off.content.avoidRightInset == 0,
                          "演示取消小窗占位")
            } else if scene == .split {
                try check(off.content.rect == canvas.bounds && off.content.opacity == 1, "分屏关闭人像后内容全宽")
            }
            config.presenterVisible = true
            let restored = LayoutBuilder.layout(for: scene, canvas: canvas, config: config, pipVisibility: 1, face: nil)
            try check(restored == on, "\(scene.rawValue)重新开启完全恢复布局")
        }
        try check(config.pip == savedPIP && config.camera == savedCamera && config.split == savedSplit,
                  "摄像头可见性不改原布局参数")
        config.pip.corner = .bottomRight
        config.presenterVisible = false
        let right = LayoutBuilder.layout(for: .demo, canvas: canvas, config: config, pipVisibility: 1, face: nil)
        try check(right.content.avoidLeft == 0 && right.content.avoidRightInset == 0, "右侧小窗也不留空位")
        config.presenterVisible = true
        let hidden = LayoutBuilder.layout(for: .slides, canvas: canvas, config: config, pipVisibility: 0, face: nil)
        try check(hidden.camera.opacity == 0, "设备重新开启不覆盖原小窗隐藏意图")

        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceToggleAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tone = folder.appendingPathComponent("synthetic-constant.caf")
        try writeConstantAudio(tone)
        let mixer = AudioMixer()
        mixer.trustsTimestamps = true
        mixer.monitor.setEnabled(false)
        mixer.bgm.setTracks([tone.path])
        mixer.bgm.setFadeSeconds(0.05)
        mixer.bgm.play()
        defer { mixer.bgm.pause() }
        var settings = MixerConfig(micGain: 1, highPass: false, gate: false, gateThresholdDB: -52,
                                   limiter: false, systemGain: 1, bgmGain: 1, ducking: false,
                                   duckGain: 1, micMuted: false, avOffset: 0)
        var output: [(pts: Double, frames: Int, samples: [Float])] = []
        var decodeFailure = false
        mixer.onMixed = { sample in
            guard let block = CMSampleBufferGetDataBuffer(sample) else { decodeFailure = true; return }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let status = values.withUnsafeMutableBytes {
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!)
            }
            guard status == noErr else { decodeFailure = true; return }
            output.append((CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample)), CMSampleBufferGetNumSamples(sample), values))
        }
        let blockFrames = 2400
        let microphone = [Float](repeating: 0.2, count: blockFrames)
        var system = [Float](repeating: 0, count: blockFrames * 2)
        for index in 0..<blockFrames { system[index * 2] = 0.08; system[index * 2 + 1] = -0.04 }
        // The first block completes the BGM fade; the next three are mic on / off / on.
        for index in 0..<4 {
            settings.micMuted = index == 2
            mixer.update(settings)
            system.withUnsafeBufferPointer { mixer.systemRing.writeInterleaved($0.baseAddress!, frames: blockFrames) }
            microphone.withUnsafeBufferPointer { mixer.processMic($0.baseAddress!, frames: blockFrames, pts: Double(index) * 0.05) }
        }
        try check(!decodeFailure && output.count == 4, "静音切换每块均产出真实CMSampleBuffer")
        try check(output.allSatisfy { $0.frames == blockFrames && $0.samples.count == blockFrames * 2 }, "静音不改双声道采样长度")
        for index in 0..<4 {
            try check(abs(output[index].pts - Double(index * blockFrames) / 48_000) < 0.000001,
                      "第\(index)块PTS连续")
        }
        for index in 1..<4 {
            let mic: Float = index == 2 ? 0 : 0.2
            let samples = output[index].samples
            let valid = (0..<blockFrames).allSatisfy {
                abs(samples[$0 * 2] - (mic + 0.12 + 0.08)) < 0.0001
                    && abs(samples[$0 * 2 + 1] - (mic + 0.12 - 0.04)) < 0.0001
            }
            try check(valid, index == 2 ? "静音只消除麦克风并保留BGM和左右系统声" : "打开麦克风恢复原混音")
        }
        try check(mixer.bgm.status().playing && abs(mixer.bgm.status().position - 0.2) < 0.0001,
                  "静音期间BGM播放头连续前进")
        return checks
    }

    @MainActor
    static func runMedia(_ outputDirectory: URL) async throws -> Int {
        guard CommandLine.arguments.contains("--no-capture") else { throw Failure(message: "设备开关媒体自测必须带 --no-capture") }
        var checks = try runCPU()
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "设备开关媒体自测失败：\(name)") }
            checks += 1
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let folder = outputDirectory.appendingPathComponent("device-toggle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("合成口播.mov")
        try await SyntheticNarrationFixture.write(to: copy)
        let settingsBefore = try? Data(contentsOf: SettingsStore.fileURL)
        let app = AppState()
        app.persistsSettings = false
        defer { app.recState = .idle; app.shutdown() }
        let micID = app.settings.audio.micDeviceID
        app.settings.audio.systemAudio = false
        app.settings.bgm.monitor = false
        app.settings.bgm.tracks = []
        app.settings.bgm.autoStart = false
        app.settings.slides.deckPath = ""
        app.settings.background.mode = .off
        app.settings.background.customImagePath = ""
        app.settings.demo.customBackdropPath = ""
        app.settings.camera.faceTracking = false
        app.settings.beauty.enabled = false
        app.settings.recording.folder = folder.path
        app.settings.recording.resolution = .p1080
        app.settings.recording.fps = 30
        let frames = FrameCounter()
        app.engine.addSink(frames)
        defer { app.engine.removeSink(frames) }
        app.start()
        try await wait("合成开始出帧") { frames.count > 0 && app.engine.isRunning }
        app.selectScene(.demo)
        app.togglePIP()
        let savedSettings = app.settings, savedScene = app.scene, savedPIP = app.pipHidden, savedSources = app.demoSources
        app.recState = .recording
        try check(app.canToggleCamera && app.recorder.currentState == .idle, "实时录屏状态允许开关且测试未启动writer")
        let count = frames.count
        app.toggleCamera()
        try check(app.cameraSwitchInProgress && !app.canToggleCamera, "关闭排空期间锁定开关")
        app.toggleCamera()
        try check(!app.cameraEnabled, "关闭未收尾时连续点击不会重开")
        try await wait("关闭摄像头仍持续出帧") { frames.count > count + 3 }
        try await wait("摄像头关闭排空完成") { !app.cameraSwitchInProgress }
        try check(!app.cameraEnabled && app.engine.isRunning && app.recState == .recording, "关闭摄像头不停止录屏状态或合成")
        try check(app.recorder.currentState == .idle && app.narrationRecorder.currentState == .idle, "设备开关不触碰写入器")
        try check(app.settings == savedSettings && app.scene == savedScene && app.pipHidden == savedPIP && app.demoSources == savedSources,
                  "关闭保留原设置镜头小窗和来源")
        app.toggleMicMute()
        try check(app.micMuted && app.recState == .recording && app.engine.isRunning, "麦克风按钮只变静音意图")
        app.toggleMicMute()
        try check(!app.micMuted && app.settings == savedSettings, "取消静音保留设置")
        app.toggleCamera()
        try check(app.cameraEnabled && app.scene == savedScene && app.pipHidden == savedPIP, "开启恢复且不改变镜头或小窗隐藏")
        app.recState = .idle
        app.toggleCamera()
        try await wait("第二次摄像头关闭完成") { !app.cameraSwitchInProgress }
        let token = UUID()
        try check(app.pausePreviewForNarrationImport(token: token), "关闭摄像头时可暂停导入预览")
        app.resumePreviewAfterNarrationImport(token: token)
        try await wait("导入结束恢复渲染") { app.engine.isRunning }
        try check(!app.cameraEnabled && !app.cameraStatus.running, "导入恢复保留摄像头关闭意图")
        app.workMode = .production
        let lockedStates: [RecState] = [.countdown(2), .recording, .paused, .finishing]
        for state in lockedStates {
            app.recState = state
            try check(!app.canToggleCamera, "口播\(state)禁止硬件开关")
            app.toggleCamera()
            try check(!app.cameraEnabled && app.recState == state, "口播\(state)调用开关也不改变状态")
        }
        app.recState = .idle
        try check(app.canToggleCamera, "口播空闲恢复开关")
        var project = CourseProject(name: "合成设备开关")
        project.narrationFile = copy.lastPathComponent
        project.narrationDuration = CMTimeGetSeconds(try await AVURLAsset(url: copy).load(.duration))
        project.narrationIsImported = true
        project.includeBGM = false
        try ProjectStore.save(project, to: folder)
        app.production.open(project, folder: folder)
        try await wait("已有口播加载") { app.production.isLoaded }
        try check(!app.canToggleCamera && !app.cameraEnabled, "已载入口播禁用实时摄像头开关")
        app.toggleCamera()
        try check(!app.cameraEnabled && app.production.isLoaded, "硬件开关不会隐藏已录口播")
        app.production.close()
        app.engine.stop()
        checks += try checkRenderedColors(context: app.ciContext)
        try check(app.settings.audio.micDeviceID == micID, "测试未改变麦克风设备")
        try check((try? Data(contentsOf: SettingsStore.fileURL)) == settingsBefore, "测试未写用户设置")
        try "Device quick toggle: \(checks) checks passed\nSynthetic colors and PCM only; no input/output capture.\n"
            .write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("Device quick toggle artifacts: \(folder.path)")
        return checks
    }

    private static func checkRenderedColors(context: CIContext) throws -> Int {
        let store = FrameStore()
        let assets = AssetFactory(context: context)
        let engine = RenderEngine(context: context, store: store, assets: assets, cursor: CursorTracker(), canvasSize: CGSize(width: 320, height: 180))
        let red = try solidPixels(red: 255, green: 0)
        let green = try solidPixels(red: 0, green: 255)
        store.setCamera(CameraFrame(processed: red, cutout: nil, size: CGSize(width: 320, height: 180), face: nil, captureTime: 0))
        let ref = SourceRef.display(UInt32.max - 20)
        store.setScreen(ScreenFrame(pixelBuffer: green, contentRect: CGRect(x: 0, y: 0, width: 320, height: 180), hostTime: 0), for: ref)
        engine.setSources(SceneSources(slides: ref, demo: ref), at: 0)
        var config = LayoutConfig()
        config.camera.faceTracking = false
        config.pip.borderWidth = 0
        config.pip.shadow = false
        config.demo.padding = 0
        config.demo.shadow = false
        config.demo.cornerRadius = 0
        var checks = 0
        func check(_ condition: Bool, _ name: String) throws {
            guard condition else { throw Failure(message: "设备开关像素自测失败：\(name)") }
            checks += 1
        }
        for (index, scene) in SceneKind.allCases.enumerated() {
            let time = Double(index * 10 + 10)
            config.presenterVisible = true
            engine.update(config: config, transitions: TransitionSettings())
            engine.setScene(scene, animated: false, at: time)
            guard let on = engine.renderFrame(at: time + 1) else { throw Failure(message: "无法合成开启画面") }
            try check(redCount(on) > 4, "\(scene.rawValue)开启时有实际红色人像")
            config.presenterVisible = false
            engine.update(config: config, transitions: TransitionSettings())
            guard let off = engine.renderFrame(at: time + 1.01) else { throw Failure(message: "无法合成关闭画面") }
            try check(redCount(off) == 0, "\(scene.rawValue)关闭后不保留旧摄像头帧")
            if scene != .camera {
                let slot = scene == .split ? CGPoint(x: 290, y: 90)
                    : LayoutBuilder.pipRect(canvas: Canvas(width: 320, height: 180), pip: config.pip).center
                try check(isGreen(off, at: slot), "\(scene.rawValue)人像位置由内容填充而不是占位人像")
            }
        }
        config.presenterVisible = true
        engine.update(config: config, transitions: TransitionSettings())
        engine.setScene(.camera, animated: false, at: 100)
        _ = engine.renderFrame(at: 100)
        engine.setScene(.demo, animated: true, at: 101)
        config.presenterVisible = false
        engine.update(config: config, transitions: TransitionSettings())
        guard let transition = engine.renderFrame(at: 101.001) else { throw Failure(message: "无法合成转场画面") }
        try check(redCount(transition) == 0, "转场缓存中的人像立即隐藏")
        config.presenterVisible = true
        engine.update(config: config, transitions: TransitionSettings())
        engine.setScene(.camera, animated: false, at: 103)
        guard let restored = engine.renderFrame(at: 103) else { throw Failure(message: "无法合成恢复画面") }
        try check(redCount(restored) > 4, "再次开启恢复人像")
        return checks
    }

    private static func writeConstantAudio(_ url: URL) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for channel in 0..<2 { buffer.floatChannelData![channel].update(repeating: 0.12, count: 48_000) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    private static func solidPixels(red: UInt8, green: UInt8) throws -> CVPixelBuffer {
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &output) == kCVReturnSuccess, let output else {
            throw Failure(message: "无法创建合成像素")
        }
        CVPixelBufferLockBaseAddress(output, [])
        defer { CVPixelBufferUnlockBaseAddress(output, []) }
        let bytes = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(output)
        for y in 0..<180 { for x in 0..<320 {
            let index = y * stride + x * 4
            bytes[index] = 0; bytes[index + 1] = green; bytes[index + 2] = red; bytes[index + 3] = 255
        } }
        return output
    }

    private static func redCount(_ pixels: CVPixelBuffer) -> Int {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        var count = 0
        for y in Swift.stride(from: 2, to: CVPixelBufferGetHeight(pixels), by: 4) {
            for x in Swift.stride(from: 2, to: CVPixelBufferGetWidth(pixels), by: 4) {
                let index = y * stride + x * 4
                if bytes[index + 2] > 180 && bytes[index + 1] < 70 && bytes[index] < 70 { count += 1 }
            }
        }
        return count
    }

    private static func isGreen(_ pixels: CVPixelBuffer, at point: CGPoint) -> Bool {
        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        let x = min(CVPixelBufferGetWidth(pixels) - 1, max(0, Int(point.x)))
        let y = min(CVPixelBufferGetHeight(pixels) - 1, max(0, Int(point.y)))
        let index = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
        return bytes[index + 1] > 180 && bytes[index + 2] < 70 && bytes[index] < 70
    }

    @MainActor
    private static func wait(_ name: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "设备开关自测等待超时：\(name)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private final class FrameCounter: FrameSink {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func consume(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) { lock.lock(); value += 1; lock.unlock() }
    }
}
