import Foundation
import AppKit
import AVFoundation

/// App-state and project persistence checks. Constructs render resources but never starts device capture.
enum OutputFormatStateSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run(_ outputDirectory: URL) async throws -> Int {
        guard CommandLine.arguments.contains("--no-capture") else {
            throw Failure(message: "输出格式状态自测必须带 --no-capture")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let directory = outputDirectory.appendingPathComponent("output-format-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let settingsBefore = try? Data(contentsOf: SettingsStore.fileURL)
        let app = AppState()
        app.persistsSettings = false
        defer { app.recState = .idle; app.shutdown() }
        let micID = app.settings.audio.micDeviceID
        var settings = app.settings
        settings.audio.systemAudio = false
        settings.bgm.monitor = false
        settings.bgm.tracks = []
        settings.bgm.autoStart = false
        settings.slides.deckPath = ""
        settings.slides.source = nil
        settings.demo.sources = []
        settings.demo.customBackdropPath = ""
        settings.background.mode = .off
        settings.background.customImagePath = ""
        settings.camera.faceTracking = false
        settings.beauty.enabled = false
        settings.recording.folder = directory.path
        settings.recording.resolution = .p1080
        settings.recording.aspect = .landscape
        // Preserve hardware device IDs and camera frame rate to avoid their start-on-change hooks.
        app.settings = settings
        app.engine.stop()
        app.camera.stop()
        app.mic.stop()
        app.screens.stopAll()
        app.engine.synchronize()

        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "输出格式状态自测失败：\(name)") }
            checks += 1
        }
        func checkLocked(_ name: String) throws {
            let previous = app.settings.recording
            let other: OutputAspect = previous.aspect == .landscape ? .portrait : .landscape
            try check(!app.canChangeOutputFormat, "\(name)禁用格式入口")
            app.setOutputAspect(other)
            try check(app.settings.recording.aspect == previous.aspect, "\(name)API拒绝切画幅")
            var attempted = previous
            attempted.aspect = other
            attempted.resolution = previous.resolution == .p1080 ? .p1440 : .p1080
            attempted.fps = previous.fps == 60 ? 30 : 60
            attempted.codec = previous.codec == .h264 ? .hevc : .h264
            attempted.quality = previous.quality == .high ? .standard : .high
            app.settings.recording = attempted
            app.engine.synchronize()
            try check(app.settings.recording == previous, "\(name)直接绑定不能改编码或尺寸")
            try check(app.engine.canvas.size == previous.outputSize, "\(name)渲染画布保持原尺寸")
        }

        try check(app.canChangeOutputFormat, "空闲允许修改")
        app.setOutputAspect(.portrait)
        app.engine.synchronize()
        try check(app.settings.recording.aspect == .portrait && app.engine.canvas.size == CGSize(width: 1080, height: 1920), "空闲切竖屏与渲染画布一致")
        try check(app.maxCaptureWidth == 3840, "竖屏保留完整桌面采集宽度")
        app.setOutputAspect(.landscape)
        app.engine.synchronize()
        try check(app.engine.canvas.size == CGSize(width: 1920, height: 1080), "切回横屏恢复画布")
        for state in [RecState.countdown(2), .recording, .paused, .finishing] {
            app.recState = state
            try checkLocked("\(state)")
        }
        app.recState = .idle
        app.exportProgress = 0.25
        try checkLocked("导出")
        app.exportProgress = nil
        app.narrationImportProgress = 0.25
        try checkLocked("导入")
        app.narrationImportProgress = nil
        app.projectActionInProgress = true
        try checkLocked("项目事务")
        app.projectActionInProgress = false
        let importToken = UUID()
        try check(app.pausePreviewForNarrationImport(token: importToken), "取得导入预览暂停令牌")
        try checkLocked("导入预览暂停")
        app.resumePreviewAfterNarrationImport(token: importToken)
        try check(app.canChangeOutputFormat && !app.engine.isRunning, "恢复未启动的预览不打开设备或循环")

        app.workMode = .production
        app.setOutputAspect(.portrait)
        try check(app.createProject(named: "合成竖屏项目"), "创建竖屏项目")
        guard let portraitFolder = app.production.folder else { throw Failure(message: "未创建竖屏项目目录") }
        app.production.flushSave()
        try check(ProjectStore.load(portraitFolder)?.outputAspect == .portrait, "项目保存竖屏画幅")
        let portraitBytes = try Data(contentsOf: portraitFolder.appendingPathComponent(CourseProject.fileName))
        app.production.close()
        app.setOutputAspect(.landscape)
        try check(app.createProject(named: "合成横屏项目"), "创建独立横屏项目")
        guard let landscapeFolder = app.production.folder else { throw Failure(message: "未创建横屏项目目录") }
        app.production.flushSave()
        app.openProject(named: portraitFolder.lastPathComponent)
        app.engine.synchronize()
        try check(app.settings.recording.aspect == .portrait && app.engine.canvas.size == CGSize(width: 1080, height: 1920), "打开竖屏项目恢复预览画幅")
        try check(ProjectStore.load(landscapeFolder)?.outputAspect == .landscape, "打开另一项目不覆盖旧项目画幅")
        try check(try Data(contentsOf: portraitFolder.appendingPathComponent(CourseProject.fileName)) == portraitBytes, "恢复画幅不改写目标项目元数据")

        let legacy = CourseProject(name: "合成旧版项目")
        let legacyFolder = ProjectStore.folder(named: legacy.name, in: directory)
        try ProjectStore.save(legacy, to: legacyFolder)
        app.openProject(named: legacy.name)
        app.engine.synchronize()
        try check(app.settings.recording.aspect == .landscape && app.engine.canvas.size == CGSize(width: 1920, height: 1080), "旧版项目缺省横屏")
        try check(ProjectStore.load(legacyFolder)?.outputAspect == nil, "旧版项目保持兼容元数据")

        // A silent audio-only asset exercises AVPlayer's real lifecycle without capturing private media.
        let silence = legacyFolder.appendingPathComponent("合成静音.caf")
        try writeSilence(silence)
        var playbackProject = legacy
        playbackProject.narrationFile = silence.lastPathComponent
        playbackProject.narrationDuration = 5
        playbackProject.includeBGM = false
        app.production.open(playbackProject, folder: legacyFolder)
        try await wait("合成静音加载") { app.production.isLoaded }
        app.production.play()
        try check(app.production.isPlaying, "真实播放器进入播放状态")
        try checkLocked("制作播放")
        let finished = Task { @MainActor in
            await withCheckedContinuation { continuation in
                app.production.finishOperations { continuation.resume() }
            }
        }
        // The async task starts on its next actor turn; wait for its completion before further project work.
        await finished.value
        try check(app.canChangeOutputFormat, "停止播放并收尾后恢复入口")
        app.production.finishOperations {}
        try checkLocked("制作素材收尾")
        try await wait("空素材收尾") { !app.production.isFinishingTakes }
        app.production.review(cues: [])
        try await wait("制作预览") { app.production.isReviewing && !app.production.isFinishingTakes }
        try checkLocked("制作预览")
        app.production.stopReview()
        app.production.close()
        app.flushSave()
        try check(app.recorder.currentState == .idle && app.narrationRecorder.currentState == .idle, "状态验证未启动写入器")
        try check(!app.cameraStatus.running && app.displays.isEmpty && app.windows.isEmpty, "状态验证未打开摄像头或屏幕捕捉")
        try check(app.settings.audio.micDeviceID == micID, "麦克风设备ID保持不变")
        app.shutdown()
        try check((try? Data(contentsOf: SettingsStore.fileURL)) == settingsBefore, "状态验证与退出未写用户设置")
        try "Output format state: \(checks) checks passed\nNo device capture; synthetic silence only.\n"
            .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("Output format state artifacts: \(directory.path)")
        return checks
    }

    private static func writeSilence(_ url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240_000) else {
            throw Failure(message: "无法创建合成静音")
        }
        buffer.frameLength = buffer.frameCapacity
        buffer.floatChannelData![0].update(repeating: 0, count: Int(buffer.frameLength))
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    @MainActor
    private static func wait(_ name: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 8
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "输出格式状态自测等待超时：\(name)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
}
