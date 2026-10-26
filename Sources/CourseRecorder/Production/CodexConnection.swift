import Foundation
import Combine

/// Account controls are independent from the current course and never receive project paths or content.
final class CodexConnection: ObservableObject {
    enum State: String { case unknown, missingCLI, signedOut, apiKey, chatGPT }

    @Published private(set) var state: State = .unknown
    @Published private(set) var status = "尚未检查 Codex 登录"
    @Published private(set) var error: String?
    @Published private(set) var isBusy = false
    @Published private(set) var isLoggingIn = false
    @Published private(set) var loginURL: URL?
    @Published private(set) var lastTested: Date?
    @Published private(set) var lastChecked: Date?
    var isChatGPT: Bool { state == .chatGPT }
    var isConnected: Bool { isChatGPT }

    private enum Action { case refresh, login, test }
    private let executable: URL
    private let loginTimeout: TimeInterval
    private let testTimeout: TimeInterval
    private var operation: CodexConnectionOperation?
    private var generation = UUID()
    private var cancelRequested = false

    init(executable: URL = URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex"),
         loginTimeout: TimeInterval = 300, testTimeout: TimeInterval = 90) {
        self.executable = executable
        self.loginTimeout = loginTimeout.isFinite ? min(300, max(0.1, loginTimeout)) : 300
        self.testTimeout = testTimeout.isFinite ? min(90, max(0.1, testTimeout)) : 90
    }

    func refresh() { onMain { self.start(.refresh) } }
    func login() { onMain { self.start(.login) } }
    func testConnection() { onMain { self.start(.test) } }
    func cancel() {
        onMain {
            guard self.isBusy else { return }
            self.cancelRequested = true
            self.status = "正在取消连接操作…"
            self.loginURL = nil
            self.operation?.cancel()
        }
    }

    private func onMain(_ body: @escaping () -> Void) {
        if Thread.isMainThread { body() } else { DispatchQueue.main.async(execute: body) }
    }

    private func start(_ action: Action) {
        guard !isBusy else { return }
        error = nil
        loginURL = nil
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            state = .missingCLI
            status = "未找到 Codex"
            lastTested = nil
            error = "请先安装或更新 ChatGPT 桌面版，其中包含此功能需要的 Codex 命令行工具。"
            return
        }
        isBusy = true
        cancelRequested = false
        isLoggingIn = action == .login
        if action != .refresh { lastTested = nil }
        switch action {
        case .refresh: status = "正在检查 Codex 登录…"
        case .login: status = "正在打开 ChatGPT 登录，请在浏览器完成授权（最长 5 分钟）"
        case .test: status = "正在检查 ChatGPT 登录并测试连接…"
        }
        let token = UUID()
        generation = token
        let worker = CodexConnectionOperation(executable: executable)
        operation = worker
        let loginLimit = loginTimeout, testLimit = testTimeout
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result: Result<(State, Bool), Error> = Result {
                try worker.prepare()
                defer { worker.cleanup() }
                if action == .login {
                    let login = try worker.run(arguments: ["login", "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\""],
                                               name: "login", timeout: loginLimit, timeoutMessage: "ChatGPT 登录等待超时，请重新连接并在浏览器完成授权。",
                                               loginLink: { url in
                        DispatchQueue.main.async { [weak self] in
                            guard let self, self.generation == token, self.isLoggingIn, !self.cancelRequested else { return }
                            self.loginURL = url
                        }
                    })
                    guard login.code == 0 else { throw CodexConnectionFailure("ChatGPT 登录未完成。请重试，并在浏览器完成授权；现有登录不会由本应用主动退出。") }
                }
                let auth = try worker.run(arguments: ["login", "status"], name: "status", timeout: 15,
                                          timeoutMessage: "检查 Codex 登录超时，请稍后刷新状态。")
                let state = Self.authenticationState(code: auth.code, text: auth.output)
                guard state != .unknown else { throw CodexConnectionFailure("无法读取 Codex 登录状态。请更新 ChatGPT 桌面版后重试。") }
                if action == .test {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.generation == token else { return }
                        self.state = state
                        self.lastChecked = Date()
                    }
                    guard state == .chatGPT else {
                        throw CodexConnectionFailure(state == .apiKey
                            ? "当前 Codex 使用 API Key 登录。请点击“连接 ChatGPT”，完成 ChatGPT 账号授权后再测试。"
                            : "Codex 尚未登录。请先点击“连接 ChatGPT”，完成浏览器授权后再测试。")
                    }
                    try worker.test(timeout: testLimit)
                }
                return (state, action == .test)
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.generation == token else { return }
                self.isBusy = false
                self.isLoggingIn = false
                self.loginURL = nil
                self.operation = nil
                switch result {
                case .success(let (state, tested)):
                    self.state = state
                    self.lastChecked = Date()
                    if state != .chatGPT { self.lastTested = nil }
                    if tested {
                        self.lastTested = Date()
                        self.status = "连接测试通过，可以使用 ChatGPT 登录生成时间线"
                    } else {
                        switch state {
                        case .chatGPT: self.status = "已连接 ChatGPT（Codex 登录）"
                        case .apiKey:
                            self.status = "当前为 API Key 登录"
                            self.error = "此功能只使用 ChatGPT 登录。请点击“连接 ChatGPT”进行授权。"
                        case .signedOut: self.status = "尚未连接 ChatGPT，请点击连接并在浏览器授权"
                        default: self.status = "尚未确认登录状态"
                        }
                    }
                case .failure(let error):
                    if error is CancellationError {
                        self.status = "已取消连接操作，可刷新当前登录状态"
                    } else {
                        if action == .refresh { self.state = .unknown; self.lastTested = nil }
                        self.status = "连接操作未完成"
                        self.error = (error as? CodexConnectionFailure)?.message ?? "Codex 连接操作失败，请检查网络后重试。"
                    }
                }
            }
        }
    }

    fileprivate static func authenticationState(code: Int32, text: String) -> State {
        let text = text.lowercased()
        if code == 0, text.contains("logged in using chatgpt") { return .chatGPT }
        if code == 0, text.contains("api key") || text.contains("api-key") { return .apiKey }
        if text.contains("not logged in") || text.contains("not authenticated") { return .signedOut }
        return .unknown
    }

    /// Only expose the initial authorization URL; never expose callback codes or tokens from diagnostics.
    fileprivate static func authorizationURL(in output: String) -> URL? {
        guard let regex = try? NSRegularExpression(pattern: "https://auth\\.openai\\.com/[^\\s<>\\\"']+") else { return nil }
        let source = output as NSString
        for match in regex.matches(in: output, range: NSRange(location: 0, length: source.length)) {
            let value = source.substring(with: match.range).trimmingCharacters(in: CharacterSet(charactersIn: ").,;"))
            guard let url = URL(string: value), let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme == "https", components.host == "auth.openai.com",
                  components.user == nil, components.password == nil, components.port == nil || components.port == 443,
                  ["/authorize", "/oauth/authorize"].contains(components.path), components.fragment == nil else { continue }
            let blocked = Set(["code", "token", "access_token", "id_token", "refresh_token"])
            guard !(components.queryItems ?? []).contains(where: { blocked.contains($0.name.lowercased()) }) else { continue }
            return url
        }
        return nil
    }

    deinit { operation?.cancel() }
}

/// CPU-only regression checks. Login is exercised only through an isolated fake CLI.
enum CodexConnectionSelfTest {
    @MainActor static func run() async throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw CodexConnectionFailure("连接自测失败：\(name)") }
            checks += 1
        }
        try check(CodexConnection.authenticationState(code: 0, text: "Logged in using ChatGPT") == .chatGPT, "ChatGPT 状态")
        try check(CodexConnection.authenticationState(code: 0, text: "Logged in using an API key") == .apiKey, "API Key 状态")
        try check(CodexConnection.authenticationState(code: 1, text: "Not logged in") == .signedOut, "未登录状态")
        try check(CodexConnection.authenticationState(code: 1, text: "configuration failed") == .unknown, "异常不伪装未登录")
        try check(CodexConnection.authorizationURL(in: "Open https://auth.openai.com/oauth/authorize?response_type=code&code_challenge=synthetic&state=synthetic") != nil, "官方初始授权URL")
        try check(CodexConnection.authorizationURL(in: "https://auth.openai.com/oauth/authorize?access_token=synthetic") == nil, "拒绝tokenURL")
        try check(CodexConnection.authorizationURL(in: "https://auth.openai.com/oauth/authorize?code=synthetic") == nil, "拒绝授权回调code")
        try check(CodexConnection.authorizationURL(in: "https://auth.openai.com.example.org/oauth/authorize?state=synthetic") == nil, "拒绝伪造域名")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CourseRecorder-Connection-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("fake-codex")
        func install(status: String = "Logged in using ChatGPT", statusCode: Int = 0, body: String = "exit 0", login: String = "exit 0") throws {
            let script = """
            #!/bin/sh
            if [ "$1" = login ]; then
              if [ "$2" = status ]; then
                printf '%s\\n' '\(status)'
                exit \(statusCode)
              fi
              \(login)
            fi
            \(body)
            """
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        func wait(_ connection: CodexConnection) async throws {
            // Public entry points marshal to main; give their initial update a chance to run.
            try await Task.sleep(nanoseconds: 30_000_000)
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while connection.isBusy, ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 30_000_000) }
            guard !connection.isBusy else { connection.cancel(); throw CodexConnectionFailure("连接自测等待超时") }
        }
        let connection = CodexConnection(executable: cli, loginTimeout: 0.5, testTimeout: 0.3)
        try install()
        connection.refresh()
        try await wait(connection)
        try check(connection.isChatGPT && connection.error == nil && connection.lastTested == nil, "刷新不宣称已测试")
        try install(status: "Logged in using an API key")
        connection.testConnection()
        try await wait(connection)
        try check(connection.state == .apiKey && connection.lastTested == nil && connection.error?.contains("API Key") == true, "API Key不能测试")
        try install(status: "Not logged in", statusCode: 1)
        connection.refresh()
        try await wait(connection)
        try check(connection.state == .signedOut && !connection.isConnected, "刷新未登录")
        try install(body: """
        while [ "$#" -gt 0 ]; do
          if [ "$1" = -o ]; then
            shift
            printf '%s' '{"ok":true}' > "$1"
            exit 0
          fi
          shift
        done
        exit 1
        """)
        connection.testConnection()
        try await wait(connection)
        try check(connection.isConnected && connection.lastTested != nil && connection.error == nil, "成功测试状态")
        try install(body: "exec /bin/sleep 30")
        connection.testConnection()
        try await wait(connection)
        try check(connection.error?.contains("超时") == true && connection.lastTested == nil, "测试超时不保留旧成功")
        try install(login: "printf '%s\\n' 'https://auth.openai.com/oauth/authorize?state=synthetic&response_type=code'\nexec /bin/sleep 30")
        let login = CodexConnection(executable: cli)
        login.login()
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(login.isLoggingIn && login.loginURL != nil, "等待浏览器并提供官方URL")
        login.cancel()
        try await wait(login)
        try check(!login.isBusy && !login.isLoggingIn && login.loginURL == nil && login.error == nil, "取消登录清理")
        connection.login()
        try await wait(connection)
        try check(connection.error?.contains("超时") == true && !connection.isLoggingIn && connection.loginURL == nil, "登录超时清理")
        try install()
        connection.login()
        try await wait(connection)
        try check(connection.isChatGPT && connection.error == nil && !connection.isLoggingIn, "登录后自动刷新")
        try install(status: "configuration failed", statusCode: 1)
        connection.refresh()
        try await wait(connection)
        try check(connection.state == .unknown && connection.error != nil && !connection.isConnected, "状态检查失败不保留已连接")
        let missing = CodexConnection(executable: folder.appendingPathComponent("missing"))
        missing.refresh()
        try await wait(missing)
        try check(missing.state == .missingCLI && missing.error?.contains("ChatGPT") == true, "缺少CLI安装提示")
        return checks
    }
}

private struct CodexConnectionFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A single cancellable child process at a time. No token files are read, copied, or changed by this wrapper.
private final class CodexConnectionOperation: @unchecked Sendable {
    struct Output { var code: Int32; var output: String }
    private let executable: URL
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent("CourseRecorder-Connection-\(UUID().uuidString)")
    private let lock = NSLock()
    private var cancelled = false
    private var process: Process?

    init(executable: URL) { self.executable = executable }
    func prepare() throws {
        try checkCancellation()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    func cleanup() { try? FileManager.default.removeItem(at: directory) }
    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }
    private func checkCancellation() throws {
        lock.lock()
        let value = cancelled
        lock.unlock()
        if value { throw CancellationError() }
    }

    func run(arguments: [String], name: String, timeout: TimeInterval, timeoutMessage: String,
             input: String = "", loginLink: ((URL) -> Void)? = nil) throws -> Output {
        try checkCancellation()
        let out = directory.appendingPathComponent(name + ".out")
        let err = directory.appendingPathComponent(name + ".err")
        let stdin = directory.appendingPathComponent(name + ".in")
        try Data().write(to: out)
        try Data().write(to: err)
        try Data(input.utf8).write(to: stdin)
        let outputHandle = try FileHandle(forWritingTo: out), errorHandle = try FileHandle(forWritingTo: err)
        let inputHandle = try FileHandle(forReadingFrom: stdin)
        defer { try? outputHandle.close(); try? errorHandle.close(); try? inputHandle.close() }
        let child = Process()
        child.executableURL = executable
        child.arguments = arguments
        child.currentDirectoryURL = directory
        child.environment = AIShotPlanner.cliEnvironment()
        child.standardInput = inputHandle
        child.standardOutput = outputHandle
        child.standardError = errorHandle
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        process = child
        do { try child.run() }
        catch { process = nil; lock.unlock(); throw CodexConnectionFailure("无法启动 Codex，请安装或更新 ChatGPT 桌面版。") }
        lock.unlock()
        defer { lock.lock(); process = nil; lock.unlock() }
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var linkFound = false
        var failure: Error?
        while child.isRunning {
            do { try checkCancellation() } catch { failure = error; break }
            if ProcessInfo.processInfo.systemUptime >= deadline { failure = CodexConnectionFailure(timeoutMessage); break }
            let size = [out, err].reduce(0) {
                $0 + (((try? FileManager.default.attributesOfItem(atPath: $1.path))?[.size] as? NSNumber)?.intValue ?? 0)
            }
            if size > 2_000_000 { failure = CodexConnectionFailure("Codex 返回内容异常过大，已停止本次操作，请重试。"); break }
            if !linkFound, let loginLink,
               let url = CodexConnection.authorizationURL(in: read(out) + "\n" + read(err)) {
                linkFound = true
                loginLink(url)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        if let failure {
            if child.isRunning { child.terminate() }
            let grace = ProcessInfo.processInfo.systemUptime + 1
            while child.isRunning, ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { kill(child.processIdentifier, SIGKILL) }
            child.waitUntilExit()
            throw failure
        }
        child.waitUntilExit()
        try checkCancellation()
        return Output(code: child.terminationStatus, output: read(out) + "\n" + read(err))
    }

    private func read(_ url: URL) -> String {
        guard let file = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? file.close() }
        return String(decoding: (try? file.read(upToCount: 2_000_001)) ?? Data(), as: UTF8.self)
    }

    func test(timeout: TimeInterval) throws {
        let schema = directory.appendingPathComponent("schema.json")
        let result = directory.appendingPathComponent("result.json")
        try Data(#"{"type":"object","additionalProperties":false,"properties":{"ok":{"type":"boolean","enum":[true]}},"required":["ok"]}"#.utf8).write(to: schema)
        let output = try run(arguments: ["exec", "--ignore-user-config", "-s", "read-only", "--skip-git-repo-check", "--ephemeral",
            "-c", "forced_login_method=\"chatgpt\"", "-c", "model_provider=\"openai\"",
            "-c", "features.shell_tool=false", "-c", "features.shell_snapshot=false", "-c", "web_search=\"disabled\"",
            "-c", "project_doc_max_bytes=0", "-c", "history.persistence=\"none\"",
            "--color", "never", "--output-schema", schema.path, "-o", result.path, "-"], name: "test", timeout: timeout,
            timeoutMessage: "连接测试超时，请检查网络和 Codex 可用额度后重试。",
            input: "Connection check only. Return {\"ok\":true}. Do not use tools, access files, or browse.")
        guard output.code == 0 else {
            let message = output.output.lowercased()
            if message.contains("rate limit") || message.contains("usage limit") || message.contains("quota") {
                throw CodexConnectionFailure("ChatGPT / Codex 当前额度暂不可用，请查看 Codex 额度并稍后重试。")
            }
            if message.contains("401") || message.contains("unauthorized") || message.contains("authentication") {
                throw CodexConnectionFailure("ChatGPT 登录可能已失效，请重新连接并授权后再测试。")
            }
            throw CodexConnectionFailure("连接测试未通过，请检查网络、ChatGPT 登录和 Codex 可用额度后重试。")
        }
        struct Response: Decodable { var ok: Bool }
        guard let size = (try? FileManager.default.attributesOfItem(atPath: result.path))?[.size] as? NSNumber,
              size.intValue > 0, size.intValue < 4096, let data = try? Data(contentsOf: result),
              (try? JSONDecoder().decode(Response.self, from: data).ok) == true else {
            throw CodexConnectionFailure("Codex 已响应，但连接测试结果无效，请重试。")
        }
    }
}
