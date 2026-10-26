import Foundation
import AppKit
import CoreImage
import QuartzCore

/// `CourseRecorder --capture-test`: exercises ScreenCaptureKit capture of every display and the compositor
/// with live frames. Prints numbers only (no images are written, so screen contents stay private).
enum CaptureTest {
    static func run() -> Int32 {
        _ = NSApplication.shared
        guard CGPreflightScreenCaptureAccess() else {
            print("no screen recording permission in this context; skipping")
            return 0
        }
        let ctx = CIContext(options: [.cacheIntermediates: false])
        let store = FrameStore()
        let screens = ScreenCaptureManager(store: store)
        var listed = false
        screens.onSourcesChanged = { d, w in
            print("displays: \(d.count), windows: \(w.count)")
            for x in d { print("  \(x.ref.key) \(x.detail) frame=\(x.frame)") }
            listed = true
        }
        screens.onError = { print("error: \($0)"); listed = true }
        screens.refresh()
        spin(until: { listed }, timeout: 10)
        let refs = screens.displays.map(\.ref)
        guard !refs.isEmpty else { return 1 }

        func measure(_ seconds: Double, label: String) {
            var counts: [SourceRef: Int] = [:]
            var last: [SourceRef: Double] = [:]
            let t0 = CACurrentMediaTime()
            while CACurrentMediaTime() - t0 < seconds {
                for r in refs {
                    if let f = store.screen(r), f.hostTime != last[r] {
                        counts[r, default: 0] += 1
                        last[r] = f.hostTime
                    }
                }
                RunLoop.main.run(until: Date().addingTimeInterval(0.002))
            }
            for r in refs {
                let f = store.screen(r)
                let size = f.map { "\(CVPixelBufferGetWidth($0.pixelBuffer))×\(CVPixelBufferGetHeight($0.pixelBuffer)) content=\($0.contentRect.size)" } ?? "no frame"
                let luma = f.map { String(format: "%.3f", meanLuma($0, ctx)) } ?? "-"
                print("  [\(label)] \(r.key): \(counts[r] ?? 0) new frames in \(seconds)s, \(size), mean luma \(luma)")
            }
        }

        screens.setWanted(refs, focus: refs.first, throttle: true)
        measure(3, label: "focus \(refs[0].key)")
        if refs.count > 1 {
            screens.setWanted(refs, focus: refs[1], throttle: true)
            measure(2, label: "focus \(refs[1].key)")
        }

        // Compositor with live screen frames (camera placeholder).
        let assets = AssetFactory(context: ctx)
        let engine = RenderEngine(context: ctx, store: store, assets: assets, cursor: CursorTracker(), canvasSize: CGSize(width: 1920, height: 1080))
        engine.screens = screens
        var ready = false
        engine.applyAssets(RenderEngine.AssetConfig()) { ready = true }
        spin(until: { ready }, timeout: 5)
        engine.setSources(SceneSources(slides: refs.first, demo: refs.first))
        engine.setScene(.demo, animated: false)
        _ = engine.renderFrame(at: CACurrentMediaTime())
        let t0 = CACurrentMediaTime()
        for i in 0..<60 { _ = engine.renderFrame(at: t0 + Double(i) / 60) }
        print(String(format: "  compositor with live display: %.2f ms/frame", (CACurrentMediaTime() - t0) / 60 * 1000))
        screens.stopAll()
        spin(until: { false }, timeout: 0.5)
        return 0
    }

    private static func spin(until done: () -> Bool, timeout: Double) {
        let end = Date().addingTimeInterval(timeout)
        while !done() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    private static func meanLuma(_ f: ScreenFrame, _ ctx: CIContext) -> Double {
        let img = CIImage(cvPixelBuffer: f.pixelBuffer)
        let avg = img.applyingFilter("CIAreaAverage", parameters: [kCIInputExtentKey: CIVector(cgRect: img.extent)])
        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(avg, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (0.2126 * Double(px[0]) + 0.7152 * Double(px[1]) + 0.0722 * Double(px[2])) / 255
    }
}
