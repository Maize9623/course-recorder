import SwiftUI
import AppKit

// MARK: - Mode switch (top bar)

struct WorkModeSwitch: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        HStack(spacing: 2) {
            modeButton(.live, title: "实时录制", icon: "dot.radiowaves.left.and.right")
            modeButton(.production, title: "口播制作", icon: "film.stack")
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.stroke))
        .help("实时录制：边讲边操作，直接出 MP4。口播制作：先录口播，再对着口播配操作，最后导出成片")
    }

    private func modeButton(_ mode: AppState.WorkMode, title: String, icon: String) -> some View {
        let active = app.workMode == mode
        return Button { app.setWorkMode(mode) } label: {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(active ? Color.white : Theme.text2)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(active ? Theme.accent.opacity(0.85) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(app.recState != .idle || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || app.production.isFinishingTakes)
    }
}

// MARK: - Timeline (under the preview)

struct ProductionTimeline: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: ProductionSession

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Label(session.project?.name ?? "还没有项目", systemImage: "folder")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text2).lineLimit(1)
                stepBadge
                Spacer()
                if session.isLoaded {
                    Button { session.seek(to: 0) } label: { Image(systemName: "backward.end.fill") }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                        .help("回到开头")
                    Button { session.togglePlay() } label: {
                        HStack(spacing: 6) {
                            Image(systemName: session.isPlaying ? "pause.fill" : "play.fill")
                            Text(session.isPlaying ? "暂停" : (session.isReviewing ? "播放预览" : "播放并配操作"))
                            KeyHint(text: "空格")
                        }
                    }
                    .buttonStyle(PillButtonStyle(tone: session.isPlaying ? .secondary : .primary, compact: true))
                    .disabled(app.aiProduction.isBusy || (app.aiProduction.hasDraft && !session.isReviewing) || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || session.isFinishingTakes)
                    Text("\(formatTimecode(session.time)) / \(formatTimecode(session.duration))")
                        .font(.system(size: 12, weight: .medium, design: .monospaced)).foregroundStyle(Theme.text)
                    if session.recordingTake {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.red).frame(width: 7, height: 7)
                            Text("正在录演示画面").font(.system(size: 11)).foregroundStyle(Theme.text2)
                        }
                    }
                    if session.isReviewing {
                        Text("预览中 · 不记录操作").font(.system(size: 11)).foregroundStyle(Theme.accentSoft)
                        Button("退出预览") { session.stopReview() }
                            .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                    }
                    Button { session.clearAfterCurrentTime() } label: { Label("清除此后", systemImage: "scissors") }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                        .help("删掉当前位置之后记录的所有切换和演示素材，从这里重新配")
                        .disabled(app.aiProduction.locksProject || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || session.isFinishingTakes || session.isReviewing)
                } else if session.project != nil, app.recState == .idle {
                    Text("第 1 步：点右上角「开始录口播」，对着镜头讲完整节课")
                        .font(.system(size: 12)).foregroundStyle(Theme.text3)
                } else if session.project == nil {
                    Button { app.toggleRecording() } label: { Label("开始录口播", systemImage: "record.circle") }
                        .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                        .disabled(!app.canManageProject)
                        .help("先命名并创建项目，再开始录口播")
                }
            }
            if session.isLoaded, let project = session.project {
                let shownProject: CourseProject = {
                    var shown = project
                    if let draft = app.aiProduction.draft { shown.cues = draft.cues }
                    return shown
                }()
                TimelineBar(project: shownProject, time: session.time, duration: session.duration) { t in
                    session.seek(to: t)
                } onScrubStart: {
                    if session.isPlaying { session.pause() }
                }
                .frame(height: 44)
                .disabled(app.aiProduction.isBusy || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || session.isFinishingTakes)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.stroke))
    }

    private var stepBadge: some View {
        let text: String
        if session.project == nil { text = "口播制作" }
        else if !session.isLoaded { text = app.recState.isActive ? "① 正在录口播" : "① 录口播" }
        else if session.project?.outputFile != nil { text = "③ 已导出成片" }
        else { text = "② 配操作" }
        return Text(text)
            .font(.system(size: 10.5, weight: .semibold)).foregroundStyle(Theme.accentSoft)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Theme.accent.opacity(0.18)))
    }
}

/// Scene segments, slide flips and recorded takes along the narration, with a draggable playhead.
struct TimelineBar: View {
    let project: CourseProject
    let time: Double
    let duration: Double
    let onSeek: (Double) -> Void
    let onScrubStart: () -> Void
    @StateObject private var scrub = ViewState<Double?>(nil)

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let shown = scrub.value ?? time
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.05))
                SwiftUI.Canvas { ctx, size in
                    guard duration > 0 else { return }
                    let laneH = size.height * 0.5
                    let cues = project.sortedCues
                    // Scene lanes
                    var current: SceneKind = .camera
                    var start = 0.0
                    func fill(_ s: SceneKind, from a: Double, to b: Double) {
                        let x0 = size.width * CGFloat(a / duration), x1 = size.width * CGFloat(b / duration)
                        guard x1 > x0 else { return }
                        ctx.fill(Path(CGRect(x: x0, y: 4, width: x1 - x0, height: laneH - 4)), with: .color(Self.color(for: s)))
                    }
                    for c in cues {
                        if case .scene(let s) = c.action {
                            fill(current, from: start, to: c.time)
                            current = s
                            start = c.time
                        }
                    }
                    fill(current, from: start, to: duration)
                    // Slide flips
                    for c in cues {
                        if case .slide = c.action {
                            let x = size.width * CGFloat(c.time / duration)
                            ctx.fill(Path(CGRect(x: x - 0.5, y: 4, width: 1.5, height: laneH - 4)), with: .color(.white.opacity(0.7)))
                        }
                    }
                    // Takes
                    for t in project.takes {
                        let x0 = size.width * CGFloat(t.start / duration), x1 = size.width * CGFloat(min(duration, t.end) / duration)
                        ctx.fill(Path(roundedRect: CGRect(x: x0, y: laneH + 6, width: max(2, x1 - x0), height: size.height - laneH - 10), cornerRadius: 2),
                                 with: .color(Theme.green.opacity(0.75)))
                    }
                }
                // Playhead
                if duration > 0 {
                    let x = w * CGFloat(min(1, max(0, shown / duration)))
                    Rectangle().fill(Color.white).frame(width: 2, height: h).offset(x: x - 1)
                    Circle().fill(Color.white).frame(width: 9, height: 9).offset(x: x - 4.5, y: -4)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { g in
                    if scrub.value == nil { onScrubStart() }
                    scrub.value = duration * Double(min(1, max(0, g.location.x / max(1, w))))
                }
                .onEnded { g in
                    let t = duration * Double(min(1, max(0, g.location.x / max(1, w))))
                    scrub.value = nil
                    onSeek(t)
                })
        }
        .overlay(alignment: .bottomLeading) {
            HStack(spacing: 10) {
                legend(.camera); legend(.slides); legend(.demo); legend(.split)
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.green.opacity(0.75)).frame(width: 10, height: 6)
                    Text("已录的演示画面").font(.system(size: 9.5)).foregroundStyle(Theme.text3)
                }
            }
            .padding(.leading, 4)
            .offset(y: 16)
        }
        .padding(.bottom, 16)
    }

    private func legend(_ s: SceneKind) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Self.color(for: s)).frame(width: 10, height: 6)
            Text(s.title).font(.system(size: 9.5)).foregroundStyle(Theme.text3)
        }
    }

    static func color(for s: SceneKind) -> Color {
        switch s {
        case .camera: Color(red: 0.55, green: 0.45, blue: 0.95)
        case .slides: Color(red: 0.25, green: 0.6, blue: 0.95)
        case .demo: Color(red: 0.95, green: 0.6, blue: 0.25)
        case .split: Color(red: 0.2, green: 0.75, blue: 0.65)
        }
    }
}

// MARK: - Inspector tab

struct ProductionTab: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: ProductionSession
    @StateObject private var newName = ViewState("")

    var body: some View {
        CodexConnectionCard(connection: app.aiProduction.connection,
                            disabled: app.recState != .idle || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.isBusy)

        if app.workMode != .production {
            SectionCard(title: "口播制作", icon: "film.stack",
                        note: "先对着镜头把整节课的口播一次讲完，再播放口播、对着它切镜头和操作电脑，最后导出成片。中途不用担心操作打断讲解。") {
                Button { app.setWorkMode(.production) } label: { Label("进入口播制作模式", systemImage: "film.stack") }
                    .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    .disabled(app.recState != .idle || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || app.production.isFinishingTakes)
            }
        }

        SectionCard(title: "项目", icon: "folder", note: "每个项目一个文件夹，放在录制目录的「项目」里：口播视频、配操作时录下的演示画面、时间线和成片。") {
            if let p = session.project {
                HStack(spacing: 8) {
                    Image(systemName: "folder.fill").foregroundStyle(Theme.accentSoft)
                    Text(p.name).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text).lineLimit(1)
                    Spacer()
                    Button { app.revealProject() } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true)).help("在访达中打开项目文件夹")
                }
                Button { app.deleteProject() } label: { Label("删除项目", systemImage: "trash") }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                    .foregroundStyle(Theme.red)
                    .disabled(!app.canManageProject)
                    .help("将当前项目移到废纸篓；请先暂停播放并等待录制、导入、导出和 AI 操作完成")
            }
            HStack(spacing: 8) {
                TextField("新项目名称，例如「第 3 课」", text: $newName.value).textFieldStyle(.roundedBorder)
                Button {
                    if app.createProject(named: newName.value) { newName.value = "" }
                } label: { Label("新建", systemImage: "plus") }
                    .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    .disabled(app.recState != .idle || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || app.production.isFinishingTakes)
            }
            if !app.projectNames.isEmpty {
                LabeledRow(title: "打开已有项目") {
                    Menu {
                        ForEach(app.projectNames, id: \.self) { name in
                            Button(name) { app.openProject(named: name) }
                        }
                        Divider()
                        Button("刷新列表") { app.refreshProjects() }
                    } label: {
                        Text(session.project?.name ?? "选择…").font(.system(size: 12)).lineLimit(1)
                    }
                    .frame(width: 190)
                    .disabled(app.recState != .idle || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || app.production.isFinishingTakes)
                }
            }
        }

        if session.project == nil, app.workMode == .production {
            SectionCard(title: "① 录口播", icon: "record.circle",
                        note: "还没有打开课程项目。直接点开始录口播，为课程命名后即可创建项目并开始录制。") {
                Button { app.toggleRecording() } label: { Label("开始录口播", systemImage: "record.circle") }
                    .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    .disabled(!app.canManageProject)
                Text("已有课程可以从上方「打开已有项目」继续。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
        }

        if let p = session.project {
            if let error = session.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            SectionCard(title: "① 录口播", icon: "record.circle",
                        note: "可以在这里录制，也可以导入用其他工具录好的完整口播视频。准备好口播后，再配镜头和演示操作。") {
                HStack(spacing: 8) {
                    if p.hasNarration {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.green)
                        Text("口播 \(formatTimecode(p.narrationDuration))").font(.system(size: 12)).foregroundStyle(Theme.text)
                    } else {
                        Image(systemName: "circle.dashed").foregroundStyle(Theme.text3)
                        Text("还没有口播视频").font(.system(size: 12)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Button { app.toggleRecording() } label: {
                        Label(app.recState.isActive ? "停止" : (p.hasNarration ? "重录口播" : "开始录口播"),
                              systemImage: app.recState.isActive ? "stop.fill" : "record.circle")
                    }
                    .buttonStyle(PillButtonStyle(tone: app.recState.isActive ? .danger : .primary, compact: true))
                    .disabled(app.recState == .finishing || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || session.isFinishingTakes)
                }
                if p.hasNarration && !app.recState.isActive {
                    Text("重录会清空已配好的时间线和演示素材。").font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
                if let progress = app.narrationImportProgress {
                    ProgressView(value: progress).tint(Theme.accent)
                    HStack(alignment: .top) {
                        Text(app.narrationImportStatus).font(.system(size: 11)).foregroundStyle(Theme.text2)
                        Spacer()
                        Button("取消导入") { app.cancelNarrationImport() }
                            .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                    }
                } else {
                    Button { app.importNarration() } label: { Label("导入口播视频", systemImage: "square.and.arrow.down") }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                        .disabled(app.recState != .idle || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || session.isFinishingTakes)
                    Text("支持 MP4、MOV 等视频。保留原文件；不同画幅等比适配，完整保留画面。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
            }

            NarrationEditCard(edit: app.narrationEdit, session: session)

            SectionCard(title: "③ 配操作", icon: "slider.horizontal.below.rectangle",
                        note: "播放口播，像实时录制一样切镜头、翻页、切屏幕、放大。每一次切换都记在时间线上，所选演示来源会全程录成素材。配错了就把播放头拖回去，点「清除此后」重新配。") {
                HStack(spacing: 14) {
                    stat("切换记录", "\(p.cues.count)")
                    stat("演示素材", "\(p.takes.count) 段 · \(formatBytes(session.takeBytes))")
                    stat("鼠标轨迹", "\(p.cursor.count) 点")
                    Spacer()
                }
                HStack(spacing: 8) {
                    Button {
                        session.review(cues: p.cues)
                    } label: { Label("预览时间线", systemImage: "play.rectangle") }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                        .disabled(app.aiProduction.locksProject || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || session.isFinishingTakes)
                    Button { session.deleteAllTakes() } label: { Label("删除全部演示素材", systemImage: "trash") }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                        .disabled(p.takes.isEmpty || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || app.aiProduction.locksProject || session.isFinishingTakes || session.isReviewing)
                }
                .opacity(session.isLoaded ? 1 : 0.5)
                .disabled(!session.isLoaded)
            }

            AIProductionCard(ai: app.aiProduction, session: session)

            SectionCard(title: "④ 导出成片", icon: "square.and.arrow.up",
                        note: "用和实时录制一样的画面合成、转场和叠加，把口播、演示素材和幻灯片渲染成一个 MP4。可以在下方选择背景音乐。") {
                ProjectMusicView(session: session)
                if let progress = app.exportProgress {
                    VStack(alignment: .leading, spacing: 6) {
                        ProgressView(value: progress).tint(Theme.accent)
                        HStack {
                            Text("正在渲染… \(Int(progress * 100))%").font(.system(size: 11)).foregroundStyle(Theme.text2)
                            Spacer()
                            Button("取消") { app.cancelExport() }.buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                        }
                    }
                } else {
                    HStack(spacing: 8) {
                        Button { app.exportProject() } label: { Label(p.outputFile == nil ? "导出成片" : "重新导出", systemImage: "square.and.arrow.up") }
                            .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                            .disabled(!p.hasNarration || app.recState != .idle || app.aiProduction.locksProject || session.isFinishingTakes || app.narrationImportProgress != nil || app.projectActionInProgress)
                        if let url = app.exportedFileURL {
                            Button { NSWorkspace.shared.open(url) } label: { Label("打开成片", systemImage: "play.fill") }
                                .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                            Button { app.reveal(url) } label: { Image(systemName: "magnifyingglass") }
                                .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                        }
                    }
                }
                Text("输出分辨率、帧率和编码跟「录制」页一致。导出速度取决于课程长度、分辨率和电脑负载，以实际进度为准。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(Theme.text3)
            Text(value).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
        }
    }
}
