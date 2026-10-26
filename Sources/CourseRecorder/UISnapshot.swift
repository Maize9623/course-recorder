import Foundation
import AppKit
import SwiftUI

/// `CourseRecorder --ui-snapshot <dir> [cameraImage] [--slides-only] [--deck <file>]` renders the main window and
/// control bar offscreen, with synthetic sources and without touching camera / microphone / screen capture or the
/// user's settings file.
enum UISnapshot {
    static func run(_ args: [String]) -> Int32 {
        let dir = URL(fileURLWithPath: args.first ?? "ui-snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)

        let app = AppState()
        app.persistsSettings = false
        app.settings.demo.sources = [.display(1), .window(7)]
        app.settings.slides.source = .display(1)
        app.settings.slides.deckPath = ""
        if args.contains("--portrait") { app.settings.recording.aspect = .portrait }
        if let i = args.firstIndex(of: "--deck"), i + 1 < args.count { app.settings.slides.deckPath = args[i + 1] }
        let ctx = app.ciContext
        // Synthetic content so the preview shows something meaningful.
        if args.count > 1, let cg = app.assets.loadImage(path: args[1]), let pb = SelfTest.makePixelBuffer(cg, ctx: ctx) {
            var pc = CameraProcessingConfig()
            pc.background = app.settings.background
            app.processor.update(pc)
            _ = app.processor.process(pb, hostTime: 0)
            Thread.sleep(forTimeInterval: 1)
            if let f = app.processor.process(pb, hostTime: 0) { app.store.setCamera(f) }
        } else if let cg = SelfTest.syntheticPerson(assets: app.assets), let pb = SelfTest.makePixelBuffer(cg, ctx: ctx) {
            app.store.setCamera(CameraFrame(processed: pb, cutout: nil, size: CGSize(width: cg.width, height: cg.height),
                                            face: CGPoint(x: 0.5, y: 0.45), captureTime: 0))
        }
        if let ui = SelfTest.mockAppWindow(CGSize(width: 2880, height: 1800), assets: app.assets), let pb = SelfTest.makePixelBuffer(ui, ctx: ctx) {
            app.store.setScreen(ScreenFrame(pixelBuffer: pb, contentRect: CGRect(x: 0, y: 0, width: 2880, height: 1800), hostTime: 0), for: .display(1))
        }
        app.displays = [CaptureSourceInfo(ref: .display(1), name: "显示器 1 · 内建视网膜显示器", detail: "3024×1964 · 主屏",
                                          pixelSize: CGSize(width: 3024, height: 1964), frame: CGRect(x: 0, y: 0, width: 1512, height: 982)),
                        CaptureSourceInfo(ref: .display(2), name: "显示器 2 · DELL U2723QE", detail: "3840×2160",
                                          pixelSize: CGSize(width: 3840, height: 2160), frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080))]
        app.windows = [CaptureSourceInfo(ref: .window(7), name: "Google Chrome — 迷宫小游戏", detail: "1440×900",
                                         pixelSize: CGSize(width: 2880, height: 1800), frame: .zero)]
        app.screenPermission = true
        app.resolveSources(direction: 1)
        app.makeThumbnails()
        app.engine.start(fps: 30)
        app.engine.applyAssets(RenderEngine.AssetConfig(backdrop: app.settings.demo.backdrop, customBackdrop: "",
                                                        overlay: app.settings.overlay, borderColor: app.settings.pip.borderColor,
                                                        canvas: app.settings.recording.outputSize))
        app.cameraStatus = CameraStatus(running: true, deviceName: "FaceTime HD 相机", format: "1920×1080 · 30fps", error: nil)
        app.selectScene(.demo)
        if let i = args.firstIndex(of: "--scene"), i + 1 < args.count, let scene = SceneKind(rawValue: args[i + 1]) {
            app.selectScene(scene)
        }
        if args.contains("--devices-off") {
            app.toggleCamera()
            app.toggleMicMute()
        }

        var snapshotWidth: CGFloat = 1460
        if let i = args.firstIndex(of: "--width"), i + 1 < args.count,
           let width = Double(args[i + 1]), width >= 800, width <= 3000 {
            snapshotWidth = CGFloat(width)
        }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: snapshotWidth, height: 920),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingView(rootView: MainView().environmentObject(app))
        window.contentView = hosting
        window.setFrameOrigin(NSPoint(x: -4000, y: -4000))
        window.orderBack(nil)

        func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
        func snap(_ view: NSView, _ name: String) {
            view.layoutSubtreeIfNeeded()
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            let url = dir.appendingPathComponent(name)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }

        spin(2.5)
        if args.contains("--production") {
            app.workMode = .production
            app.inspectorTab = .production
            if args.contains("--import-paused") {
                app.narrationImportProgress = 0.42
                app.narrationImportStatus = "正在导入视频…"
                app.pausePreviewForNarrationImport(token: UUID())
            }
            if let i = args.firstIndex(of: "--project"), i + 1 < args.count {
                let folder = URL(fileURLWithPath: args[i + 1], isDirectory: true)
                if let project = ProjectStore.load(folder) {
                    app.production.open(project, folder: folder)
                    if !project.deckPath.isEmpty { app.loadDeck(project.deckPath) }
                    if args.contains("--ai-review") {
                        let cues = project.sortedCues
                        let draft = AIShotDraft(cues: cues, review: cues.map {
                            AIShotReviewRow(cue: $0, reason: "合成测试：按课程内容切换画面，便于审核时间点。")
                        }, summary: "按开场、课件讲解和软件操作安排画面，请预览后采纳。", warnings: [])
                        app.aiProduction.present(draft, project: project, folder: folder, splitContent: app.settings.split.content)
                    }
                }
            }
            spin(1)
            snap(hosting, "main_production.png")
            print("ui snapshots written to \(dir.path)")
            return 0
        }
        if args.contains("--slides-only") {
            if !app.settings.slides.deckPath.isEmpty { app.loadDeck(app.settings.slides.deckPath) }
            spin(4)
            app.selectScene(.slides)
            app.goToSlide(2)
            spin(1.5)
            snap(hosting, "main_slides.png")
            print("ui snapshots written to \(dir.path)")
            return 0
        }
        for tab in InspectorTab.allCases {
            app.inspectorTab = tab
            spin(0.6)
            snap(hosting, "main_\(tab.rawValue).png")
        }

        let bar = ControlBarController(app: app)
        bar.panel.setFrameOrigin(NSPoint(x: -4000, y: -3000))
        bar.panel.orderBack(nil)
        spin(0.8)
        if let v = bar.panel.contentView { snap(v, "control_bar.png") }

        print("ui snapshots written to \(dir.path)")
        return 0
    }
}
