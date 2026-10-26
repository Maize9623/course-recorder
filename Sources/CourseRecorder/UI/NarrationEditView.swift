import SwiftUI
import AppKit

struct NarrationEditCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var edit: NarrationEditController
    @ObservedObject var session: ProductionSession

    var body: some View {
        SectionCard(title: "② 整理口播与字幕", icon: "scissors",
                    note: "配操作前，先保守删除明显重说和口误重来。AI 根据文字提出建议，试听后再采纳；原视频保留。字幕随剪后的时间重新对齐。") {
            if edit.isBusy {
                ProgressView(value: edit.progress).tint(Theme.accent)
                HStack {
                    Text(edit.status).font(.system(size: 11)).foregroundStyle(Theme.text2)
                    Spacer()
                    Button("取消") { edit.cancel(in: app) }.buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                }
            } else if let draft = edit.draft {
                Text(draft.summary).font(.system(size: 11)).foregroundStyle(Theme.text2)
                Text("已选 \(edit.cuts.count) 处，缩短约 \(String(format: "%.1f", edit.removedDuration)) 秒")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.accentSoft)
                ForEach(draft.warnings, id: \.self) { warning in
                    Text(warning).font(.system(size: 10.5)).foregroundStyle(Theme.amber)
                }
                if !draft.cuts.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(draft.cuts) { cut in
                                VStack(alignment: .leading, spacing: 4) {
                                    Toggle(isOn: Binding(get: { edit.selected.contains(cut.id) }, set: { edit.select(cut, enabled: $0) })) {
                                        Text("\(formatTimecode(cut.start))–\(formatTimecode(cut.end))  \(cut.text)")
                                            .font(.system(size: 11)).fixedSize(horizontal: false, vertical: true)
                                    }.toggleStyle(.checkbox)
                                    Text(cut.reason).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                                    Button { edit.audition(cut, in: app) } label: { Label("试听原片段", systemImage: "play.fill") }
                                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                                }
                            }
                        }.padding(.trailing, 4)
                    }.frame(maxHeight: 260)
                }
                HStack(spacing: 7) {
                    Button("预览剪后效果") { edit.renderPreview(in: app) }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    Button(edit.cuts.isEmpty ? "保存字幕" : "应用剪辑与字幕") { edit.adopt(in: app) }
                        .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    Button("放弃") { edit.cancel(in: app) }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                }
                Text("字幕为可编辑的 SRT 文件，不会烧进画面。剪辑改变时长，已有操作需重新配；可恢复剪辑前版本。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            } else {
                HStack(spacing: 8) {
                    Button { edit.generate(in: app) } label: { Label("AI 整理口播", systemImage: "sparkles") }
                        .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                        .disabled(!available || !app.aiProduction.connection.isChatGPT || app.aiProduction.connection.isBusy)
                    Button("只生成字幕") { edit.generate(in: app, subtitlesOnly: true) }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true)).disabled(!available)
                }
                Text("保守模式优先保留内容；较长停顿建议默认不选。只生成字幕使用本机识别，无需 Codex 调用。")
                    .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                if session.project?.narrationEditBackup != nil {
                    Button("恢复上次剪辑前版本") { edit.restore(in: app) }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true)).disabled(!app.canManageProject)
                }
            }
            if let relative = session.project?.subtitleFile, let folder = session.folder,
               let url = try? NarrationEditStore.localFile(relative, in: folder) {
                Button { app.reveal(url) } label: { Label("显示 SRT 字幕文件", systemImage: "captions.bubble") }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
            }
            if !edit.isBusy, !edit.status.isEmpty {
                Text(edit.status).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
            }
            if let error = edit.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var available: Bool {
        session.isLoaded && app.recState == .idle && app.exportProgress == nil && app.narrationImportProgress == nil
            && !app.projectActionInProgress && !app.aiProduction.locksProject && !session.isFinishingTakes
    }
}
