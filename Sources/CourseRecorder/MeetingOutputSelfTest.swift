import Foundation
import AppKit
import CoreImage
import CoreVideo
import Metal

/// Exercises a real output window using synthetic frames, without capture, recording or meeting clients.
enum MeetingOutputSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private final class CountingSink: FrameSink {
        private let lock = NSLock()
        private var count = 0

        var frames: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }

        func consume(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
            lock.lock()
            count += 1
            lock.unlock()
        }
    }

    @MainActor
    static func run(_ outputDirectory: URL) async throws -> Int {
        guard CommandLine.arguments.contains("--no-capture") else {
            throw Failure(message: "会议输出自测必须带 --no-capture")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let settingsBefore = try? Data(contentsOf: SettingsStore.fileURL)
        let directory = outputDirectory.appendingPathComponent("meeting-output-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(message: "Metal 不可用") }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let assets = AssetFactory(context: context)
        let store = FrameStore()
        guard let person = SelfTest.syntheticPerson(assets: assets),
              let personBuffer = SelfTest.makePixelBuffer(person, ctx: context),
              let screen = SelfTest.mockAppWindow(CGSize(width: 1920, height: 1080), assets: assets),
              let screenBuffer = SelfTest.makePixelBuffer(screen, ctx: context) else {
            throw Failure(message: "无法创建合成测试画面")
        }
        store.setCamera(CameraFrame(processed: personBuffer, cutout: nil,
                                    size: CGSize(width: person.width, height: person.height),
                                    face: CGPoint(x: 0.5, y: 0.4), captureTime: 0))
        store.setScreen(ScreenFrame(pixelBuffer: screenBuffer,
                                    contentRect: CGRect(x: 0, y: 0, width: CGFloat(screen.width), height: CGFloat(screen.height)),
                                    hostTime: 0), for: .display(1))
        let landscape = CGSize(width: 1280, height: 720)
        let portrait = CGSize(width: 720, height: 1280)
        let engine = RenderEngine(context: context, store: store, assets: assets, cursor: CursorTracker(), canvasSize: landscape)
        let counter = CountingSink()
        engine.addSink(counter)
        var config = LayoutConfig()
        config.camera.faceTracking = false
        engine.update(config: config, transitions: TransitionSettings())
        engine.setSources(SceneSources(slides: .display(1), demo: .display(1)), at: 0)
        engine.setScene(.demo, animated: false, at: 0)
        await withCheckedContinuation { continuation in
            engine.applyAssets(RenderEngine.AssetConfig(canvas: landscape)) { continuation.resume() }
        }

        let framePreference = "NSWindow Frame ProgramOutput"
        let oldFramePreference = UserDefaults.standard.object(forKey: framePreference)
        let output = ProgramWindowController(engine: engine, canvas: landscape)
        // This diagnostic must not replace the user's saved output-window position.
        output.window.setFrameAutosaveName("")
        output.window.setFrameOrigin(NSPoint(x: -4000, y: -3000))
        defer {
            output.window.close()
            engine.removeSink(counter)
            engine.stop()
            if let oldFramePreference {
                UserDefaults.standard.set(oldFramePreference, forKey: framePreference)
            } else {
                UserDefaults.standard.removeObject(forKey: framePreference)
            }
        }
        var checks = 0
        func check(_ value: @autoclosure () -> Bool, _ name: String) throws {
            guard value() else { throw Failure(message: "会议输出自测失败：\(name)") }
            checks += 1
        }
        try check(output.window.title == ProgramWindowController.shareWindowTitle, "窗口使用明确的会议共享标题")
        try check(output.window.sharingType != .none, "窗口没有禁止其他应用读取")
        try check(output.window.contentView is PreviewNSView, "内容区只有节目画面，不包含主控制界面")
        try check(output.window.contentAspectRatio == landscape, "初始横屏比例正确")
        try check(!output.isOutputActive, "未打开输出时不持有防休眠活动")
        guard let preview = output.window.contentView as? PreviewNSView else { throw Failure(message: "输出预览类型错误") }

        engine.start(fps: 30)
        engine.synchronize()
        output.show()
        try await wait("未录制时持续输出") { counter.frames >= 4 && preview.displayLayer.contents != nil }
        try check(engine.isRunning && output.window.isVisible, "无需录制即可运行输出窗口")
        try check(output.isOutputActive, "输出期间持有独立防休眠活动")
        try check(preview.displayLayer.bounds.width > 0 && preview.displayLayer.bounds.height > 0, "画面图层覆盖输出内容区")
        output.show()
        try check(output.isOutputActive && output.window.isVisible, "重复打开保持同一输出生命周期")

        let previousSurface = surface(in: preview)
        let beforeSceneChange = counter.frames
        engine.setScene(.camera, animated: false)
        try await wait("切镜头更新输出画面") {
            guard let current = surface(in: preview) else { return false }
            return counter.frames > beforeSceneChange + 2 && current !== previousSurface
        }
        try check(preview.displayLayer.contents != nil, "会议输出随镜头切换更新")
        try save(preview, to: directory.appendingPathComponent("meeting-output-landscape.png"))
        checks += 1

        let beforeClose = counter.frames
        output.window.close()
        try check(!output.isOutputActive, "关闭输出释放防休眠活动")
        try check(!output.window.isVisible, "关闭输出窗口隐藏")
        try await wait("关闭输出不影响其他帧消费者") { counter.frames > beforeClose + 3 }
        try check(engine.isRunning, "关闭输出不停止合成引擎")
        try check(counter.frames > beforeClose + 3, "独立帧消费者在输出关闭后继续收到画面")

        engine.setCanvasSize(portrait)
        engine.synchronize()
        output.updateCanvas(portrait)
        output.show()
        let beforeReopen = counter.frames
        try await wait("重开竖屏输出") { counter.frames > beforeReopen + 3 && preview.displayLayer.contents != nil }
        try check(output.isOutputActive && output.window.isVisible, "关闭后可再次打开输出")
        try check(output.window.contentAspectRatio == portrait, "输出窗口跟随竖屏比例")
        let content = preview.bounds.size
        try check(abs(content.width / max(1, content.height) - 9.0 / 16.0) < 0.01, "竖屏客户区没有拉伸为横屏")
        try save(preview, to: directory.appendingPathComponent("meeting-output-portrait.png"))
        checks += 1
        output.window.close()
        try check(!output.isOutputActive && engine.isRunning, "再次关闭输出仍与引擎生命周期隔离")
        try check((try? Data(contentsOf: SettingsStore.fileURL)) == settingsBefore, "没有写入个人设置")
        try "Meeting output: \(checks) checks passed\nSynthetic frames only; no recording, device capture or meeting clients.\n"
            .write(to: directory.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("Meeting output artifacts: \(directory.path)")
        return checks
    }

    @MainActor
    private static func wait(_ name: String, condition: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while !condition() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw Failure(message: "会议输出自测等待超时：\(name)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    private static func surface(in view: PreviewNSView) -> AnyObject? {
        guard let contents = view.displayLayer.contents else { return nil }
        return contents as AnyObject
    }

    @MainActor
    private static func save(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw Failure(message: "无法创建输出窗口截图") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(message: "无法编码输出窗口截图") }
        try png.write(to: url)
    }
}
