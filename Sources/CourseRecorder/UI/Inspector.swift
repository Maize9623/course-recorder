import SwiftUI
import AppKit
import AVFoundation

enum InspectorTab: String, CaseIterable, Identifiable {
    case scenes, camera, sources, audio, overlay, prompter, record, production, hotkeys
    var id: String { rawValue }

    var title: String {
        switch self {
        case .scenes: "镜头"
        case .camera: "人像"
        case .sources: "画面源"
        case .audio: "音频"
        case .overlay: "叠加"
        case .prompter: "提词"
        case .record: "录制"
        case .production: "制作"
        case .hotkeys: "快捷键"
        }
    }

    var icon: String {
        switch self {
        case .scenes: "square.stack.3d.down.forward"
        case .camera: "person.crop.square"
        case .sources: "display.2"
        case .audio: "waveform"
        case .overlay: "square.3.layers.3d.down.right"
        case .prompter: "text.justify.left"
        case .record: "record.circle"
        case .production: "film.stack"
        case .hotkeys: "command"
        }
    }
}

struct InspectorView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let tab = app.inspectorTab
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(InspectorTab.allCases) { t in
                    Button { app.inspectorTab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 13, weight: .medium))
                            Text(t.title).font(.system(size: 10))
                        }
                        .foregroundStyle(tab == t ? Color.white : Theme.text3)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 8).fill(tab == t ? Theme.accent.opacity(0.85) : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(8)
            Rectangle().fill(Theme.stroke).frame(height: 1)
            ScrollView {
                VStack(spacing: 12) {
                    switch tab {
                    case .scenes: ScenesTab()
                    case .camera: CameraTab()
                    case .sources: SourcesTab()
                    case .audio: AudioTab(live: app.live)
                    case .overlay: OverlayTab()
                    case .prompter: PrompterTab()
                    case .record: RecordTab()
                    case .production: ProductionTab(session: app.production)
                    case .hotkeys: HotkeysTab()
                    }
                }
                .padding(14)
            }
        }
        .background(Theme.panel)
    }
}

// MARK: - Scenes

struct ScenesTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SectionCard(title: "转场动画", icon: "wand.and.stars",
                    note: "出镜 ↔ 小窗会自动「缩放变形」：人像平滑缩进左下角或放大回全屏；屏幕/幻灯片切换按下方样式。") {
            SliderRow(title: "镜头切换时长", value: $app.settings.transitions.sceneDuration, range: 0...1.5) { String(format: "%.2f 秒", $0) }
            LabeledRow(title: "屏幕切换样式") {
                Picker("", selection: $app.settings.transitions.sourceStyle) {
                    ForEach(TransitionStyle.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 140)
            }
            SliderRow(title: "屏幕切换时长", value: $app.settings.transitions.sourceDuration, range: 0.2...1.2) { String(format: "%.2f 秒", $0) }
            SliderRow(title: "小窗显隐时长", value: $app.settings.transitions.pipDuration, range: 0.15...0.8) { String(format: "%.2f 秒", $0) }
            SliderRow(title: "幻灯片翻页时长", value: $app.settings.transitions.slideDuration, range: 0...0.8) { String(format: "%.2f 秒", $0) }
        }

        SectionCard(title: "2 讲解 · 内容", icon: "rectangle.inset.bottomleft.filled",
                    note: "可以直接导入 PPT / PPTX / Keynote / PDF，用快捷键或翻页笔翻页（PPT 会自动转成幻灯片，里面的动画不保留）。需要 PPT 动画时，选择捕捉正在放映 PPT 的屏幕或窗口即可。") {
            LabeledRow(title: "讲解内容") {
                Picker("", selection: slidesSourceBinding) {
                    Text("自动").tag("auto")
                    if app.deck != nil { Text("导入的幻灯片").tag(SourceRef.slides.key) }
                    ForEach(app.displays) { Text($0.name).tag($0.ref.key) }
                    ForEach(app.windows) { Text($0.onScreen ? $0.name : "\($0.name)（后台）").tag($0.ref.key) }
                }
                .labelsHidden().frame(width: 190)
            }
            HStack(spacing: 8) {
                Button { app.importDeck() } label: { Label("导入 PPT / PDF", systemImage: "square.and.arrow.down") }
                    .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    .disabled(app.deckConverting)
                if app.deckConverting {
                    ProgressView().controlSize(.small)
                    Text("正在转换…").font(.system(size: 11)).foregroundStyle(Theme.text2)
                } else if let deck = app.deck {
                    Text("\(deck.title) · \(deck.pageCount) 页").font(.system(size: 11)).foregroundStyle(Theme.text2)
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { app.reloadDeck() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                        .help("PPT 修改后点这里重新载入")
                    Button { app.settings.slides.deckPath = ""; if app.settings.slides.source == .slides { app.settings.slides.source = nil } } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                }
            }
            LabeledRow(title: "画面适配") {
                Picker("", selection: slidesFitBinding) {
                    ForEach(SlidesFit.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            if isPortrait {
                Text("竖屏默认完整显示课件，上下空余区域显示背景；铺满时可在预览中拖动与缩放。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            ToggleRow(title: "讲解时用 ← → 方向键翻页",
                      subtitle: "画面上是导入的幻灯片时，← → 在任何应用里都用来翻页，切到其他镜头立即恢复正常。本工具窗口在前台时，空格和 ↑ ↓ 也能翻页",
                      isOn: $app.settings.slides.arrowKeys)
            ToggleRow(title: "翻页笔 / PageUp PageDown 全局翻页",
                      subtitle: "接翻页笔时打开；MacBook 键盘上 fn + ↑ / fn + ↓ 就是 PageUp / PageDown",
                      isOn: $app.settings.slides.clickerKeys)
        }

        SectionCard(title: "3 演示 · 屏幕实操", icon: "macwindow.on.rectangle") {
            if isPortrait {
                LabeledRow(title: "竖屏取景") {
                    Picker("", selection: $app.settings.demo.portraitFraming) {
                        ForEach(PortraitDemoFraming.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
                Text(app.settings.demo.portraitFraming == .leftHalf
                     ? "演示镜头及分屏内的演示内容只显示屏幕或窗口的左半边。将要演示的内容放到左侧，小窗默认位于左下角。"
                     : "演示镜头及分屏内的演示内容完整保留整个屏幕或窗口，空余区域用所选背景填充。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("背景").font(.system(size: 12)).foregroundStyle(Theme.text2)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                ForEach(AssetCatalog.demoBackdrops) { p in
                    SwatchItem(title: p.name, image: app.thumbnails["demo:\(p.id)"], colors: p.colors.map(\.color),
                               selected: app.settings.demo.backdrop == p.id) { app.settings.demo.backdrop = p.id }
                }
                SwatchItem(title: "自定义…", image: app.thumbnails["demo:custom"], colors: [Theme.card, Theme.cardHi],
                           selected: app.settings.demo.backdrop == "custom") {
                    if app.settings.demo.customBackdropPath.isEmpty { app.chooseDemoBackdrop() } else { app.settings.demo.backdrop = "custom" }
                }
            }
            if app.settings.demo.backdrop == "custom" {
                Button("更换背景图…") { app.chooseDemoBackdrop() }.buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
            }
            SliderRow(title: "画面水平位置", value: $app.settings.demo.contentAlign, range: -1...1) { v in
                abs(v) < 0.02 ? "居中" : (v < 0 ? String(format: "偏左 %.0f%%", -v * 100) : String(format: "偏右 %.0f%%", v * 100))
            }
            HStack(spacing: 6) {
                ChipButton(title: "靠左", icon: "arrow.left.to.line", active: app.settings.demo.contentAlign <= -0.98) { app.settings.demo.contentAlign = -1 }
                ChipButton(title: "居中", icon: "align.horizontal.center", active: abs(app.settings.demo.contentAlign) < 0.02) { app.settings.demo.contentAlign = 0 }
                ChipButton(title: "靠右", icon: "arrow.right.to.line", active: app.settings.demo.contentAlign >= 0.98) { app.settings.demo.contentAlign = 1 }
            }
            if !isPortrait {
                ToggleRow(title: "小窗出现时画面自动让开", subtitle: "人像小窗显示时录屏画面自动挪开不被挡住，收起小窗后回到原位（画面两侧有空余时生效）",
                          isOn: $app.settings.demo.avoidPIP)
            }
            SliderRow(title: "画面边距", value: $app.settings.demo.padding, range: 0...0.12) { String(format: "%.0f%%", $0 * 100) }
            SliderRow(title: "圆角", value: $app.settings.demo.cornerRadius, range: 0...0.03) { String(format: "%.0f px", $0 * Double(app.settings.recording.outputSize.width)) }
            ToggleRow(title: "画面阴影", isOn: $app.settings.demo.shadow)
            ToggleRow(title: "录入鼠标指针", isOn: $app.settings.demo.showCursor)
            ToggleRow(title: "鼠标点击高亮", subtitle: "点击处出现一圈涟漪，观众更容易跟上操作", isOn: $app.settings.demo.clickHighlight)
            SliderRow(title: "跟随放大倍数", value: $app.settings.demo.zoomFactor, range: 1.3...3) { String(format: "%.1f×", $0) }
            LabeledRow(title: "放大方式") {
                Picker("", selection: $app.settings.demo.zoomMode) {
                    ForEach(ZoomMode.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 150)
            }
            if app.settings.demo.zoomMode == .autoOnClick {
                SliderRow(title: "无点击后自动缩回", value: $app.settings.demo.autoZoomHold, range: 1...8) { String(format: "%.1f 秒", $0) }
            }
            ToggleRow(title: "后台画面降帧节能", subtitle: "未显示的屏幕以 12fps 采集，切换时立即恢复满帧", isOn: $app.settings.demo.throttleInactive)
        }

        SectionCard(title: isPortrait ? "4 分屏 · 上下布局" : "4 分屏 · 内容 + 人像",
                    icon: isPortrait ? "rectangle.split.1x2.fill" : "rectangle.split.2x1.fill") {
            LabeledRow(title: "内容来源") {
                Picker("", selection: $app.settings.split.content) {
                    ForEach(SplitContent.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            LabeledRow(title: "人像在") {
                Picker("", selection: splitPositionBinding) {
                    Text(isPortrait ? "上方" : "左边").tag(false)
                    Text(isPortrait ? "下方" : "右边").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 120)
            }
            SliderRow(title: isPortrait ? "人像格子高度" : "人像格子宽度", value: splitSizeBinding,
                      range: isPortrait ? 0.18...0.4 : 0.28...0.55) { String(format: "%.0f%%", $0 * 100) }
            if isPortrait {
                Text("默认操作内容在主区域居中，人像在底部占 25%；以操作画面为主。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            SliderRow(title: "人像左右微调", value: $app.settings.split.personOffset, range: -0.25...0.25) { String(format: "%+.2f", $0) }
            SliderRow(title: "人像缩放", value: $app.settings.split.personZoom, range: 1...1.6) { String(format: "%.2f×", $0) }
            ToggleRow(title: "内容完整显示", subtitle: isPortrait ? "关闭后内容裁切铺满自己的格子；竖屏始终上下分屏" : "关闭后内容铺满整个画面、人像叠在内容上（适合一侧留白的课件）",
                      isOn: $app.settings.split.fitContent)
            if app.settings.split.fitContent {
                ToggleRow(title: "人像做成圆角卡片", subtitle: isPortrait ? "上下都是独立的格子，边界最清楚" : "两边都是独立的格子，边界最清楚", isOn: $app.settings.split.cardStyle)
            }
            if !isPortrait && !(app.settings.split.fitContent && app.settings.split.cardStyle) {
                SliderRow(title: "人像边缘柔化", value: $app.settings.split.edgeSoftness, range: 0...0.15) { String(format: "%.0f%%", $0 * 100) }
            }
            ToggleRow(title: "抠像人物（去掉背景）", isOn: $app.settings.split.cutout)
        }
    }

    private var isPortrait: Bool { app.settings.recording.aspect == .portrait }

    private var splitPositionBinding: Binding<Bool> {
        Binding(get: { isPortrait ? app.settings.split.portraitCameraAtBottom : app.settings.split.cameraOnRight },
                set: { if isPortrait { app.settings.split.portraitCameraAtBottom = $0 } else { app.settings.split.cameraOnRight = $0 } })
    }

    private var splitSizeBinding: Binding<Double> {
        Binding(get: { isPortrait ? app.settings.split.portraitPersonHeight : app.settings.split.personWidth },
                set: { if isPortrait { app.settings.split.portraitPersonHeight = $0 } else { app.settings.split.personWidth = $0 } })
    }

    private var slidesFitBinding: Binding<SlidesFit> {
        Binding(get: { isPortrait ? app.settings.slides.portraitFit : app.settings.slides.fit },
                set: { if isPortrait { app.settings.slides.portraitFit = $0 } else { app.settings.slides.fit = $0 } })
    }

    private var slidesSourceBinding: Binding<String> {
        Binding(get: { app.settings.slides.source?.key ?? "auto" },
                set: { app.settings.slides.source = $0 == "auto" ? nil : SourceRef(key: $0) })
    }
}

// MARK: - Camera

/// Live camera processing load, so the effect of beauty / matte quality on frame rate is visible.
struct CameraLoadView: View {
    @ObservedObject var live: LiveStatus

    var body: some View {
        let budget = live.cameraFPS > 40 ? 16.7 : 33.3
        let ok = live.cameraMs < budget * 0.9
        HStack(spacing: 6) {
            Circle().fill(ok ? Theme.green : Theme.amber).frame(width: 6, height: 6)
            Text(String(format: "实时 %.0f fps · 人像处理 %.0f ms/帧", live.cameraFPS, live.cameraMs))
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.text2)
            if !ok {
                Text("偏慢：可降低抠像精度或关掉瘦脸/大眼").font(.system(size: 10.5)).foregroundStyle(Theme.amber)
            }
        }
    }
}

struct CameraTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SectionCard(title: "摄像头", icon: "video") {
            LabeledRow(title: "设备") {
                Picker("", selection: $app.settings.camera.deviceID) {
                    Text("系统默认").tag("")
                    ForEach(app.cameras) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 200)
            }
            LabeledRow(title: "摄像头帧率") {
                Picker("", selection: $app.settings.camera.frameRate) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 110)
            }
            Text("推荐 30：人像稳定流畅，输出画面仍是 60 帧。60 需要更多算力，开美颜和精细抠像时可能跟不上。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            if app.cameraStatus.running {
                Text("\(app.cameraStatus.deviceName) · \(app.cameraStatus.format)").font(.system(size: 11)).foregroundStyle(Theme.text3)
                CameraLoadView(live: app.live)
            }
            ToggleRow(title: "镜像画面", subtitle: "默认不镜像，衣服和白板上的字是正的", isOn: $app.settings.camera.mirror)
            ToggleRow(title: "人脸居中追踪", subtitle: "出镜、小窗和分屏共用，平滑跟随人脸；竖屏或放大后可随左右移动调整构图", isOn: $app.settings.camera.faceTracking)
            Button {
                AVCaptureDevice.showSystemUserInterface(.videoEffects)
            } label: { Label("系统视频效果（人物居中 / 人像模式 / 影棚光效）", systemImage: "sparkles") }
                .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
        }

        SectionCard(title: "虚拟背景", icon: "photo.on.rectangle.angled",
                    note: "基于 Apple Vision 实时抠像，不需要绿幕。也可以导入你用 AI 生成的演播室背景图。") {
            Picker("", selection: $app.settings.background.mode) {
                ForEach(BackgroundMode.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()

            switch app.settings.background.mode {
            case .image:
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(AssetCatalog.cameraBackgrounds) { p in
                        SwatchItem(title: p.name, image: app.thumbnails["cam:\(p.id)"], colors: p.colors.map(\.color),
                                   selected: app.settings.background.preset == p.id) { app.settings.background.preset = p.id }
                    }
                    SwatchItem(title: "自定义图片…", image: app.thumbnails["cam:custom"], colors: [Theme.card, Theme.cardHi],
                               selected: app.settings.background.preset == "custom") {
                        if app.settings.background.customImagePath.isEmpty { app.chooseCameraBackground() } else { app.settings.background.preset = "custom" }
                    }
                }
                if app.settings.background.preset == "custom" {
                    Button("更换图片…") { app.chooseCameraBackground() }.buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                }
                SliderRow(title: "背景景深（虚化）", value: $app.settings.background.imageDefocus, range: 0...12) { String(format: "%.1f", $0) }
            case .blur:
                SliderRow(title: "虚化强度", value: $app.settings.background.blurAmount, range: 4...60) { String(format: "%.0f", $0) }
            case .color:
                LabeledRow(title: "背景颜色") {
                    ColorPicker("", selection: colorBinding($app.settings.background.color), supportsOpacity: false).labelsHidden()
                    Button("绿幕") { app.settings.background.color = .chroma }.buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                }
            case .off:
                EmptyView()
            }
            if app.settings.background.mode != .off {
                LabeledRow(title: "抠像精度") {
                    Picker("", selection: $app.settings.background.quality) {
                        ForEach(SegmentationQuality.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 170)
                }
                Text("「精细」边缘最干净，适合坐着讲课；动作很多时用「均衡」更跟手。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                ToggleRow(title: "填补漏洞", subtitle: "修补深色衣服、手臂和身体之间被误抠掉的小块", isOn: $app.settings.background.fillHoles)
                SliderRow(title: "抠像干净度", value: $app.settings.background.matteClean, range: 0...1) { String(format: "%.0f%%", $0 * 100) }
                SliderRow(title: "边缘收紧", value: $app.settings.background.edgeTighten, range: -2...4) { String(format: "%+.1f", $0) }
                SliderRow(title: "边缘柔化", value: $app.settings.background.edgeSmoothing, range: 0...4) { String(format: "%.1f", $0) }
                Button("抠像参数恢复默认") {
                    let d = BackgroundSettings()
                    app.settings.background.fillHoles = d.fillHoles
                    app.settings.background.matteClean = d.matteClean
                    app.settings.background.edgeTighten = d.edgeTighten
                    app.settings.background.edgeSmoothing = d.edgeSmoothing
                }
                .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
            }
        }

        SectionCard(title: "美颜", icon: "sparkles",
                    note: "磨皮、美白、红润只作用在皮肤上，五官、头发和衣服保持清晰；瘦脸、大眼会实时识别脸型。") {
            ToggleRow(title: "开启美颜", isOn: $app.settings.beauty.enabled)
            if app.settings.beauty.enabled {
                SliderRow(title: "磨皮", value: $app.settings.beauty.smooth, range: 0...1) { String(format: "%.0f", $0 * 100) }
                SliderRow(title: "美白", value: $app.settings.beauty.whiten, range: 0...1) { String(format: "%.0f", $0 * 100) }
                SliderRow(title: "红润", value: $app.settings.beauty.rosy, range: 0...1) { String(format: "%.0f", $0 * 100) }
                SliderRow(title: "瘦脸", value: $app.settings.beauty.slim, range: 0...1) { String(format: "%.0f", $0 * 100) }
                SliderRow(title: "大眼", value: $app.settings.beauty.eyes, range: 0...1) { String(format: "%.0f", $0 * 100) }
                SliderRow(title: "清晰度", value: $app.settings.beauty.clarity, range: 0...1) { String(format: "%.0f", $0 * 100) }
                HStack(spacing: 8) {
                    Button("自然") {
                        app.settings.beauty = BeautySettings()
                    }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    Button("精致") {
                        app.settings.beauty = BeautySettings(enabled: true, smooth: 0.6, whiten: 0.45, rosy: 0.25, slim: 0.35, eyes: 0.25, clarity: 0.3)
                    }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    Button("全部归零") {
                        app.settings.beauty = BeautySettings(enabled: true, smooth: 0, whiten: 0, rosy: 0, slim: 0, eyes: 0, clarity: 0)
                    }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                }
            }
        }

        SectionCard(title: "画面调节", icon: "camera.filters") {
            SliderRow(title: "亮度", value: $app.settings.camera.brightness, range: -0.25...0.25) { String(format: "%+.2f", $0) }
            SliderRow(title: "对比度", value: $app.settings.camera.contrast, range: 0.7...1.4) { String(format: "%.2f", $0) }
            SliderRow(title: "饱和度", value: $app.settings.camera.saturation, range: 0...1.8) { String(format: "%.2f", $0) }
            SliderRow(title: "色温（暖 ←→ 冷）", value: $app.settings.camera.warmth, range: -1...1) { String(format: "%+.2f", $0) }
            Button("恢复默认") {
                app.settings.camera.brightness = 0
                app.settings.camera.contrast = 1
                app.settings.camera.saturation = 1
                app.settings.camera.warmth = 0
            }
            .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
        }

        SectionCard(title: "1 出镜 · 构图", icon: "person.crop.rectangle",
                    note: "开启人脸居中追踪后自动调整水平构图，位置滑块用于跟随后的微调。横屏完整画幅的移动空间有限，可适当放大。") {
            SliderRow(title: "画面缩放", value: $app.settings.camera.fullZoom, range: 1...1.8) { String(format: "%.2f×", $0) }
            SliderRow(title: "水平位置", value: $app.settings.camera.fullOffsetX, range: -0.3...0.3) { String(format: "%+.2f", $0) }
            SliderRow(title: "垂直位置", value: $app.settings.camera.fullOffsetY, range: -0.3...0.3) { String(format: "%+.2f", $0) }
        }

        SectionCard(title: "小窗人像（讲解 / 演示）", icon: "person.crop.circle") {
            Picker("", selection: $app.settings.pip.shape) {
                ForEach(PIPShape.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            LabeledRow(title: "位置") {
                Picker("", selection: $app.settings.pip.corner) {
                    ForEach(Corner.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            SliderRow(title: "大小", value: $app.settings.pip.size, range: 0.12...0.32) { String(format: "%.0f%%", $0 * 100) }
            SliderRow(title: "边距", value: $app.settings.pip.margin, range: 0...0.06) { String(format: "%.1f%%", $0 * 100) }
            SliderRow(title: "人像放大", value: $app.settings.pip.zoom, range: 1...2) { String(format: "%.2f×", $0) }
            if app.settings.pip.shape != .cutout {
                SliderRow(title: "描边粗细", value: $app.settings.pip.borderWidth, range: 0...10) { String(format: "%.0f px", $0) }
                LabeledRow(title: "描边颜色") {
                    ColorPicker("", selection: colorBinding($app.settings.pip.borderColor), supportsOpacity: true).labelsHidden()
                }
                ToggleRow(title: "投影", isOn: $app.settings.pip.shadow)
            }
        }
    }
}
