import SwiftUI
import AppKit
import Combine

/// Hosting view that reacts to the first click even when the panel is not key.
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ControlBarPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Transparent AppKit view that drags its window; SwiftUI views over a borderless panel cannot do that themselves.
final class WindowDragView: NSView {
    override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }
}

struct WindowDragArea: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowDragView { WindowDragView() }
    func updateNSView(_ nsView: WindowDragView, context: Context) {}
}

/// Six-dot grip that drags the panel.
struct DragGrip: View {
    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<3, id: \.self) { _ in
                HStack(spacing: 3) {
                    Circle().frame(width: 3, height: 3)
                    Circle().frame(width: 3, height: 3)
                }
            }
        }
        .foregroundStyle(Color.white.opacity(0.45))
        .frame(width: 16, height: 28)
        .contentShape(Rectangle())
        .overlay(WindowDragArea())
        .help("拖动移动控制条")
    }
}

/// Floating, non-activating control bar: clicking it never takes focus away from the app being demoed.
final class ControlBarController {
    let panel: ControlBarPanel
    private weak var app: AppState?
    private let hosting: NSView
    private var cancellable: AnyCancellable?

    init(app: AppState) {
        self.app = app
        let root = ControlBarView(live: app.live).environmentObject(app)
        let hostingView = FirstMouseHostingView(rootView: root)
        hostingView.sizingOptions = [.intrinsicContentSize]
        hosting = hostingView
        let size = hostingView.fittingSize
        panel = ControlBarPanel(contentRect: NSRect(origin: .zero, size: size),
                                styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovable = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.contentView = hostingView
        panel.setFrameAutosaveName("ControlBar")
        if !panel.setFrameUsingName("ControlBar"), let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - size.width / 2, y: f.minY + 24))
        }
        fitToContent()
        DispatchQueue.main.async { [weak self] in self?.fitToContent() }
        cancellable = app.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.fitToContent() }
        }
    }

    /// Keeps the panel sized to its content. The left edge (where the grip is) stays put, and the panel stays on screen.
    private func fitToContent() {
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        var f = panel.frame
        guard abs(size.width - f.width) > 0.5 || abs(size.height - f.height) > 0.5 else { return }
        f.size = size
        if let v = (panel.screen ?? NSScreen.main)?.visibleFrame {
            f.origin.x = min(max(f.origin.x, v.minX + 4), v.maxX - size.width - 4)
            f.origin.y = min(max(f.origin.y, v.minY + 4), v.maxY - size.height - 4)
        }
        panel.setFrame(f, display: true)
    }

    var isVisible: Bool { panel.isVisible }

    func show() {
        panel.orderFrontRegardless()
        app?.settings.controlBarVisible = true
    }

    func hide() {
        panel.orderOut(nil)
        app?.settings.controlBarVisible = false
        if let app {
            app.showToast("控制条已隐藏：按 \(app.settings.combo(for: .controlBar).display) 或点菜单栏的 🎥 图标再次显示", icon: "eye.slash")
        }
    }

    func toggle() {
        isVisible ? hide() : show()
    }
}

struct ControlBarView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var live: LiveStatus

    var body: some View {
        Group {
            if app.settings.controlBarCollapsed { mini } else { full }
        }
        .background(VisualEffectBackground(material: .hudWindow))
        .background(Color.black.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.14)))
        .fixedSize()
        .preferredColorScheme(.dark)
    }

    /// Collapsed pill: grip, recording state, expand and close.
    private var mini: some View {
        HStack(spacing: 6) {
            DragGrip()
            recordCluster
            BarButton(icon: "arrow.up.left.and.arrow.down.right", active: false, help: "展开控制条") {
                app.settings.controlBarCollapsed = false
            }
            BarButton(icon: "xmark", active: false,
                      help: "隐藏（\(app.settings.combo(for: .controlBar).display) 或菜单栏图标可再次显示）") {
                app.onToggleControlBar?()
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var full: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                DragGrip()
                recordCluster
                separator
                ForEach(SceneKind.allCases) { s in
                    BarButton(icon: s == .split && app.settings.recording.aspect == .portrait ? "rectangle.split.1x2.fill" : s.symbol, label: "\(s.number)", active: app.scene == s, help: "\(s.number) \(s.title)") {
                        app.selectScene(s)
                    }
                }
                separator
                BarButton(icon: app.pipHidden ? "person.crop.circle.badge.xmark" : "person.crop.circle", active: !app.pipHidden,
                          help: "小窗人像 \(app.settings.combo(for: .togglePIP).display)") { app.togglePIP() }
                BarButton(icon: "rectangle.2.swap", label: app.shortSourceName(app.stripShowsSlides ? app.slidesSource : app.currentDemoSource),
                          active: false, help: "切换\(app.stripShowsSlides ? "讲解" : "演示")画面 \(app.settings.combo(for: .nextSource).display)") { app.nextSource() }
                BarButton(icon: "plus.magnifyingglass", active: app.zoomed,
                          help: "跟随放大 \(app.settings.combo(for: .toggleZoom).display)") { app.toggleZoom() }
                if let deck = app.deck, app.slidesSource == .slides {
                    separator
                    BarButton(icon: "chevron.left", active: false, help: "上一页") { app.previousSlide() }
                    Text("\(app.slideIndex + 1)/\(deck.pageCount)")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.75))
                    BarButton(icon: "chevron.right", active: false, help: "下一页") { app.nextSlide() }
                }
                separator
                BarButton(icon: "flag", active: false, help: "章节打点 \(app.settings.combo(for: .marker).display)") { app.addMarker(.chapter) }
                BarButton(icon: "scissors", active: false, help: "口误打点 \(app.settings.combo(for: .markerNG).display)") { app.addMarker(.mistake) }
                BarButton(icon: "music.note", active: live.bgm.playing, help: "BGM \(app.settings.combo(for: .bgm).display)") { app.toggleBGM() }
                BarButton(icon: app.micMuted ? "mic.slash.fill" : "mic.fill", active: false, tint: app.micMuted ? Theme.red : nil,
                          help: "麦克风静音 \(app.settings.combo(for: .micMute).display)") { app.toggleMicMute() }
                LevelMeter(db: app.micMuted ? -120 : live.micDB, height: 5).frame(width: 46)
                BarButton(icon: "text.justify.left", active: false, help: "提词器") { app.onTeleprompter?(.toggleVisible) }
                BarButton(icon: "macwindow", active: false, help: "打开主窗口") { app.onShowMainWindow?() }
                separator
                BarButton(icon: "arrow.down.right.and.arrow.up.left", active: false, help: "收起成小按钮") {
                    app.settings.controlBarCollapsed = true
                }
            }
            HStack(spacing: 8) {
                statusLine
                Spacer(minLength: 8)
                if let t = app.toast {
                    Label(t.text, systemImage: t.icon)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .frame(height: 16)
            .padding(.leading, 22)
            .overlay(WindowDragArea())
            .animation(.easeOut(duration: 0.2), value: app.toast)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var separator: some View {
        Rectangle().fill(Color.white.opacity(0.15)).frame(width: 1, height: 22).padding(.horizontal, 2)
    }

    @ViewBuilder
    private var recordCluster: some View {
        switch app.recState {
        case .idle:
            Button { app.toggleRecording() } label: {
                HStack(spacing: 6) {
                    Circle().fill(Theme.red).frame(width: 10, height: 10)
                    Text("录制").font(.system(size: 12, weight: .semibold)).fixedSize()
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Capsule().fill(Color.white.opacity(0.1)))
            }
            .buttonStyle(.plain)
            .help("开始录制 \(app.settings.combo(for: .record).display)")
        case .countdown(let n):
            Button { app.toggleRecording() } label: {
                Text("\(n)…").font(.system(size: 14, weight: .heavy, design: .rounded)).foregroundStyle(Theme.amber)
                    .frame(width: 58)
            }
            .buttonStyle(.plain)
        case .recording, .paused, .finishing:
            HStack(spacing: 6) {
                Button { app.toggleRecording() } label: {
                    RoundedRectangle(cornerRadius: 3).fill(Theme.red).frame(width: 11, height: 11)
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("停止并保存")
                Text(formatTimecode(live.elapsed))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(app.recState == .paused ? Theme.amber : .white)
                Button { app.togglePause() } label: {
                    Image(systemName: app.recState == .paused ? "play.fill" : "pause.fill")
                        .font(.system(size: 11)).foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            Circle().fill(app.recState == .recording ? Theme.red : (app.recState == .paused ? Theme.amber : Color.white.opacity(0.35)))
                .frame(width: 6, height: 6)
            Text(statusText).font(.system(size: 11)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
    }

    private var statusText: String {
        let state: String
        switch app.recState {
        case .idle: state = "未录制"
        case .countdown: state = "准备开始"
        case .recording: state = "录制中"
        case .paused: state = "已暂停"
        case .finishing: state = "正在保存"
        }
        var parts = [state, "\(app.scene.number) \(app.scene.title)"]
        if app.scene == .demo { parts.append(app.shortSourceName(app.currentDemoSource)) }
        if app.recState.isActive && !app.markers.isEmpty { parts.append("打点 \(app.markers.count)") }
        return parts.joined(separator: " · ")
    }
}

struct BarButton: View {
    let icon: String
    var label: String? = nil
    let active: Bool
    var tint: Color? = nil
    var help: String = ""
    let action: () -> Void
    @StateObject private var hover = ViewState(false)

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 12, weight: .medium))
                if let label {
                    Text(label).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                }
            }
            .foregroundStyle(tint ?? (active ? Color.white : Color.white.opacity(0.78)))
            .padding(.horizontal, label == nil ? 0 : 7)
            .frame(minWidth: 28, minHeight: 28)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(active ? Theme.accent.opacity(0.9) : Color.white.opacity(hover.value ? 0.14 : 0.06)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .help(help)
    }
}
