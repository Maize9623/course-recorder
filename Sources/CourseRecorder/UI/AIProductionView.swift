import SwiftUI

struct AIProductionCard: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var ai: AIProductionController
    @ObservedObject var session: ProductionSession

    var body: some View {
        SectionCard(title: "AI 自动配镜头", icon: "sparkles",
                    note: "用当前口播、课件和已录演示生成镜头初稿。需要剪掉重说时，请先在「整理口播与字幕」中完成剪辑，再配操作。使用当前 ChatGPT 登录；音视频文件不上传。") {
            if ai.isBusy {
                ProgressView(value: ai.progress).tint(Theme.accent)
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(ai.status).font(.system(size: 11)).foregroundStyle(Theme.text2)
                        Text("已用时 \(ai.elapsed) 秒").font(.system(size: 10, design: .monospaced)).foregroundStyle(Theme.text3)
                    }
                    Spacer()
                    Button("取消") { ai.cancel() }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                }
            } else if let draft = ai.draft {
                Text(draft.summary).font(.system(size: 11)).foregroundStyle(Theme.text2)
                ForEach(draft.warnings, id: \.self) { warning in
                    Text(warning).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
                HStack(spacing: 7) {
                    Button { ai.preview(in: app) } label: { Label("预览初稿", systemImage: "play.rectangle") }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    Button("采纳") { ai.adopt(in: app) }
                        .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    Button("放弃") { ai.discard(in: app) }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                }
                Text("采纳前保留原时间线；采纳时自动保存备份。点击下方条目可定位预览。")
                    .font(.system(size: 10)).foregroundStyle(Theme.text3)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(draft.review) { row in
                            Button {
                                if session.isReviewing { session.seek(to: row.cue.time) }
                                else { ai.preview(in: app, at: row.cue.time) }
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text("\(formatTimecode(row.cue.time))  \(row.cue.action.reviewTitle)")
                                        .font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.text)
                                    Text(row.reason).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                                        .fixedSize(horizontal: false, vertical: true)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(.plain)
                        }
                    }
                }.frame(maxHeight: 240)
            } else {
                Button { ai.generate(for: app) } label: { Label("AI 生成时间线", systemImage: "sparkles") }
                    .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    .disabled(!session.isLoaded || app.recState != .idle || app.exportProgress != nil || app.narrationImportProgress != nil || app.projectActionInProgress || session.isFinishingTakes || app.deckConverting || !ai.connection.isChatGPT || ai.connection.isBusy)
                if !ai.connection.isChatGPT {
                    Text("先在本页顶部连接 ChatGPT / Codex，再生成时间线。")
                        .font(.system(size: 11)).foregroundStyle(Theme.accentSoft)
                }
                if !ai.status.isEmpty {
                    Text(ai.status).font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
                if session.project?.takes.isEmpty == true {
                    Text("没有演示素材时，只安排出镜与可用幻灯片。需要实操画面时，先播放口播录一遍演示。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
            }
            if let error = ai.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
