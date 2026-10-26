import AppKit
import Combine

private final class PrompterBackground: NSView {
    var opacity: CGFloat = 0.86 { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(calibratedWhite: 0.05, alpha: opacity).setFill()
        bounds.fill()
    }
}

private final class ReadingGuide: NSView {
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let y = bounds.height * 0.32
        NSColor(calibratedRed: 0.66, green: 0.55, blue: 0.98, alpha: 0.9).setFill()
        NSBezierPath(roundedRect: NSRect(x: 8, y: y - 9, width: 6, height: 18), xRadius: 3, yRadius: 3).fill()
        NSBezierPath(roundedRect: NSRect(x: bounds.width - 14, y: y - 9, width: 6, height: 18), xRadius: 3, yRadius: 3).fill()
        let fade = NSGradient(starting: NSColor(calibratedWhite: 0.05, alpha: 0.9), ending: NSColor(calibratedWhite: 0.05, alpha: 0))
        fade?.draw(in: NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.16), angle: 90)
        fade?.draw(in: NSRect(x: 0, y: bounds.height * 0.84, width: bounds.width, height: bounds.height * 0.16), angle: -90)
    }
}

/// Floating teleprompter. It belongs to this app, so screen capture never records it.
final class TeleprompterController: NSObject, NSWindowDelegate {
    let panel: NSPanel
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let background = PrompterBackground()
    private let guide = ReadingGuide()
    private var timer: Timer?
    private var speed: Double = 36
    private var cancellable: AnyCancellable?
    private(set) var playing = false
    private var lastTick: CFTimeInterval = 0

    init(app: AppState) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 250),
                        styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .utilityWindow, .hudWindow],
                        backing: .buffered, defer: false)
        super.init()
        panel.title = "提词器（不会被录进视频）"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.minSize = NSSize(width: 360, height: 140)

        let container = NSView()
        container.wantsLayer = true
        background.autoresizingMask = [.width, .height]
        container.addSubview(background)

        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.autoresizingMask = [.width, .height]
        container.addSubview(scrollView)
        guide.autoresizingMask = [.width, .height]
        container.addSubview(guide)
        panel.contentView = container
        layoutViews()

        panel.setFrameAutosaveName("Teleprompter")
        if !panel.setFrameUsingName("Teleprompter"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - 380, y: f.maxY - 270))
        }
        cancellable = app.$settings.map(\.teleprompter).removeDuplicates().sink { [weak self] t in
            self?.apply(t)
        }
        NotificationCenter.default.addObserver(forName: NSWindow.didResizeNotification, object: panel, queue: .main) { [weak self] _ in
            self?.layoutViews()
        }
    }

    private func layoutViews() {
        guard let c = panel.contentView else { return }
        background.frame = c.bounds
        scrollView.frame = c.bounds.insetBy(dx: 24, dy: 0)
        guide.frame = c.bounds
        let h = c.bounds.height
        textView.textContainerInset = NSSize(width: 0, height: max(20, h * 0.32 - 20))
        textView.minSize = NSSize(width: 0, height: h)
        textView.frame.size.width = scrollView.contentSize.width
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        textView.sizeToFit()
    }

    private func apply(_ t: TeleprompterSettings) {
        speed = t.speed
        background.opacity = CGFloat(t.opacity)
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineSpacing = CGFloat(t.lineSpacing)
        style.paragraphSpacing = CGFloat(t.lineSpacing) + CGFloat(t.fontSize) * 0.4
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: CGFloat(t.fontSize), weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        let tail = String(repeating: "\n", count: 8)
        let offset = scrollView.contentView.bounds.origin.y
        textView.textStorage?.setAttributedString(NSAttributedString(string: t.text + tail, attributes: attrs))
        layoutViews()
        scroll(to: offset)
    }

    func handle(_ cmd: TeleprompterCommand) {
        switch cmd {
        case .show: panel.orderFrontRegardless()
        case .hide: panel.orderOut(nil)
        case .toggleVisible: panel.isVisible ? panel.orderOut(nil) : panel.orderFrontRegardless()
        case .togglePlay:
            if !panel.isVisible { panel.orderFrontRegardless() }
            playing ? pause() : play()
        case .rewind:
            scroll(to: 0)
        }
    }

    private func play() {
        playing = true
        lastTick = CACurrentMediaTime()
        timer?.invalidate()
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in self?.step() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func pause() {
        playing = false
        timer?.invalidate()
        timer = nil
    }

    private func step() {
        let now = CACurrentMediaTime()
        let dt = min(0.1, now - lastTick)
        lastTick = now
        let clip = scrollView.contentView
        let maxY = max(0, textView.frame.height - clip.bounds.height)
        let y = clip.bounds.origin.y + CGFloat(speed * dt)
        if y >= maxY {
            scroll(to: maxY)
            pause()
        } else {
            scroll(to: y)
        }
    }

    private func scroll(to y: CGFloat) {
        let clip = scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    func windowWillClose(_ notification: Notification) {
        pause()
    }
}
