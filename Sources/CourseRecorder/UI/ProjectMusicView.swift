import SwiftUI

struct ProjectMusicView: View {
    @EnvironmentObject var app: AppState
    @ObservedObject var session: ProductionSession

    var body: some View {
        if let project = session.project {
            VStack(alignment: .leading, spacing: 9) {
                ToggleRow(title: "加入 BGM", subtitle: "在导出的成片中加入背景音乐",
                          isOn: Binding(get: { project.includeBGM }, set: { app.setProjectBGMEnabled($0) }))
                    .disabled(!app.canManageProject)
                if project.includeBGM {
                    HStack(spacing: 8) {
                        Menu {
                            Button("默认：沿用「音频」页播放列表") { app.useDefaultProjectBGM() }
                            if !app.settings.bgm.tracks.isEmpty {
                                Divider()
                                ForEach(Array(app.settings.bgm.tracks.enumerated()), id: \.offset) { _, path in
                                    Button(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent) {
                                        app.selectProjectBGM(path: path)
                                    }
                                }
                            }
                        } label: {
                            Text(project.bgmFile == nil ? "默认音乐" : "更换音乐")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                        .disabled(!app.canManageProject)
                        Button { app.chooseProjectBGM() } label: {
                            Label("选择本地音乐", systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                        .disabled(!app.canManageProject)
                    }
                    if let file = project.bgmFile {
                        Label(URL(fileURLWithPath: file).lastPathComponent, systemImage: "music.note")
                            .font(.system(size: 11)).foregroundStyle(Theme.text2)
                            .lineLimit(2).textSelection(.enabled)
                        Text("已保存项目副本；移动原音乐文件不会影响导出。")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    } else {
                        Text(app.settings.bgm.tracks.isEmpty
                             ? "默认列表还没有音乐，请选择本地文件，或在「音频」页添加。"
                             : "沿用「音频」页播放列表，共 \(app.settings.bgm.tracks.count) 首。")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                        if !app.settings.bgm.tracks.isEmpty {
                            Text(app.settings.bgm.tracks.prefix(3).map {
                                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
                            }.joined(separator: " · ") + (app.settings.bgm.tracks.count > 3 ? " 等" : ""))
                                .font(.system(size: 11)).foregroundStyle(Theme.text2)
                                .lineLimit(3)
                        }
                    }
                    Text("音量、循环、淡入淡出和说话时自动压低，沿用「音频」页设置。")
                        .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                }
                ProjectMusicImportProgress(controller: app.projectMusicImport, cancel: app.cancelProjectMusicImport)
            }
        }
    }
}

private struct ProjectMusicImportProgress: View {
    @ObservedObject var controller: ProjectMusicImportController
    var cancel: () -> Void

    var body: some View {
        if controller.isBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(controller.status).font(.system(size: 10.5)).foregroundStyle(Theme.text2)
                Spacer(minLength: 0)
                Button("取消", action: cancel).buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
            }
        }
    }
}
