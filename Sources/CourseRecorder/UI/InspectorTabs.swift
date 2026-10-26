import SwiftUI
import AppKit

// MARK: - Sources

struct SourcesTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SectionCard(title: "屏幕录制权限", icon: "lock.shield") {
            HStack(spacing: 8) {
                Image(systemName: app.screenPermission ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(app.screenPermission ? Theme.green : Theme.amber)
                Text(app.screenPermission ? "已授权，可以捕捉屏幕与窗口" : "未授权：点「授权」后在系统设置中打开开关，再重启应用")
                    .font(.system(size: 12)).foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !app.screenPermission {
                    Button("授权") { Permissions.requestScreen() }.buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    Button("重启应用") { app.flushSave(); Permissions.relaunch() }.buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                }
                Button { app.refreshSources() } label: { Label("刷新屏幕和窗口列表", systemImage: "arrow.clockwise") }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
            }
        }

        SectionCard(title: "演示切换列表", icon: "rectangle.2.swap",
                    note: "勾选要在「3 演示」里切换的画面，按 \(app.settings.combo(for: .nextSource).display) 依次切换。两块屏幕时：一块放 AI 操作界面，一块放生成结果。本工具自己的窗口永远不会被录进去。") {
            ForEach(app.displays) { info in
                SourceRow(info: info)
            }
            if app.displays.isEmpty {
                Text("没有读取到显示器").font(.system(size: 12)).foregroundStyle(Theme.amber)
            }
        }

        SectionCard(title: "单独捕捉窗口", icon: "macwindow",
                    note: "只录某个 App 的窗口：即使它被别的窗口挡住也能录到，桌面杂物和通知都不会入镜。其他桌面上的窗口也会列出（标注「后台」）；已最小化的窗口要恢复后画面才会更新。列表会在切换应用时自动刷新。") {
            if app.windows.isEmpty {
                Text("没有可捕捉的窗口").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            ForEach(app.windows.prefix(30)) { info in
                SourceRow(info: info)
            }
        }
    }
}

struct SourceRow: View {
    @EnvironmentObject var app: AppState
    let info: CaptureSourceInfo

    var body: some View {
        let included = app.isDemoSource(info.ref)
        HStack(spacing: 8) {
            Image(systemName: info.ref.key.hasPrefix("display") ? "display" : "macwindow")
                .foregroundStyle(included ? Theme.accentSoft : Theme.text3)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(info.name).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                Text(info.detail).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            Spacer()
            if included {
                Button { app.moveDemoSource(info.ref, by: -1) } label: { Image(systemName: "chevron.up") }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                Button { app.moveDemoSource(info.ref, by: 1) } label: { Image(systemName: "chevron.down") }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
            }
            Toggle("", isOn: Binding(get: { included }, set: { app.toggleDemoSource(info.ref, included: $0) }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden().tint(Theme.accent)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Audio

struct AudioTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var live: LiveStatus

    var body: some View {
        SectionCard(title: "麦克风", icon: "mic") {
            LabeledRow(title: "设备") {
                Picker("", selection: $app.settings.audio.micDeviceID) {
                    Text("系统默认").tag("")
                    ForEach(app.mics) { Text($0.name).tag($0.id) }
                }
                .labelsHidden().frame(width: 200)
            }
            Label(app.micName.isEmpty ? "尚未打开麦克风" : "当前实际输入：\(app.micName)", systemImage: "waveform")
                .font(.system(size: 11)).foregroundStyle(app.micError == nil ? Theme.text2 : Theme.amber)
                .textSelection(.enabled)
            if let error = app.micError {
                Text(error).font(.system(size: 10.5)).foregroundStyle(Theme.red)
            }
            if let selected = app.mics.first(where: { $0.id == app.settings.audio.micDeviceID }),
               !app.micName.isEmpty, selected.name != app.micName {
                Text("所选设备与当前输入不同，请确认设备已连接，录制前重新选择并试音。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.amber)
            }
            if !app.settings.audio.micDeviceID.isEmpty,
               !app.mics.contains(where: { $0.id == app.settings.audio.micDeviceID }) {
                Text("所选麦克风当前未连接。请接回设备，或重新选择后试音。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.amber)
            }
            Text("要固定使用外接麦克风，请在上方选它的名称。选择「系统默认」会使用 Mac 的默认输入。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            HStack(spacing: 8) {
                Image(systemName: app.micMuted ? "mic.slash.fill" : "mic.fill")
                    .foregroundStyle(app.micMuted ? Theme.red : Theme.green)
                LevelMeter(db: app.micMuted ? -120 : live.micDB, height: 8)
                Text(String(format: "%.0f dB", live.micDB)).font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.text3)
                    .frame(width: 44, alignment: .trailing)
            }
            Text("说话时电平在黄绿交界附近最合适；爆红会自动限幅。").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            if app.micName.localizedCaseInsensitiveContains("beats") || app.micName.localizedCaseInsensitiveContains("airpods")
                || app.micName.contains("耳机") {
                Label("蓝牙耳机的麦克风音质较差，还会让耳机播放变成电话音质。建议选 MacBook 麦克风或外接麦克风。", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SliderRow(title: "增益", value: $app.settings.audio.micGainDB, range: -12...24) { String(format: "%+.0f dB", $0) }
            ToggleRow(title: "低频滤除", subtitle: "去掉空调、桌面震动的嗡嗡声", isOn: $app.settings.audio.highPass)
            ToggleRow(title: "环境噪声抑制", subtitle: "不说话时压低底噪", isOn: $app.settings.audio.noiseGate)
            if app.settings.audio.noiseGate {
                SliderRow(title: "噪声门限", value: $app.settings.audio.gateThresholdDB, range: -70 ... -30) { String(format: "%.0f dB", $0) }
            }
            ToggleRow(title: "防爆音限幅", isOn: $app.settings.audio.limiter)
            Button { app.toggleMicMute() } label: {
                Label(app.micMuted ? "取消静音" : "静音（\(app.settings.combo(for: .micMute).display)）", systemImage: app.micMuted ? "mic" : "mic.slash")
            }
            .buttonStyle(PillButtonStyle(tone: app.micMuted ? .danger : .secondary, compact: true))
        }

        SectionCard(title: "电脑声音", icon: "speaker.wave.2") {
            ToggleRow(title: "录制系统声音", subtitle: "演示 AI 语音、视频等声音时打开（本工具自己的声音不会被录进去）", isOn: $app.settings.audio.systemAudio)
            if app.settings.audio.systemAudio {
                SliderRow(title: "系统声音音量", value: $app.settings.audio.systemGainDB, range: -30...6) { String(format: "%+.0f dB", $0) }
            }
        }

        BGMSection(live: live)

        SectionCard(title: "音画同步", icon: "timer") {
            ToggleRow(title: "自动补偿摄像头延迟",
                      subtitle: String(format: "当前测得画面延迟约 %.0f ms，开始录制时把声音对齐到画面", app.engine.videoLag * 1000),
                      isOn: $app.settings.audio.autoSync)
            SliderRow(title: "额外微调（声音延后）", value: $app.settings.audio.avOffsetMs, range: -300...300) { String(format: "%+.0f ms", $0) }
            Text("如果回看时嘴型仍然比声音慢，就再把声音延后（正值）一点。").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
    }
}

struct BGMSection: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var live: LiveStatus

    var body: some View {
        SectionCard(title: "BGM 背景音乐", icon: "music.note.list",
                    note: "BGM 直接混进录音，不经过扬声器，所以不会被麦克风二次录到。开启「人声闪避」后你说话时音乐会自动变小。") {
            HStack(spacing: 8) {
                Button { app.mixer.bgm.previous() } label: { Image(systemName: "backward.fill") }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                Button { app.toggleBGM() } label: {
                    Label(live.bgm.playing ? "暂停" : "播放", systemImage: live.bgm.playing ? "pause.fill" : "play.fill")
                }
                .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                Button { app.mixer.bgm.next() } label: { Image(systemName: "forward.fill") }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                Spacer()
                KeyHint(text: app.settings.combo(for: .bgm).display)
            }
            if !live.bgm.trackName.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(live.bgm.trackName).font(.system(size: 12)).foregroundStyle(Theme.text).lineLimit(1)
                    ProgressView(value: live.bgm.duration > 0 ? min(1, live.bgm.position / live.bgm.duration) : 0)
                        .tint(Theme.accent)
                    Text("\(formatTimecode(live.bgm.position)) / \(formatTimecode(live.bgm.duration))")
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.text3)
                }
            }
            VStack(spacing: 4) {
                ForEach(Array(app.settings.bgm.tracks.enumerated()), id: \.offset) { i, path in
                    HStack(spacing: 8) {
                        Image(systemName: i == live.bgm.index && live.bgm.playing ? "speaker.wave.2.fill" : "music.note")
                            .font(.system(size: 10)).foregroundStyle(Theme.accentSoft).frame(width: 16)
                        Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension)
                            .font(.system(size: 12)).foregroundStyle(Theme.text2).lineLimit(1)
                        Spacer()
                        Button { app.mixer.bgm.select(i) } label: { Image(systemName: "play.circle") }
                            .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                        Button { app.settings.bgm.tracks.remove(at: i) } label: { Image(systemName: "trash") }
                            .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                    }
                }
            }
            Button { app.addBGM() } label: { Label("添加音乐（mp3 / m4a / wav）", systemImage: "plus") }
                .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
            SliderRow(title: "BGM 音量", value: $app.settings.bgm.volumeDB, range: -40...0) { String(format: "%.0f dB", $0) }
            ToggleRow(title: "人声闪避", subtitle: "说话时自动压低音乐，停顿时慢慢恢复", isOn: $app.settings.bgm.ducking)
            if app.settings.bgm.ducking {
                SliderRow(title: "闪避幅度", value: $app.settings.bgm.duckDB, range: -24 ... -3) { String(format: "%.0f dB", $0) }
            }
            SliderRow(title: "淡入淡出", value: $app.settings.bgm.fadeSeconds, range: 0.1...5) { String(format: "%.1f 秒", $0) }
            LabeledRow(title: "播放模式") {
                Picker("", selection: $app.settings.bgm.loopMode) {
                    ForEach(BGMLoopMode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 210)
            }
            ToggleRow(title: "开始录制时自动播放", isOn: $app.settings.bgm.autoStart)
            ToggleRow(title: "耳机监听 BGM", subtitle: "戴耳机时打开；用外放会被麦克风录进去", isOn: $app.settings.bgm.monitor)
            if app.settings.bgm.monitor {
                SliderRow(title: "监听音量", value: $app.settings.bgm.monitorVolume, range: 0...1) { String(format: "%.0f%%", $0 * 100) }
            }
        }
    }
}

// MARK: - Overlays

struct OverlayTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SectionCard(title: "人名条", icon: "person.text.rectangle",
                    note: "按 \(app.settings.combo(for: .lowerThird).display) 滑入，几秒后自动收起。适合开场自我介绍。") {
            LabeledRow(title: "姓名") {
                TextField("", text: $app.settings.overlay.lowerThirdName).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            LabeledRow(title: "头衔") {
                TextField("", text: $app.settings.overlay.lowerThirdTitle).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            SliderRow(title: "停留时长", value: $app.settings.overlay.lowerThirdSeconds, range: 2...15) { String(format: "%.0f 秒", $0) }
            Button { app.showLowerThird() } label: { Label("现在显示", systemImage: "play.fill") }
                .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
        }

        SectionCard(title: "角标水印", icon: "seal", note: "在画面角落显示课程品牌，例如「WORK AGENT | 入门课」。") {
            ToggleRow(title: "显示角标", isOn: $app.settings.overlay.watermarkEnabled)
            LabeledRow(title: "主标题") {
                TextField("", text: $app.settings.overlay.watermarkTitle).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            LabeledRow(title: "副标题") {
                TextField("", text: $app.settings.overlay.watermarkSubtitle).textFieldStyle(.roundedBorder).frame(width: 200)
            }
            LabeledRow(title: "位置") {
                Picker("", selection: $app.settings.overlay.watermarkCorner) {
                    ForEach(Corner.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 200)
            }
            Text("显示在这些镜头").font(.system(size: 12)).foregroundStyle(Theme.text2)
            HStack(spacing: 6) {
                ForEach(SceneKind.allCases) { s in
                    let on = app.settings.overlay.watermarkScenes.contains(s)
                    ChipButton(title: s.title, active: on) {
                        if on { app.settings.overlay.watermarkScenes.removeAll { $0 == s } } else { app.settings.overlay.watermarkScenes.append(s) }
                    }
                }
            }
        }

        SectionCard(title: "颜色", icon: "paintpalette") {
            LabeledRow(title: "强调色（人名条 / 角标）") {
                ColorPicker("", selection: colorBinding($app.settings.overlay.accent), supportsOpacity: false).labelsHidden()
            }
            LabeledRow(title: "点击高亮颜色") {
                ColorPicker("", selection: colorBinding($app.settings.overlay.clickColor), supportsOpacity: false).labelsHidden()
            }
        }

        SectionCard(title: "构图辅助", icon: "grid") {
            ToggleRow(title: "预览显示三分线", subtitle: "只在预览里显示，不会录进视频", isOn: $app.settings.showGuides)
        }
    }
}

// MARK: - Teleprompter

struct PrompterTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SectionCard(title: "提词器", icon: "text.justify.left",
                    note: "提词器是一个悬浮窗，不会被录进视频。把它拖到摄像头正下方，读稿时眼神更自然。") {
            HStack(spacing: 8) {
                Button { app.onTeleprompter?(.show) } label: { Label("打开提词器", systemImage: "macwindow") }
                    .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                Button { app.onTeleprompter?(.togglePlay) } label: { Label("开始 / 暂停", systemImage: "playpause.fill") }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                Button { app.onTeleprompter?(.rewind) } label: { Image(systemName: "backward.end.fill") }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                Spacer()
                KeyHint(text: app.settings.combo(for: .teleprompter).display)
            }
            TextEditor(text: $app.settings.teleprompter.text)
                .font(.system(size: 13))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 260)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.3)))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.stroke))
            SliderRow(title: "字号", value: $app.settings.teleprompter.fontSize, range: 18...72) { String(format: "%.0f", $0) }
            SliderRow(title: "滚动速度", value: $app.settings.teleprompter.speed, range: 5...150) { String(format: "%.0f", $0) }
            SliderRow(title: "行距", value: $app.settings.teleprompter.lineSpacing, range: 0...30) { String(format: "%.0f", $0) }
            SliderRow(title: "背景不透明度", value: $app.settings.teleprompter.opacity, range: 0.3...1) { String(format: "%.0f%%", $0 * 100) }
        }
    }
}

// MARK: - Recording

struct RecordTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        let locked = !app.canChangeOutputFormat
        SectionCard(title: "输出格式", icon: "film", note: locked ? "录制、播放或处理项目期间不能修改格式" : nil) {
            LabeledRow(title: "画幅比例") {
                Picker("", selection: Binding(get: { app.settings.recording.aspect }, set: { app.setOutputAspect($0) })) {
                    ForEach(OutputAspect.allCases) { Text("\($0.title) \($0.detail)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            LabeledRow(title: "分辨率") {
                Picker("", selection: $app.settings.recording.resolution) {
                    ForEach(OutputResolution.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 230)
            }
            let size = app.settings.recording.outputSize
            Text("实际输出：\(Int(size.width)) × \(Int(size.height)) 像素")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            LabeledRow(title: "帧率") {
                Picker("", selection: $app.settings.recording.fps) {
                    Text("30 fps").tag(30)
                    Text("60 fps").tag(60)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            LabeledRow(title: "编码") {
                Picker("", selection: $app.settings.recording.codec) {
                    ForEach(VideoCodec.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden().frame(width: 200)
            }
            LabeledRow(title: "画质") {
                Picker("", selection: $app.settings.recording.quality) {
                    ForEach(RecordingQuality.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 170)
            }
            let mbps = Double(app.settings.recording.videoBitrate) / 1_000_000
            Text(String(format: "视频码率约 %.0f Mbps，每分钟约 %.0f MB。4K 建议 30fps 或使用 HEVC。", mbps, mbps * 60 / 8 + 1.5))
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
        .disabled(locked)

        SectionCard(title: "保存", icon: "folder") {
            HStack(spacing: 8) {
                Text(app.settings.recording.folderURL.path)
                    .font(.system(size: 11)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("更改…") { app.chooseRecordingFolder() }.buttonStyle(PillButtonStyle(tone: .secondary, compact: true)).disabled(locked)
                Button { app.openRecordingFolder() } label: { Image(systemName: "folder") }
                    .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
            }
            LabeledRow(title: "文件名前缀") {
                TextField("", text: $app.settings.recording.filePrefix).textFieldStyle(.roundedBorder).frame(width: 180)
            }
            LabeledRow(title: "开始前倒计时") {
                Picker("", selection: $app.settings.recording.countdown) {
                    Text("无").tag(0)
                    Text("3 秒").tag(3)
                    Text("5 秒").tag(5)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 150)
            }
            ToggleRow(title: "倒计时提示音", isOn: $app.settings.recording.countdownSound)
            LabeledRow(title: "自动分段保存") {
                Picker("", selection: $app.settings.recording.segmentMinutes) {
                    Text("关闭").tag(0)
                    Text("5 分钟").tag(5)
                    Text("10 分钟").tag(10)
                    Text("15 分钟").tag(15)
                    Text("30 分钟").tag(30)
                }
                .labelsHidden().frame(width: 120)
                .disabled(locked)
            }
            Text(app.settings.recording.segmentMinutes > 0
                 ? "录到每 \(app.settings.recording.segmentMinutes) 分钟自动存好一段、无缝接着录下一段（文件名带「第2段」「第3段」）。万一程序崩溃或被强制退出，最多只丢正在录的那一段。"
                 : "整节课存成一个文件。注意：万一程序崩溃或被强制退出，正在录的文件会无法打开。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            ToggleRow(title: "停止后合并为完整录像", subtitle: "合并并校验成功后，原分段移到废纸篓；失败或取消保留分段", isOn: $app.settings.recording.mergeSegmentsOnStop)
                .disabled(locked)
            if let progress = app.recordingMergeProgress {
                ProgressView(value: progress).tint(Theme.accent)
                Button("取消合并并保留分段") { app.cancelRecordingMerge() }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
            }
            if !app.recordingMergeStatus.isEmpty {
                Text(app.recordingMergeStatus).font(.system(size: 10.5)).foregroundStyle(Theme.text2)
                    .textSelection(.enabled)
            }
            Text("每次录制会生成 .mp4，以及打点文件 .markers.txt / .markers.srt（可导入剪映、Premiere 当字幕轨查看打点）。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }

        if !app.markers.isEmpty {
            SectionCard(title: "本次打点", icon: "flag") {
                ForEach(app.markers) { m in
                    HStack {
                        Image(systemName: m.kind == .chapter ? "flag.fill" : "scissors")
                            .foregroundStyle(m.kind == .chapter ? Theme.accentSoft : Theme.amber)
                        Text(formatTimecode(m.time)).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.text)
                        Text(m.note).font(.system(size: 11)).foregroundStyle(Theme.text3).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }

        SectionCard(title: "最近录制", icon: "clock.arrow.circlepath") {
            if app.recentRecordings.isEmpty {
                Text("还没有录制文件").font(.system(size: 12)).foregroundStyle(Theme.text3)
            }
            ForEach(app.recentRecordings, id: \.self) { url in
                HStack(spacing: 8) {
                    Image(systemName: "film").foregroundStyle(Theme.accentSoft)
                    Text(url.lastPathComponent).font(.system(size: 11.5)).foregroundStyle(Theme.text2).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button { NSWorkspace.shared.open(url) } label: { Image(systemName: "play.fill") }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                    Button { app.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                }
            }
        }
        .onAppear { app.refreshRecent() }

        SectionCard(title: "会议共享 / OBS", icon: "dot.radiowaves.left.and.right",
                    note: "1. 打开共享画面。\n2. 在飞书 / 腾讯会议的共享窗口中选择「\(ProgramWindowController.shareWindowTitle)」。\n3. 在本工具切换镜头、课件和演示，会议端显示合成结果；无需开始录制。") {
            Button { app.onShowProgram?() } label: { Label("打开会议共享画面", systemImage: "tv") }
                .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
            Text("保持输出窗口打开，不要最小化。OBS 可用「macOS 屏幕采集 → 窗口」选择同一窗口。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
            Text("发言请在会议里选真实麦克风；本工具静音只影响录制。电脑声音使用会议的共享声音选项，混音和 BGM 不会自动注入会议。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Hotkeys

struct HotkeysTab: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        SectionCard(title: "全局快捷键", icon: "command",
                    note: "在任何应用里都能用（比如正在操作 AI 工具时）。点击右侧按键框后直接按新组合，Esc 取消。黄色表示被其他应用占用。") {
            ForEach(HotkeyAction.allCases) { a in
                HStack {
                    Text(a.title).font(.system(size: 12)).foregroundStyle(Theme.text2)
                    Spacer()
                    HotkeyField(action: a)
                }
            }
            Button("恢复默认快捷键") { app.settings.hotkeys = HotkeyAction.defaults }
                .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
        }

        SectionCard(title: "推荐录制流程", icon: "lightbulb") {
            VStack(alignment: .leading, spacing: 6) {
                tip("1", "先在「画面源」勾选两块屏幕：一块放 AI 操作，一块放结果。")
                tip("2", "按 \(app.settings.combo(for: .record).display) 开始，倒计时后进入录制；主窗口可以最小化，录制照常进行。")
                tip("3", "开场用 \(app.settings.combo(for: .sceneCamera).display) 出镜，讲 PPT 用 \(app.settings.combo(for: .sceneSlides).display)，实操用 \(app.settings.combo(for: .sceneDemo).display)。")
                tip("4", "实操时 \(app.settings.combo(for: .nextSource).display) 切屏，\(app.settings.combo(for: .toggleZoom).display) 放大细节，\(app.settings.combo(for: .togglePIP).display) 收起小窗。")
                tip("5", "说错了按 \(app.settings.combo(for: .markerNG).display) 打个「口误」点，后期直接定位剪掉。")
            }
        }
    }

    private func tip(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n).font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                .frame(width: 16, height: 16).background(Circle().fill(Theme.accent))
            Text(text).font(.system(size: 11.5)).foregroundStyle(Theme.text2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
