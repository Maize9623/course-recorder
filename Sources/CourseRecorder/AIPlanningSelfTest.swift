import Foundation
import CoreGraphics

/// CPU-only checks; no camera, media reader, GPU, AppState, or private course content.
enum AIPlanningSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run() throws -> Int {
        var passed = 0
        func check(_ condition: @autoclosure () -> Bool, _ name: String) throws {
            guard condition() else { throw Failure(message: "AI 自测失败：\(name)") }
            passed += 1
        }
        func event(_ time: Double, _ action: String, _ value: Any) -> [String: Any] {
            var e: [String: Any] = ["time": time, "action": action, "reason": "合成测试",
                                   "scene": NSNull(), "slide": NSNull(), "source": NSNull(), "enabled": NSNull()]
            let field = ["scene": "scene", "slide": "slide", "demoSource": "source", "pip": "enabled", "zoom": "enabled"][action] ?? "scene"
            e[field] = value
            return e
        }
        func data(_ events: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["summary": "合成测试", "warnings": [], "cues": events])
        }
        func take(_ source: SourceRef, _ start: Double, _ end: Double) -> Take {
            Take(file: "synthetic.mp4", source: source, start: start, end: end, width: 100, height: 100,
                 contentRect: CGRect(x: 0, y: 0, width: 100, height: 100))
        }
        var p = CourseProject(name: "AI 纯数据自测")
        p.narrationFile = "synthetic.mp4"
        p.narrationDuration = 20
        p.takes = [take(.display(1), 0, 20)]
        func valid(_ events: [[String: Any]], project: CourseProject? = nil, pages: Int = 2,
                   split: SplitContent = .slides) throws -> AIShotDraft {
            try AIShotPlanner.validate(data: data(events), project: project ?? p, pageCount: pages, splitContent: split)
        }
        func rejects(_ name: String, _ events: [[String: Any]], project: CourseProject? = nil,
                     pages: Int = 2, split: SplitContent = .slides) throws {
            do { _ = try valid(events, project: project, pages: pages, split: split) }
            catch is AIShotPlanner.PlanningError { passed += 1; return }
            throw Failure(message: "AI 自测未拒绝：\(name)")
        }
        let camera = [event(0, "scene", "camera")]
        let simple = try valid(camera)
        try check(simple.cues.contains { $0.time == 0 && $0.action == .slidesSource(.slides) }, "固定讲解课件源")
        try check(simple.review.map(\.id) == simple.cues.map(\.id), "审核行绑定同一 cue")
        let demo = [event(0, "scene", "demo"), event(0, "demoSource", "display:1")]
        _ = try valid(demo); passed += 1
        _ = try valid([event(0, "scene", "slides"), event(0, "slide", 1), event(0, "pip", true)]); passed += 1
        try rejects("同一操作同一时刻", camera + [event(0, "scene", "slides")])
        try rejects("相邻同类标记会互相替换", camera + [event(0.01, "scene", "slides")])
        try rejects("倒序", camera + [event(10, "slide", 0), event(9, "slide", 1)])
        try rejects("负时间", [event(-1, "scene", "camera")])
        try rejects("结束时间不再有输出帧", camera + [event(20, "scene", "camera")])
        try rejects("无开场", [event(1, "scene", "camera")])
        try rejects("越界页码", camera + [event(1, "slide", 2)])
        try rejects("负页码", camera + [event(1, "slide", -1)])
        try rejects("无课件时讲解", [event(0, "scene", "slides")], pages: 0)
        try rejects("无课件时讲解分屏", [event(0, "scene", "split")], pages: 0)
        try rejects("未知源", [event(0, "scene", "demo"), event(0, "demoSource", "display:99")])
        try rejects("未指定演示源", [event(0, "scene", "demo")])
        var gap = p
        gap.takes = [take(.display(1), 0, 8), take(.display(1), 10, 20)]
        try rejects("素材中间空两秒", demo, project: gap)
        try rejects("演示分屏中间空两秒", [event(0, "scene", "split"), event(0, "demoSource", "display:1")], project: gap, split: .demo)
        _ = try valid(demo + [event(8, "scene", "camera"), event(10, "scene", "demo")], project: gap); passed += 1
        var overlap = p
        overlap.takes.append(take(.window(2), 6, 12))
        try rejects("后录素材遮盖原来源", demo, project: overlap)
        _ = try valid(demo + [event(6, "demoSource", "window:2"), event(12, "demoSource", "display:1")], project: overlap); passed += 1
        var adjacent = p
        adjacent.takes = [take(.display(1), 0, 5), take(.display(1), 5, 20)]
        _ = try valid(demo, project: adjacent); passed += 1
        var endsEarly = p
        endsEarly.takes = [take(.display(1), 0, 19.99)]
        try rejects("末尾短缺口", demo, project: endsEarly)
        let env = AIShotPlanner.cliEnvironment(["HOME": "/synthetic", "CODEX_HOME": "/synthetic/codex", "CODEX_API_KEY": "test",
                                              "OPENAI_API_KEY": "test", "AZURE_OPENAI_API_KEY": "test", "CODEX_ACCESS_TOKEN": "test",
                                              "OPENAI_BASE_URL": "https://invalid.example", "HTTPS_PROXY": "https://proxy.example"])
        try check(env.count == 3 && env["CODEX_API_KEY"] == nil && env["CODEX_ACCESS_TOKEN"] == nil, "不继承凭据和 API endpoint 覆盖")
        return passed
    }

    /// Exercise process cancellation, timeout, auth refusal, and output draining using an isolated fake CLI.
    static func runProcessChecks() async throws -> Int {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CourseRecorder-AI-process-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("fake-codex")
        var project = CourseProject(name: "合成进程自测")
        project.narrationFile = "synthetic.mp4"
        project.narrationDuration = 10
        let transcript = [AITranscriptSegment(time: 0, duration: 9, text: "这是合成测试文字。")]
        func install(_ body: String, auth: String = "Logged in using ChatGPT") throws {
            let script = "#!/bin/sh\nif [ \"$1\" = login ]; then\n  printf '%s\\n' '\(auth)'\n  exit 0\nfi\n" + body + "\n"
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        try install("exec /bin/sleep 30")
        let cancelled = AIShotPlanner(executable: cli)
        let task = Task { try await cancelled.generate(project: project, transcript: transcript, splitContent: .slides, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; throw Failure(message: "取消没有结束进程") }
        catch is CancellationError { }
        guard ProcessInfo.processInfo.systemUptime - start < 3 else { throw Failure(message: "取消过程超过 3 秒") }
        let timeout = AIShotPlanner(executable: cli, timeout: 0.2)
        do {
            _ = try await timeout.generate(project: project, transcript: transcript, splitContent: .slides, progress: { _ in })
            throw Failure(message: "超时没有结束进程")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("超时") else { throw error }
        }
        try install("exit 99", auth: "Logged in using an API key")
        do {
            _ = try await AIShotPlanner(executable: cli).generate(project: project, transcript: transcript, splitContent: .slides, progress: { _ in })
            throw Failure(message: "未拒绝 API Key 登录")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("不接受 API Key") else { throw error }
        }
        try install("exec /usr/bin/yes synthetic-output")
        do {
            _ = try await AIShotPlanner(executable: cli, timeout: 3).generate(project: project, transcript: transcript, splitContent: .slides, progress: { _ in })
            throw Failure(message: "未限制超大输出")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("过大") else { throw error }
        }
        try install("exec /usr/bin/yes synthetic-error >&2")
        do {
            _ = try await AIShotPlanner(executable: cli, timeout: 3).generate(project: project, transcript: transcript, splitContent: .slides, progress: { _ in })
            throw Failure(message: "未限制超大错误输出")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("过大") else { throw error }
        }
        return 5
    }

    /// Explicit opt-in smoke test: sends synthetic text only through the user's ChatGPT login.
    static func runLive() async throws -> AIShotDraft {
        var project = CourseProject(name: "合成 AI 镜头测试")
        project.narrationFile = "synthetic.mp4"
        project.narrationDuration = 24
        project.takes = [Take(file: "synthetic-take.mp4", source: .display(1), start: 8, end: 16, width: 100, height: 100,
                              contentRect: CGRect(x: 0, y: 0, width: 100, height: 100))]
        let segments = [AITranscriptSegment(time: 0, duration: 7, text: "今天介绍如何建立一个学习文件夹，先听我介绍目标。"),
                        AITranscriptSegment(time: 8, duration: 7, text: "现在看屏幕上的演示，建立文件夹并将文件拖入。"),
                        AITranscriptSegment(time: 16, duration: 7, text: "回到讲师画面，总结三个步骤。")]
        return try await AIShotPlanner().generate(project: project, transcript: segments, splitContent: .slides,
                                                  progress: { print("AI 合成测试：\($0)") })
    }
}
