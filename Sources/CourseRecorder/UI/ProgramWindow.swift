import AppKit

/// A clean live program window for meeting screen sharing and OBS window capture.
final class ProgramWindowController: NSObject, NSWindowDelegate {
    static let shareWindowTitle = "会议共享画面 · 课程录制工具"
    let window: NSWindow
    private let view = PreviewNSView(frame: .zero)
    private weak var engine: RenderEngine?
    private var outputActivity: NSObjectProtocol?

    /// Local output availability, independent of recording or any meeting client's sharing state.
    var isOutputActive: Bool { outputActivity != nil }

    init(engine: RenderEngine, canvas: CGSize) {
        self.engine = engine
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let natural = NSSize(width: canvas.width / scale, height: canvas.height / scale)
        let fit = min(1, min(visible.width * 0.85 / max(1, natural.width), visible.height * 0.85 / max(1, natural.height)))
        let size = NSSize(width: natural.width * fit, height: natural.height * fit)
        window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        super.init()
        window.title = Self.shareWindowTitle
        window.contentAspectRatio = canvas
        window.isReleasedWhenClosed = false
        window.backgroundColor = .black
        window.contentView = view
        window.delegate = self
        window.setFrameAutosaveName("ProgramOutput")
        if !window.setFrameUsingName("ProgramOutput") { window.center() }
        updateCanvas(canvas)
    }

    /// Keep an already-open program window at the active output aspect ratio.
    func updateCanvas(_ canvas: CGSize) {
        guard canvas.width > 0, canvas.height > 0 else { return }
        let ratio = canvas.width / canvas.height
        let current = window.contentView?.bounds.size ?? canvas
        window.contentAspectRatio = canvas
        guard current.width > 0, current.height > 0,
              abs(current.width / current.height - ratio) > 0.001 else { return }
        let area = current.width * current.height
        let natural = NSSize(width: sqrt(area * ratio), height: sqrt(area / ratio))
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame.size ?? NSSize(width: 1280, height: 800)
        let fit = min(1, min(visible.width * 0.85 / max(1, natural.width), visible.height * 0.85 / max(1, natural.height)))
        window.setContentSize(NSSize(width: natural.width * fit, height: natural.height * fit))
    }

    func show() {
        if let engine { updateCanvas(engine.canvas.size) }
        if outputActivity == nil {
            outputActivity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .latencyCritical, .idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: "会议或直播画面输出")
        }
        engine?.addSink(view.sink)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        engine?.removeSink(view.sink)
        endOutputActivity()
    }

    private func endOutputActivity() {
        if let outputActivity { ProcessInfo.processInfo.endActivity(outputActivity) }
        outputActivity = nil
    }

    deinit {
        endOutputActivity()
    }
}
