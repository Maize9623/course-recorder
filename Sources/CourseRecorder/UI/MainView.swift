import SwiftUI
import AppKit

struct MainView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            TopBar(live: app.live)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            HStack(spacing: 0) {
                StageView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.stroke).frame(width: 1)
                InspectorView()
                    .frame(width: 392)
            }
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .overlay(alignment: .top) { ToastView().padding(.top, 70) }
    }
}

// MARK: - Top bar

struct TopBar: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var live: LiveStatus

    var body: some View {
        HStack(spacing: 14) {
            OutputAspectMenu()
                .frame(width: 56)
                .padding(.top, 14)

            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Theme.accent, Color(red: 0.93, green: 0.36, blue: 0.75)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "video.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("课程录制工具").font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.text)
                    Text(outputSummary).font(.system(size: 11)).foregroundStyle(Theme.text3)
                }
            }

            WorkModeSwitch()

            Spacer(minLength: 12)
            StatusChips(live: live)
            Spacer(minLength: 12)

            RecordControls(live: live)
                .layoutPriority(1)

            HStack(spacing: 4) {
                TopIconButton(icon: "slider.horizontal.below.rectangle", help: "悬浮控制条（\(app.settings.combo(for: .controlBar).display)）") {
                    app.onToggleControlBar?()
                }
                TopIconButton(icon: "text.justify.left", help: "提词器") { app.onTeleprompter?(.toggleVisible) }
                Button { app.onShowProgram?() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tv").font(.system(size: 11, weight: .medium))
                        Text("共享").font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(Theme.text2)
                    .frame(width: 56, height: 30)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                    .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke))
                }
                .buttonStyle(.plain)
                .help("打开会议共享画面 / OBS；在会议共享窗口中选择「\(ProgramWindowController.shareWindowTitle)」")
                .accessibilityLabel("打开会议共享画面")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Theme.panel)
    }

    private var outputSummary: String {
        let r = app.settings.recording
        return "\(r.resolution.title) · \(r.aspect.detail) · \(r.fps)fps · \(r.codec == .h264 ? "H.264" : "HEVC")"
    }
}

/// Compact format toggle below the standard window buttons.
struct OutputAspectMenu: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button {
            app.setOutputAspect(app.settings.recording.aspect == .landscape ? .portrait : .landscape)
        } label: {
            VStack(spacing: 1) {
                HStack(spacing: 3) {
                    Image(systemName: app.settings.recording.aspect.symbol).font(.system(size: 10))
                    Text(app.settings.recording.aspect.title).font(.system(size: 10, weight: .semibold))
                    Image(systemName: "arrow.left.arrow.right").font(.system(size: 7, weight: .semibold))
                }
                Text(app.settings.recording.aspect.detail).font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(Theme.text2)
            .frame(width: 56, height: 30)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
        .disabled(!app.canChangeOutputFormat)
        .help(app.canChangeOutputFormat ? "点击切换输出比例：横屏 16:9 / 竖屏 9:16" : "录制、播放或处理项目期间不能切换输出比例")
        .accessibilityLabel("输出比例")
        .accessibilityValue("\(app.settings.recording.aspect.title) \(app.settings.recording.aspect.detail)")
    }
}

struct TopIconButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 32, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 7).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

struct StatusChips: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var live: LiveStatus

    var body: some View {
        HStack(spacing: 8) {
            if app.narrationImportPreviewPaused {
                chip(icon: "pause.circle", text: "导入中 · 预览暂停", color: Theme.accentSoft)
            } else {
                chip(icon: "speedometer", text: String(format: "%.0f fps · %.1f ms", live.renderFPS, live.renderMs),
                     color: live.renderFPS >= Double(app.settings.recording.fps) * 0.9 ? Theme.green : Theme.amber)
                Button { app.toggleCamera() } label: {
                    chip(icon: cameraIcon, text: cameraLabel, color: cameraColor)
                }
                .buttonStyle(.plain)
                .disabled(!app.canToggleCamera)
                .help(app.cameraToggleHelp)
                .accessibilityLabel("摄像头开关")
                .accessibilityValue(cameraLabel)
            }
            Button { app.toggleMicMute() } label: {
                HStack(spacing: 6) {
                    Image(systemName: app.micMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(app.micMuted ? Theme.red : (app.micError == nil ? Theme.green : Theme.amber))
                    if app.micMuted {
                        Text("已静音").font(.system(size: 11)).foregroundStyle(Theme.red).frame(width: 64)
                    } else {
                        LevelMeter(db: live.micDB, height: 5).frame(width: 64)
                    }
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Theme.card))
            }
            .buttonStyle(.plain)
            .help(app.micMuted ? "取消麦克风静音" : "麦克风静音；系统声音和 BGM 继续保留")
            .accessibilityLabel("麦克风静音开关")
            .accessibilityValue(app.micMuted ? "已静音" : "未静音")
            if live.bgm.playing {
                chip(icon: "music.note", text: live.bgm.trackName, color: Theme.accentSoft)
                    .frame(maxWidth: 160)
            }
        }
    }

    private var cameraLabel: String {
        if app.production.isLoaded { return "口播回放" }
        if app.cameraSwitchInProgress { return "摄像头关闭中" }
        if !app.cameraEnabled { return "摄像头已关闭" }
        return app.cameraStatus.running ? String(format: "摄像头 %.0f fps", live.cameraFPS) : "摄像头未开启"
    }

    private var cameraIcon: String {
        if app.production.isLoaded { return "play.rectangle.fill" }
        return app.cameraEnabled && app.cameraStatus.running ? "video.fill" : "video.slash.fill"
    }

    private var cameraColor: Color {
        if app.production.isLoaded { return Theme.accentSoft }
        if app.cameraSwitchInProgress { return Theme.amber }
        if !app.cameraEnabled { return Theme.red }
        return app.cameraStatus.running ? Theme.green : Theme.amber
    }

    private func chip(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 10)).foregroundStyle(color)
            Text(text).font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(Theme.card))
    }
}

struct RecordControls: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var live: LiveStatus

    var body: some View {
        HStack(spacing: 8) {
            switch app.recState {
            case .idle:
                Button { app.toggleRecording() } label: {
                    HStack(spacing: 7) {
                        Circle().fill(.white).frame(width: 9, height: 9)
                        Text(app.workMode == .production
                             ? (app.production.project?.hasNarration == true ? "重录口播" : "开始录口播")
                             : "开始录制")
                            .font(.system(size: 13, weight: .semibold))
                        KeyHint(text: app.settings.combo(for: .record).display)
                    }
                }
                .buttonStyle(PillButtonStyle(tone: .danger))
                .disabled(app.workMode == .production && (app.cameraSwitchInProgress || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || app.production.isFinishingTakes))
                .help(app.workMode == .production && app.production.project == nil ? "先命名并创建项目，再按录制设置开始录口播" : "开始录制")
            case .countdown(let n):
                Button { app.toggleRecording() } label: {
                    Text("\(n) 秒后开始 · 取消").font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(PillButtonStyle(tone: .secondary))
            case .recording, .paused, .finishing:
                HStack(spacing: 6) {
                    Circle().fill(app.recState == .paused ? Theme.amber : Theme.red).frame(width: 9, height: 9)
                    Text(formatTimecode(live.elapsed)).font(.system(size: 14, weight: .semibold, design: .monospaced))
                    Text(formatBytes(live.fileSize)).font(.system(size: 11)).foregroundStyle(Theme.text3)
                    if live.dropped > 0 {
                        Text("丢帧 \(live.dropped)").font(.system(size: 11)).foregroundStyle(Theme.amber)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Capsule().fill(Theme.card))
                Button { app.togglePause() } label: {
                    Image(systemName: app.recState == .paused ? "play.fill" : "pause.fill")
                }
                .buttonStyle(PillButtonStyle(tone: .secondary))
                .help("暂停 / 继续（\(app.settings.combo(for: .pause).display)）")
                .disabled(app.recState == .finishing)
                Button { app.toggleRecording() } label: {
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 9, height: 9)
                        Text(app.recState == .finishing ? (app.recordingMergeProgress == nil ? "正在保存…" : "正在合并…") : "停止")
                    }
                }
                .buttonStyle(PillButtonStyle(tone: .danger))
                .disabled(app.recState == .finishing)
            }
        }
    }
}

// MARK: - Stage

struct StageView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 12) {
            PermissionBanner()
            PreviewStage(live: app.live)
            if app.workMode == .production {
                ProductionTimeline(session: app.production)
            }
            if app.deck != nil && app.slidesSource == .slides {
                SlideFilmstrip()
            }
            SceneStrip()
            SourceStrip()
        }
        .padding(16)
    }
}

struct PreviewStage: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var live: LiveStatus

    var body: some View {
        GeometryReader { geo in
            let size = app.settings.recording.outputSize
            let ratio = size.width / max(1, size.height)
            let w = min(geo.size.width, geo.size.height * ratio)
            let h = w / ratio
            ZStack {
                PreviewView(engine: app.engine)
                if app.settings.showGuides { GuidesOverlay() }
                if app.slidesOnScreen { SlideInteractionOverlay() }
                overlays(width: w)
                if !app.cameraEnabled && !app.production.isLoaded && app.scene == .camera {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash.fill").font(.system(size: 26))
                        Text("摄像头已关闭").font(.system(size: 16, weight: .semibold))
                        Text("录制实操请切换到「演示」或「讲解」镜头").font(.system(size: 12))
                    }
                    .foregroundStyle(Theme.text2)
                    .padding(20)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel.opacity(0.94)))
                    .allowsHitTesting(false)
                }
                if app.narrationImportPreviewPaused {
                    ZStack {
                        Theme.bg
                        VStack(spacing: 12) {
                            Image(systemName: "pause.circle").font(.system(size: 32))
                            Text("导入中，预览已暂停").font(.system(size: 17, weight: .semibold))
                            Text("暂时关闭摄像头与人像处理，将处理能力留给视频导入。\n导入结束或取消后自动恢复。")
                                .font(.system(size: 12)).multilineTextAlignment(.center)
                            ProgressView(value: app.narrationImportProgress ?? 0).frame(maxWidth: 260)
                            Text("\(Int((app.narrationImportProgress ?? 0) * 100))%")
                                .font(.system(size: 12, design: .monospaced))
                        }.foregroundStyle(Theme.text2).padding(24)
                    }
                }
                if case .countdown(let n) = app.recState {
                    ZStack {
                        Color.black.opacity(0.45)
                        Text("\(n)")
                            .font(.system(size: w * 0.14, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .shadow(radius: 20)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: w, height: h)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(app.recState == .recording ? Theme.red.opacity(0.85) : Theme.stroke, lineWidth: app.recState == .recording ? 2 : 1))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func overlays(width: CGFloat) -> some View {
        VStack {
            HStack(alignment: .top) {
                HStack(spacing: 6) {
                    Image(systemName: app.scene == .split && app.settings.recording.aspect == .portrait ? "rectangle.split.1x2.fill" : app.scene.symbol).font(.system(size: 10))
                    Text("\(app.scene.number) \(app.scene.title)").font(.system(size: 11, weight: .semibold))
                    if app.scene == .demo || (app.scene == .split && app.settings.split.content == .demo) {
                        Text("· \(app.shortSourceName(app.currentDemoSource))").font(.system(size: 11))
                    }
                    if app.zoomed { Image(systemName: "plus.magnifyingglass").font(.system(size: 10)) }
                    if app.pipHidden && app.scene.hasPIP { Image(systemName: "person.crop.circle.badge.xmark").font(.system(size: 10)) }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.black.opacity(0.5)))
                Spacer()
                if app.recState.isActive {
                    HStack(spacing: 5) {
                        Circle().fill(app.recState == .paused ? Theme.amber : Theme.red).frame(width: 7, height: 7)
                        Text(app.recState == .paused ? "已暂停" : "REC").font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                }
            }
            Spacer()
        }
        .padding(10)
        .allowsHitTesting(false)
    }
}

/// Mouse / trackpad handling over the preview while slides are shown:
/// drag = pan, mouse wheel / pinch / ⌘-scroll = zoom, two-finger scroll = pan, click left third = previous, else next.
final class SlideInteractionNSView: NSView {
    var onPan: ((CGVector) -> Void)?
    var onZoom: ((CGFloat, CGPoint) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onHover: ((Int) -> Void)?
    private var downAt: CGPoint?
    private var dragging = false
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                               owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    private func normalized(_ e: NSEvent) -> CGPoint {
        let p = convert(e.locationInWindow, from: nil)
        return CGPoint(x: p.x / max(1, bounds.width), y: p.y / max(1, bounds.height))
    }

    override func mouseDown(with e: NSEvent) {
        downAt = convert(e.locationInWindow, from: nil)
        dragging = false
    }

    override func mouseDragged(with e: NSEvent) {
        guard let start = downAt else { return }
        let p = convert(e.locationInWindow, from: nil)
        if !dragging {
            guard hypot(p.x - start.x, p.y - start.y) > 3 else { return }
            dragging = true
            NSCursor.closedHand.push()
        }
        onPan?(CGVector(dx: e.deltaX / max(1, bounds.width), dy: e.deltaY / max(1, bounds.height)))
    }

    override func mouseUp(with e: NSEvent) {
        if dragging {
            NSCursor.pop()
        } else if downAt != nil {
            onClick?(normalized(e))
        }
        downAt = nil
        dragging = false
    }

    override func scrollWheel(with e: NSEvent) {
        if e.hasPreciseScrollingDeltas && !e.modifierFlags.contains(.command) {
            onPan?(CGVector(dx: e.scrollingDeltaX / max(1, bounds.width), dy: e.scrollingDeltaY / max(1, bounds.height)))
        } else {
            let steps = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY * 0.012 : e.scrollingDeltaY * 0.15
            guard steps != 0 else { return }
            onZoom?(CGFloat(pow(2.0, Double(steps))), normalized(e))
        }
    }

    override func magnify(with e: NSEvent) {
        onZoom?(1 + e.magnification, normalized(e))
    }

    override func mouseMoved(with e: NSEvent) { onHover?(normalized(e).x < 0.33 ? -1 : 1) }
    override func mouseExited(with e: NSEvent) { onHover?(0) }
}

struct SlideInteractionArea: NSViewRepresentable {
    let app: AppState
    let hover: ViewState<Int>

    func makeNSView(context: Context) -> SlideInteractionNSView {
        let v = SlideInteractionNSView()
        configure(v)
        return v
    }

    func updateNSView(_ v: SlideInteractionNSView, context: Context) { configure(v) }

    private func configure(_ v: SlideInteractionNSView) {
        v.onPan = { [weak app] d in app?.slideView(.pan(d)) }
        v.onZoom = { [weak app] f, p in app?.slideView(.zoom(f, p)) }
        v.onClick = { [weak app] p in p.x < 0.33 ? app?.previousSlide() : app?.nextSlide() }
        v.onHover = { z in if hover.value != z { hover.value = z } }
    }
}

struct SlideInteractionOverlay: View {
    @EnvironmentObject var app: AppState
    @StateObject private var hover = ViewState(0)

    var body: some View {
        ZStack {
            SlideInteractionArea(app: app, hover: hover)
            HStack {
                chevron("chevron.left", visible: hover.value == -1)
                Spacer()
                chevron("chevron.right", visible: hover.value == 1)
            }
            .padding(16)
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    if hover.value != 0 {
                        Text("拖动平移 · 滚轮或双指捏合缩放 · 点左侧上一页、右侧下一页")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(Capsule().fill(Color.black.opacity(0.5)))
                            .allowsHitTesting(false)
                    }
                    Spacer()
                    if let z = app.slideZoom {
                        HStack(spacing: 6) {
                            Image(systemName: "plus.magnifyingglass").font(.system(size: 10))
                            Text("\(Int((z * 100).rounded()))%").font(.system(size: 11, weight: .semibold, design: .monospaced))
                            Button("复位") { app.slideView(.reset) }
                                .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                        }
                        .foregroundStyle(.white)
                        .padding(.leading, 10).padding(.trailing, 4).padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.55)))
                    }
                }
                .padding(10)
            }
        }
        .animation(.easeOut(duration: 0.15), value: hover.value)
    }

    private func chevron(_ name: String, visible: Bool) -> some View {
        Image(systemName: name)
            .font(.system(size: 18, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 40, height: 40)
            .background(Circle().fill(Color.black.opacity(0.45)))
            .opacity(visible ? 1 : 0)
    }
}

/// Thumbnails of every slide; click one to jump to it.
struct SlideFilmstrip: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if app.deckThumbnails.isEmpty {
                        ProgressView().controlSize(.small)
                        Text("正在生成缩略图…").font(.system(size: 11)).foregroundStyle(Theme.text3)
                    }
                    ForEach(Array(app.deckThumbnails.enumerated()), id: \.offset) { i, img in
                        Button { app.goToSlide(i) } label: {
                            Image(nsImage: img)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .frame(height: 52)
                                .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                                .overlay(alignment: .bottomLeading) {
                                    Text("\(i + 1)")
                                        .font(.system(size: 9, weight: .bold, design: .rounded))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 4).padding(.vertical, 1)
                                        .background(Capsule().fill(Color.black.opacity(0.55)))
                                        .padding(3)
                                }
                                .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                                    .stroke(i == app.slideIndex ? Theme.accentSoft : Theme.stroke, lineWidth: i == app.slideIndex ? 2 : 1))
                                .opacity(i == app.slideIndex ? 1 : 0.75)
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 3)
            }
            .onChange(of: app.slideIndex) { _, new in
                withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) }
            }
        }
        .frame(height: 60)
    }
}

struct GuidesOverlay: View {
    var body: some View {
        GeometryReader { g in
            Path { p in
                for i in 1...2 {
                    let x = g.size.width * CGFloat(i) / 3
                    let y = g.size.height * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: g.size.height))
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: g.size.width, y: y))
                }
            }
            .stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Scene strip

struct SceneStrip: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 10) {
            ForEach(SceneKind.allCases) { s in
                SceneCard(scene: s, active: app.scene == s, hotkey: app.settings.combo(for: action(for: s)).display,
                          portrait: app.settings.recording.aspect == .portrait,
                          cameraOnRight: app.settings.recording.aspect == .portrait
                              ? app.settings.split.portraitCameraAtBottom : app.settings.split.cameraOnRight) {
                    app.selectScene(s)
                }
            }
            VStack(spacing: 8) {
                ChipButton(title: app.pipHidden ? "小窗已隐藏" : "小窗人像", icon: app.pipHidden ? "person.crop.circle.badge.xmark" : "person.crop.circle",
                           active: !app.pipHidden, hint: app.settings.combo(for: .togglePIP).display) { app.togglePIP() }
                ChipButton(title: "跟随放大", icon: "plus.magnifyingglass", active: app.zoomed,
                           hint: app.settings.combo(for: .toggleZoom).display) { app.toggleZoom() }
            }
            .frame(width: 150)
            VStack(spacing: 8) {
                ChipButton(title: "人名条", icon: "person.text.rectangle", hint: app.settings.combo(for: .lowerThird).display) { app.showLowerThird() }
                ChipButton(title: "打点", icon: "flag", hint: app.settings.combo(for: .marker).display) { app.addMarker(.chapter) }
            }
            .frame(width: 130)
        }
        .frame(height: 98)
    }

    private func action(for s: SceneKind) -> HotkeyAction {
        switch s {
        case .camera: .sceneCamera
        case .slides: .sceneSlides
        case .demo: .sceneDemo
        case .split: .sceneSplit
        }
    }
}

struct SceneCard: View {
    let scene: SceneKind
    let active: Bool
    let hotkey: String
    var portrait = false
    var cameraOnRight = true
    let action: () -> Void
    @StateObject private var hover = ViewState(false)

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: scene == .split && portrait ? "rectangle.split.1x2.fill" : scene.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(active ? .white : Theme.accentSoft)
                    Spacer()
                    KeyHint(text: hotkey)
                }
                Spacer(minLength: 0)
                Text("\(scene.number)  \(scene.title)")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? .white : Theme.text)
                Text(scene == .split
                     ? (portrait ? (cameraOnRight ? "内容在上 · 人像在下" : "人像在上 · 内容在下")
                                 : (cameraOnRight ? "内容在左 · 人像在右" : "人像在左 · 内容在右"))
                     : scene.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(active ? Color.white.opacity(0.75) : Theme.text3)
                    .lineLimit(1)
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)], startPoint: .topLeading, endPoint: .bottomTrailing))
                          : AnyShapeStyle(hover.value ? Theme.cardHi : Theme.card))
            )
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(active ? Theme.accentSoft.opacity(0.8) : Theme.stroke, lineWidth: active ? 1.5 : 1))
            .shadow(color: active ? Theme.accent.opacity(0.35) : .clear, radius: 12, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.value = $0 }
        .animation(.easeOut(duration: 0.15), value: active)
    }
}

// MARK: - Source strip

/// Controls the content of the scene on screen: the 讲解 content (file / display / window) while the slides are
/// showing, otherwise the demo screen and its position.
struct SourceStrip: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 8) {
            if app.stripShowsSlides { slidesStrip } else { demoStrip }
            Spacer()
            if let deck = app.deck, app.slidesSource == .slides {
                HStack(spacing: 6) {
                    Button { app.previousSlide() } label: { Image(systemName: "chevron.left") }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    Text("幻灯片 \(app.slideIndex + 1) / \(deck.pageCount)")
                        .font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text2)
                    Button { app.nextSlide() } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    KeyHint(text: "\(app.settings.combo(for: .slidePrev).display) \(app.settings.combo(for: .slideNext).display)")
                }
            }
        }
        .frame(height: 32)
    }

    // MARK: 讲解

    @ViewBuilder private var slidesStrip: some View {
        Label("讲解画面", systemImage: "rectangle.inset.bottomleft.filled")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text2)
        if let deck = app.deck {
            ChipButton(title: shortTitle(deck.title), icon: "doc.richtext", active: app.slidesSource == .slides) {
                app.selectSlidesSource(.slides)
            }
            .help("导入的文件：\(deck.title)（\(deck.pageCount) 页）")
            Button { app.importDeck() } label: { Image(systemName: "square.and.arrow.down") }
                .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                .disabled(app.deckConverting)
                .help("更换文件（PPT / PPTX / Keynote / PDF）")
        } else if app.deckConverting {
            ProgressView().controlSize(.small)
            Text("正在转换文件…").font(.system(size: 12)).foregroundStyle(Theme.text2)
        } else {
            ChipButton(title: "导入文件…", icon: "square.and.arrow.down", active: false) { app.importDeck() }
                .help("导入 PPT / PPTX / Keynote / PDF 作为讲解内容")
        }
        if app.displays.isEmpty {
            Text(app.screenPermission ? "正在读取屏幕…" : "需要录屏权限")
                .font(.system(size: 12)).foregroundStyle(Theme.amber)
        }
        ForEach(app.displays) { d in
            ChipButton(title: app.shortSourceName(d.ref), icon: "display", active: app.slidesSource == d.ref) {
                app.selectSlidesSource(d.ref)
            }
            .help(d.name)
        }
        windowMenu
        if app.slidesChoices.count > 1 {
            KeyHint(text: app.settings.combo(for: .nextSource).display)
            Text("切换").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 18).padding(.horizontal, 2)
        Text("适配").font(.system(size: 11)).foregroundStyle(Theme.text3)
        fitButton("铺满", .fill, help: "铺满画面；可以在预览里拖动、滚轮缩放")
        fitButton("完整", .fit, help: "完整显示整页")
    }

    /// A chip-styled menu with every capturable window; the chosen window shows as the chip's title.
    private var windowMenu: some View {
        let selected = app.windows.first { $0.ref == app.slidesSource }
        let onScreen = app.windows.filter(\.onScreen)
        let background = app.windows.filter { !$0.onScreen }
        return Menu {
            if app.windows.isEmpty {
                Text("没有可捕捉的应用窗口")
            }
            if !onScreen.isEmpty {
                Section("当前桌面上的窗口") {
                    ForEach(onScreen) { w in windowItem(w) }
                }
            }
            if !background.isEmpty {
                Section("后台窗口（其他桌面 / 已最小化 / 已隐藏）") {
                    ForEach(background) { w in windowItem(w) }
                }
            }
            Divider()
            Button { app.refreshSources() } label: { Label("刷新列表", systemImage: "arrow.clockwise") }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "macwindow").font(.system(size: 11, weight: .semibold))
                Text(selected.map { app.shortSourceName($0.ref) } ?? "应用窗口")
                    .font(.system(size: 12, weight: .medium)).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(selected != nil ? Color.white : Theme.text2)
            .background(Capsule().fill(selected != nil ? Theme.accent.opacity(0.85) : Theme.card))
            .overlay(Capsule().stroke(selected != nil ? Theme.accentSoft.opacity(0.6) : Theme.stroke))
            .contentShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { if $0 { app.scheduleSourceRefresh(after: 0) } }
        .help("用某个应用的窗口作为讲解画面，例如正在放映的 PPT。其他桌面上的窗口也能选；已最小化的窗口要恢复后画面才会更新")
    }

    private func windowItem(_ w: CaptureSourceInfo) -> some View {
        Button { app.selectSlidesSource(w.ref) } label: {
            if w.ref == app.slidesSource { Label(w.name, systemImage: "checkmark") } else { Text(w.name) }
        }
    }

    private func fitButton(_ title: String, _ value: SlidesFit, help: String) -> some View {
        let portrait = app.settings.recording.aspect == .portrait
        let active = (portrait ? app.settings.slides.portraitFit : app.settings.slides.fit) == value
        return Button {
            if portrait { app.settings.slides.portraitFit = value } else { app.settings.slides.fit = value }
        } label: {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.text2)
                .frame(height: 24)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.accent.opacity(0.85) : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func shortTitle(_ s: String) -> String {
        s.count > 14 ? String(s.prefix(13)) + "…" : s
    }

    // MARK: 演示

    @ViewBuilder private var demoStrip: some View {
        Label("演示画面", systemImage: "display.2")
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.text2)
        if app.demoSources.isEmpty {
            Text(app.screenPermission ? "正在读取屏幕…" : "需要录屏权限")
                .font(.system(size: 12)).foregroundStyle(Theme.amber)
        }
        ForEach(Array(app.demoSources.enumerated()), id: \.element) { i, ref in
            ChipButton(title: app.shortSourceName(ref), icon: iconFor(ref), active: i == app.demoIndex) {
                app.selectDemoSource(i)
            }
            .help(app.sourceName(ref))
        }
        if app.demoSources.count > 1 {
            KeyHint(text: app.settings.combo(for: .nextSource).display)
            Text("切换").font(.system(size: 11)).foregroundStyle(Theme.text3)
        }
        Rectangle().fill(Theme.stroke).frame(width: 1, height: 18).padding(.horizontal, 2)
        Text("位置").font(.system(size: 11)).foregroundStyle(Theme.text3)
        alignButton("arrow.left.to.line", -1, help: "演示画面靠左")
        alignButton("align.horizontal.center", 0, help: "演示画面居中")
        alignButton("arrow.right.to.line", 1, help: "演示画面靠右（给左下角人像让位）")
    }

    private func alignButton(_ icon: String, _ value: Double, help: String) -> some View {
        let active = abs(app.settings.demo.contentAlign - value) < 0.02
        return Button { app.settings.demo.contentAlign = value } label: {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(active ? Color.white : Theme.text2)
                .frame(width: 26, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(active ? Theme.accent.opacity(0.85) : Theme.card))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.stroke))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func iconFor(_ ref: SourceRef) -> String {
        switch ref {
        case .display: "display"
        case .window: "macwindow"
        case .slides: "rectangle.on.rectangle"
        }
    }
}

// MARK: - Banners & toasts

struct PermissionBanner: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 8) {
            if !app.screenPermission || (app.screenError != nil && app.displays.isEmpty) {
                banner(icon: "rectangle.dashed.badge.record",
                       text: app.screenError ?? "需要「录屏与系统录音」权限才能捕捉屏幕。授权后请重启本应用。") {
                    Button("授权") { Permissions.requestScreen(); app.refreshSources() }
                        .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    Button("打开系统设置") { Permissions.openSettings(.screen) }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    Button("重新检测") { app.refreshSources() }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    Button("重启应用") { app.flushSave(); Permissions.relaunch() }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                }
            }
            if let err = app.cameraStatus.error {
                banner(icon: "video.slash", text: err) {
                    Button("打开系统设置") { Permissions.openSettings(.camera) }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                }
            }
            if let err = app.micError {
                banner(icon: "mic.slash", text: err) {
                    Button("打开系统设置") { Permissions.openSettings(.microphone) }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                }
            }
        }
    }

    private func banner<B: View>(icon: String, text: String, @ViewBuilder buttons: () -> B) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Theme.amber)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(2)
            Spacer()
            buttons()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.amber.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.amber.opacity(0.35)))
    }
}

struct ToastView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ZStack {
            if let t = app.toast {
                HStack(spacing: 8) {
                    Image(systemName: t.icon).foregroundStyle(Theme.accentSoft)
                    Text(t.text).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.78)))
                .overlay(Capsule().stroke(Color.white.opacity(0.12)))
                .transition(.move(edge: .top).combined(with: .opacity))
                .id(t.id)
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.85), value: app.toast)
        .allowsHitTesting(false)
    }
}
