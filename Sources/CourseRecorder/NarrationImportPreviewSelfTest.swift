import Foundation
import AppKit
import AVFoundation
import CoreVideo

/// Import-preview lifecycle checks. Run only after the user has finished recording or trying the app.
enum NarrationImportPreviewSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    @MainActor
    static func run(_ outputDirectory: URL) async throws -> Int {
        guard CommandLine.arguments.contains("--no-capture") else {
            throw Failure(message: "导入预览自测必须带 --no-capture，避免打开摄像头和麦克风")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let folder = outputDirectory.appendingPathComponent("import-preview-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // Generate the fixture inside this run; a clean clone needs no checked-in or personal media.
        let fixture = folder.appendingPathComponent("synthetic-fixture.mov")
        try await SyntheticNarrationFixture.write(to: fixture)
        let fixtureBytes = try Data(contentsOf: fixture)
        let sourceDuration = CMTimeGetSeconds(try await AVURLAsset(url: fixture).load(.duration))
        guard sourceDuration.isFinite, sourceDuration > 2 else { throw Failure(message: "合成夹具时长无效") }
        let media = folder.appendingPathComponent("合成原口播.mov")
        let replacementMedia = folder.appendingPathComponent("合成导入副本.mov")
        try FileManager.default.copyItem(at: fixture, to: media)
        try FileManager.default.copyItem(at: fixture, to: replacementMedia)

        let settingsBefore = try? Data(contentsOf: SettingsStore.fileURL)
        let app = AppState()
        app.persistsSettings = false
        defer { app.recState = .idle; app.shutdown() }
        // Preserve the microphone device ID: changing it propagates directly to MicCapture.start.
        let microphoneID = app.settings.audio.micDeviceID
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
        app.engine.stop()

        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "导入预览自测失败：\(name)") }
            checks += 1
        }
        let frames = FrameCounter()
        app.engine.addSink(frames)
        defer { app.engine.removeSink(frames) }
        var cameraStarts = 0
        let previousCameraStatus = app.camera.onStatus
        app.camera.onStatus = { status in
            if status.running { cameraStarts += 1 }
            previousCameraStatus?(status)
        }

        let beforeStartup = UUID()
        try check(app.pausePreviewForNarrationImport(token: beforeStartup), "未启动预览也可安全获取暂停令牌")
        app.resumePreviewAfterNarrationImport(token: beforeStartup)
        try check(!app.engine.isRunning, "恢复不启动从未开始的预览")
        app.start()
        try await wait("初始预览出帧") { app.engine.isRunning && frames.count > 0 }
        try check(app.engine.isRunning && !app.narrationImportPreviewPaused, "正常预览启动")
        try check(app.settings.audio.micDeviceID == microphoneID && cameraStarts == 0, "不改麦克风设备且不打开摄像头")

        let cancelled = UUID()
        try check(app.pausePreviewForNarrationImport(token: cancelled), "取消路径取得暂停令牌")
        let pausedCount = frames.count
        try check(app.narrationImportPreviewPaused && app.production.isPreviewSuspended && !app.engine.isRunning,
                  "合成循环与口播读帧共同暂停")
        try check(!app.pausePreviewForNarrationImport(token: cancelled), "重复暂停不能替换现有令牌")
        try check(!app.pausePreviewForNarrationImport(token: UUID()), "另一任务不能抢占暂停令牌")
        app.resumePreviewAfterNarrationImport(token: UUID())
        try check(app.narrationImportPreviewPaused && !app.engine.isRunning, "陌生令牌不能恢复")
        app.settings.recording.fps = 60
        let syntheticSource = SourceRef.display(UInt32.max - 11)
        app.displays = [CaptureSourceInfo(ref: syntheticSource, name: "合成测试显示器", detail: "synthetic",
            pixelSize: CGSize(width: 240, height: 160), frame: CGRect(x: 0, y: 0, width: 240, height: 160))]
        app.settings.demo.sources = [syntheticSource]
        app.settings.slides.source = syntheticSource
        app.resolveSources(direction: 1)
        app.refreshSources()
        app.scheduleSourceRefresh(after: 0.01)
        try await settle()
        try check(!app.engine.isRunning && frames.count == pausedCount, "暂停时帧率和来源变更不会重启合成")
        try check(app.narrationImportPreviewPaused && app.production.isPreviewSuspended, "来源通知不解除暂停")
        app.resumePreviewAfterNarrationImport(token: cancelled)
        try await wait("取消后恢复出帧") { app.engine.isRunning && frames.count > pausedCount }
        try check(!app.narrationImportPreviewPaused && !app.production.isPreviewSuspended, "取消路径恢复所有预览状态")

        let failed = UUID()
        try check(app.pausePreviewForNarrationImport(token: failed), "失败路径取得新的暂停令牌")
        app.resumePreviewAfterNarrationImport(token: cancelled)
        try check(app.narrationImportPreviewPaused && !app.engine.isRunning, "上次延迟完成不能解除新任务暂停")
        // Cancel and error exits share the import task's defer; exercise its same-token restoration.
        app.resumePreviewAfterNarrationImport(token: failed)
        try await wait("失败后恢复合成") { app.engine.isRunning }
        try check(!app.production.isPreviewSuspended && !app.narrationImportPreviewPaused, "失败路径恢复预览")

        app.displays = []
        app.settings.demo.sources = []
        app.settings.slides.source = nil
        app.resolveSources(direction: 1)
        app.workMode = .production
        var project = CourseProject(name: "合成导入预览生命周期")
        project.narrationFile = media.lastPathComponent
        project.narrationDuration = sourceDuration
        project.narrationIsImported = true
        project.includeBGM = false
        try ProjectStore.save(project, to: folder)
        app.production.open(project, folder: folder)
        try await wait("原口播加载") { app.production.isLoaded }
        try await settle()
        app.production.seek(to: 1.2)
        try await wait("原口播暂停画面") { app.store.camera() != nil && abs(app.production.currentTime - 1.2) < 0.04 }
        try await settle()
        guard let frozenFrame = app.store.camera() else { throw Failure(message: "原口播没有暂停帧") }
        let originalProject = app.production.project
        let originalTime = app.production.currentTime
        let replaceToken = UUID()
        try check(app.pausePreviewForNarrationImport(token: replaceToken), "已有口播可暂停预览")
        try await settle()
        try check(app.production.isLoaded && !app.production.isPlaying, "暂停不卸载原口播")
        try check(app.store.camera() === frozenFrame, "暂停保留当前口播图像对象")
        try check(abs(app.production.currentTime - originalTime) < 0.01 && abs(app.production.time - originalTime) < 0.04,
                  "暂停保留播放位置")
        try check(app.production.project == originalProject && !app.production.recordingTake, "暂停不改项目或新建演示素材")
        app.resumePreviewAfterNarrationImport(token: replaceToken)
        try await wait("原口播恢复预览") { app.engine.isRunning && !app.production.isPreviewSuspended }
        try check(app.production.isLoaded && abs(app.production.currentTime - originalTime) < 0.01,
                  "取消替换后仍在原播放位置")

        let success = UUID()
        try check(app.pausePreviewForNarrationImport(token: success), "成功路径暂停")
        var replacement = project
        replacement.narrationFile = replacementMedia.lastPathComponent
        replacement.cues = []
        replacement.takes = []
        try ProjectStore.save(replacement, to: folder)
        app.production.update(replacement)
        app.production.open(replacement, folder: folder)
        try check(!app.production.isLoaded && app.production.project?.narrationFile == replacementMedia.lastPathComponent,
                  "成功提交后新口播进入异步加载空档")
        try check(app.production.isPreviewSuspended && !app.engine.isRunning, "异步加载本身不能提前恢复合成")
        app.resumePreviewAfterNarrationImport(token: success)
        try await wait("新口播加载并恢复预览") { app.production.isLoaded && app.engine.isRunning }
        try await settle()
        app.production.seek(to: 1.5)
        try await wait("新口播画面进入预览") { app.store.camera() != nil && abs(app.production.currentTime - 1.5) < 0.04 }
        try check(!app.production.isPreviewSuspended && !app.narrationImportPreviewPaused, "异步新口播加载后恢复全部状态")
        try check(app.production.project?.narrationFile == replacementMedia.lastPathComponent && !app.production.isPlaying,
                  "新口播正确加载且不自动播放")
        try check(cameraStarts == 0 && !app.cameraStatus.running, "成功导入加载空档及完成后均不打开摄像头")

        app.recState = .recording
        try check(!app.pausePreviewForNarrationImport(token: UUID()), "录制状态拒绝暂停录制预览")
        app.recState = .idle
        let shutdown = UUID()
        try check(app.pausePreviewForNarrationImport(token: shutdown), "退出前仍可暂停")
        app.shutdown()
        let stoppedCount = frames.count
        app.resumePreviewAfterNarrationImport(token: shutdown)
        app.settings.recording.fps = 30
        app.resolveSources(direction: -1)
        try await settle()
        try check(!app.engine.isRunning && frames.count == stoppedCount, "退出后迟到恢复和设置变更都不能重新出帧")
        try check(!app.production.isLoaded && !app.cameraStatus.running && cameraStarts == 0, "退出保持播放器与摄像头停止")
        try check(!app.pausePreviewForNarrationImport(token: UUID()), "退出后不能开始新暂停操作")
        try check(try Data(contentsOf: fixture) == fixtureBytes && Data(contentsOf: media) == fixtureBytes,
                  "合成源与原口播逐字节未改")
        try check((try? Data(contentsOf: SettingsStore.fileURL)) == settingsBefore, "未写入用户设置")
        try "Narration import preview: \(checks) checks passed\nSynthetic fixture only; no device capture.\n"
            .write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("Narration import preview artifacts: \(folder.path)")
        return checks
    }

    @MainActor
    private static func wait(_ name: String, timeout: Double = 8, until condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "导入预览自测等待超时：\(name)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private static func settle() async throws { try await Task.sleep(nanoseconds: 250_000_000) }

    private final class FrameCounter: FrameSink {
        private let lock = NSLock()
        private var value = 0
        var count: Int { lock.lock(); defer { lock.unlock() }; return value }
        func consume(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
            lock.lock()
            value += 1
            lock.unlock()
        }
    }
}
