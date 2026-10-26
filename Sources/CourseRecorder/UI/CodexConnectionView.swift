import SwiftUI
import AppKit

/// Visible before creating a course so the subscription connection is an explicit first step.
struct CodexConnectionCard: View {
    @ObservedObject var connection: CodexConnection
    var disabled = false

    var body: some View {
        SectionCard(title: "连接 ChatGPT / Codex", icon: "person.crop.circle.badge.checkmark",
                    note: "使用你的 ChatGPT 账号，通过 Codex 订阅额度生成镜头。无需填写 API Key。") {
            HStack(alignment: .top, spacing: 8) {
                if connection.isBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: connection.isChatGPT ? "checkmark.circle.fill" : "person.crop.circle.badge.questionmark")
                        .foregroundStyle(connection.isChatGPT ? Theme.green : Theme.text3)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(connection.status).font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.text)
                    if let tested = connection.lastTested {
                        Text("订阅调用测试通过 · \(tested.formatted(date: .omitted, time: .shortened))")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.green)
                    } else if connection.isChatGPT {
                        Text("已识别本机的 ChatGPT 登录，可点「测试连接」确认调用可用。")
                            .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
                    }
                }
            }
            if connection.isBusy {
                if connection.isLoggingIn {
                    Text("请在浏览器中登录有订阅的 ChatGPT 账号并完成授权；完成后这里会自动更新。")
                        .font(.system(size: 11)).foregroundStyle(Theme.text2)
                    if let url = connection.loginURL {
                        Button("重新打开登录页面") { NSWorkspace.shared.open(url) }
                            .buttonStyle(PillButtonStyle(tone: .secondary, compact: true))
                    }
                }
                Button("取消") { connection.cancel() }
                    .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
            } else {
                HStack(spacing: 8) {
                    if connection.state == .missingCLI {
                        Button("安装 ChatGPT") { NSWorkspace.shared.open(URL(string: "https://chatgpt.com/download/")!) }
                            .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                    } else {
                        Button {
                            connection.login()
                        } label: {
                            Label(connection.isChatGPT ? "重新登录" : "连接 ChatGPT", systemImage: "person.badge.key")
                        }
                        .buttonStyle(PillButtonStyle(tone: connection.isChatGPT ? .secondary : .primary, compact: true))
                        .disabled(disabled)
                    }
                    Button("检查登录") { connection.refresh() }
                        .buttonStyle(PillButtonStyle(tone: .ghost, compact: true))
                        .disabled(disabled)
                    if connection.isChatGPT {
                        Button("测试连接") { connection.testConnection() }
                            .buttonStyle(PillButtonStyle(tone: .primary, compact: true))
                            .disabled(disabled)
                    }
                }
            }
            if let error = connection.error {
                Text(error).font(.system(size: 11)).foregroundStyle(Theme.red)
                    .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("测试连接只发送一条测试文字，会使用少量 Codex 额度；不发送课程内容。")
                .font(.system(size: 10.5)).foregroundStyle(Theme.text3)
        }
        .onAppear {
            if connection.state == .unknown && !connection.isBusy { connection.refresh() }
        }
    }
}
