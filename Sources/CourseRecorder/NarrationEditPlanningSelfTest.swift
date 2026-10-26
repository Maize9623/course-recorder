import Foundation

/// Pure data / fake CLI tests. No user audio, Speech authorization, camera, GPU, or network.
enum NarrationEditPlanningSelfTest {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    static func run() throws -> Int {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw Failure(message: "口播剪辑规划检查失败：\(label)") }
            count += 1
        }
        func transcript(_ values: [(Double, Double, String)], duration: Double = 20) -> NarrationTranscript {
            NarrationTranscriber.transcript(words: values.map { NarrationSegment(time: $0.0, duration: $0.1, text: $0.2) }, duration: duration)
        }
        func suggestion(_ first: Int, _ last: Int, _ keptFirst: Int, _ keptLast: Int,
                        kind: String = "repetition", reason: String = "明确紧接着重说，保留后面的完整版本") -> [String: Any] {
            ["firstWord": first, "lastWord": last, "retainedFirstWord": keptFirst,
             "retainedLastWord": keptLast, "kind": kind, "reason": reason]
        }
        func data(_ cuts: [[String: Any]]) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["summary": "合成剪辑建议", "warnings": [], "cuts": cuts])
        }
        let words = transcript([(0.2, 0.4, "今天"), (0.8, 0.6, "介绍"), (1.6, 0.5, "今天"), (2.3, 0.6, "介绍"),
                                (3.0, 1.0, "学习方法。"), (5.0, 1.0, "第一步。"), (7, 1, "建立文件夹。")])
        func rejects(_ label: String, _ cuts: [[String: Any]], _ input: NarrationTranscript = words) throws {
            do { _ = try AINarrationEditPlanner.validate(data: data(cuts), transcript: input) }
            catch is AINarrationEditPlanner.Failure { count += 1; return }
            throw Failure(message: "未拒绝：\(label)")
        }
        let legacy = Data(#"{"duration":20,"segments":[{"time":0,"duration":1,"text":"旧版本"}]}"#.utf8)
        let decoded = try JSONDecoder().decode(NarrationTranscript.self, from: legacy)
        try check(decoded.words == nil, "旧句级JSON兼容")
        try rejects("旧文字稿无逐词时间", [], decoded)
        let draft = try AINarrationEditPlanner.validate(data: data([suggestion(0, 1, 2, 3)]), transcript: words)
        try check(draft.cuts.count == 1, "明确重复得到单片段")
        try check(abs(draft.cuts[0].start - 0.14) < 0.0001 && abs(draft.cuts[0].end - 1.46) < 0.0001, "切口只派生自词边界并保留气口")
        try check(draft.cuts[0].text == "今天介绍", "展示真实被删文字")
        try check(!draft.warnings.isEmpty, "审核提醒")
        let encodedDraft = try JSONEncoder().encode(draft)
        let restoredDraft = try JSONDecoder().decode(NarrationEditDraft.self, from: encodedDraft)
        try check(restoredDraft == draft, "剪辑草稿往返含固定ID")
        try rejects("负词ID", [suggestion(-1, 1, 2, 3)])
        try rejects("越界词ID", [suggestion(0, 99, 2, 3)])
        try rejects("反向范围", [suggestion(1, 0, 2, 3)])
        try rejects("保留范围必须在后", [suggestion(2, 3, 0, 1)])
        try rejects("没有相同保留内容", [suggestion(0, 1, 4, 4)])
        try rejects("拒绝任意观点剪辑类型", [suggestion(0, 1, 2, 3, kind: "incorrect-fact")])
        try rejects("理由为空", [suggestion(0, 1, 2, 3, reason: " ")])
        try rejects("相交重复删除", [suggestion(0, 1, 2, 3), suggestion(1, 1, 3, 3)])
        var overlap = words
        overlap.words![2].time = 1.3
        try rejects("相邻保留词跨越切口", [suggestion(0, 1, 2, 3)], overlap)
        var invalidTime = words
        invalidTime.words![0].time = -1
        try rejects("负词时间", [], invalidTime)
        invalidTime = words; invalidTime.words![0].duration = .infinity
        try rejects("非有限时间", [], invalidTime)
        invalidTime = words; invalidTime.words![0].duration = 0
        try rejects("零时长词不用于切口", [], invalidTime)
        invalidTime = words; invalidTime.words![0].time = 5
        try rejects("词时间倒序", [], invalidTime)
        invalidTime = words; invalidTime.words![0].duration = 21
        try rejects("词超出口播", [], invalidTime)
        let restart = transcript([(0, 1, "今天我们"), (1.1, 0.6, "介绍"), (1.8, 0.5, "重来"),
                                  (2.5, 1, "今天我们"), (3.6, 0.6, "介绍"), (4.3, 1, "工作流程。")])
        let restarted = try AINarrationEditPlanner.validate(data: data([suggestion(0, 2, 3, 5, kind: "restart")]), transcript: restart)
        try check(restarted.cuts.count == 1, "明确重来删除失败版本")
        let prefix = transcript([(0, 1, "今天我们介绍"), (1.2, 0.5, "呃"), (2, 1, "今天我们介绍完整课程。")])
        let prefixed = try AINarrationEditPlanner.validate(data: data([suggestion(0, 1, 2, 2, kind: "restart")]), transcript: prefix)
        try check(prefixed.cuts.count == 1, "明显相同开头的卡壳重说")
        try rejects("不相干观点不当作重说", [suggestion(0, 1, 4, 4, kind: "restart")])
        let allRemoved = transcript([(0, 7.1, "重复内容"), (7.2, 1, "重复内容")], duration: 10)
        try rejects("删除超过35%", [suggestion(0, 0, 1, 1)], allRemoved)
        let long = transcript([(0, 31, "重复内容"), (32, 1, "重复内容")], duration: 100)
        try rejects("单段超过30秒", [suggestion(0, 0, 1, 1)], long)
        let chained = transcript([(0, 1, "完整重复"), (1.3, 1, "完整重复"), (2.6, 1, "完整重复")])
        try rejects("保留版本也被删除", [suggestion(0, 0, 1, 1), suggestion(1, 1, 2, 2)], chained)
        let unchanged = try AINarrationEditPlanner.validate(data: data([]), transcript: words)
        try check(unchanged.cuts.isEmpty, "无明确失误不删")
        let pause = transcript([(0.1, 0.9, "开始。"), (5, 1, "继续。")])
        let paused = try AINarrationEditPlanner.validate(data: data([]), transcript: pause)
        try check(paused.cuts.count == 1 && paused.cuts[0].text == "（较长停顿）", "长停顿标为试听候选")
        try check(abs(paused.cuts[0].start - 1.4) < 0.0001 && abs(paused.cuts[0].end - 4.6) < 0.0001, "词间保留0.8秒正常气口")
        let tooLong = transcript([(0, 1, "开始。"), (16, 1, "继续。")])
        let longGap = try AINarrationEditPlanner.validate(data: data([]), transcript: tooLong)
        try check(longGap.cuts.isEmpty && longGap.warnings.contains { $0.contains("超过 12 秒") }, "过长识别空隙保守保留")
        let ordinaryPause = transcript([(0, 1, "开始。"), (3.4, 1, "继续。")])
        let ordinary = try AINarrationEditPlanner.validate(data: data([]), transcript: ordinaryPause)
        try check(ordinary.cuts.isEmpty, "正常短停顿保留")
        let shifted = NarrationTranscriber.transcript(words: [NarrationSegment(time: 0.14, duration: 0.5, text: "今天"),
                                                              NarrationSegment(time: 0.84, duration: 0.6, text: "介绍。")], duration: 3)
        try check(shifted.words?.count == 2 && shifted.segments.count == 1, "剪后逐词可重组句级字幕")
        try check(shifted.words?[0].time == 0.14 && shifted.segments[0].time == 0.14, "重分句保留剪后时间基底")
        let stutter = NarrationTranscriber.transcript(words: [NarrationSegment(time: 0, duration: 0.03, text: "我"),
                                                              NarrationSegment(time: 0.04, duration: 0.03, text: "我")], duration: 1)
        try check(stutter.words?.count == 2, "真实紧接的卡壳词不能当识别重叠去重")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CourseRecorder-Edit-Cache-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("synthetic.mp4")
        try Data("Synthetic identity only, no media is opened".utf8).write(to: source)
        try NarrationTranscriber.saveCache(transcript: shifted, url: source, projectFolder: folder)
        let cache = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(NarrationTranscriber.cacheFileName))) as! [String: Any]
        let identity = cache["source"] as! [String: Any]
        try check(identity["version"] as? Int == 2 && identity["fileName"] as? String == "synthetic.mp4", "v2缓存绑定剪后媒体身份")
        let cachedTranscript = try JSONDecoder().decode(NarrationTranscript.self, from: JSONSerialization.data(withJSONObject: cache["transcript"]!))
        try check(cachedTranscript == shifted, "缓存保留剪后文字和全部词时间")
        return count
    }

    static func runProcessChecks() async throws -> Int {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("CourseRecorder-Edit-CLI-Test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: folder) }
        let cli = folder.appendingPathComponent("fake-codex")
        let transcript = NarrationTranscriber.transcript(words: [NarrationSegment(time: 0, duration: 1, text: "合成测试。")], duration: 10)
        func install(_ body: String, auth: String = "Logged in using ChatGPT") throws {
            let script = "#!/bin/sh\nif [ \"$1\" = login ]; then\n  printf '%s\\n' '\(auth)'\n  exit 0\nfi\n" + body + "\n"
            try script.write(to: cli, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: cli.path)
        }
        try install("""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = -o ]; then shift; result="$1"; fi
          shift
        done
        printf '%s' '{"summary":"合成检查","warnings":[],"cuts":[]}' > "$result"
        """)
        let runner = AINarrationEditPlanner(executable: cli)
        let result = try await runner.generate(transcript: transcript, progress: { _ in })
        guard result.cuts.isEmpty else { throw Failure(message: "CLI结构化结果没有传递") }
        do {
            _ = try await runner.generate(transcript: transcript, progress: { _ in })
            throw Failure(message: "同一规划器被重复使用")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("已使用") else { throw error }
        }
        try install("exec /bin/sleep 30")
        let cancelled = AINarrationEditPlanner(executable: cli)
        let task = Task { try await cancelled.generate(transcript: transcript, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 400_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        task.cancel()
        do { _ = try await task.value; throw Failure(message: "取消没有结束剪辑CLI") }
        catch is CancellationError { }
        guard ProcessInfo.processInfo.systemUptime - start < 3 else { throw Failure(message: "取消超时") }
        do {
            _ = try await AINarrationEditPlanner(executable: cli, timeout: 0.2).generate(transcript: transcript, progress: { _ in })
            throw Failure(message: "超时没有结束剪辑CLI")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("超时") else { throw error }
        }
        try install("exit 99", auth: "Logged in using an API key")
        do {
            _ = try await AINarrationEditPlanner(executable: cli).generate(transcript: transcript, progress: { _ in })
            throw Failure(message: "未拒绝API Key登录")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("不接受 API Key") else { throw error }
        }
        try install("exec /usr/bin/yes synthetic-output")
        do {
            _ = try await AINarrationEditPlanner(executable: cli, timeout: 3).generate(transcript: transcript, progress: { _ in })
            throw Failure(message: "未限制输出大小")
        } catch let error as AIShotPlanner.PlanningError {
            guard error.message.contains("过大") else { throw error }
        }
        return 6
    }

    /// Explicit opt-in smoke test: only this synthetic text is sent through the ChatGPT subscription.
    static func runLive() async throws -> NarrationEditDraft {
        let tokens = ["今天介绍", "如何整理", "一节课程的资料。",
                      "首先", "新建", "学习文件夹，",
                      "首先", "新建", "学习文件夹。",
                      "然后", "把课程资料", "放进去。",
                      "第二步", "点击", "删除按钮，", "说错了，", "重新说。",
                      "第二步", "点击", "保存按钮，", "保留当前的学习计划。",
                      "完成后", "检查文件名称", "和保存的位置，", "本节课就结束了。"]
        let words = tokens.enumerated().map { index, text in
            NarrationSegment(time: 0.3 + Double(index) * 1.1, duration: 0.85, text: text)
        }
        let transcript = NarrationTranscriber.transcript(words: words, duration: 28)
        let draft = try await AINarrationEditPlanner().generate(transcript: transcript) {
            print("AI 口播剪辑合成测试：\($0)")
        }
        // These observations are about the fixed synthetic script, never a real user's correctness.
        guard draft.cuts.contains(where: { $0.text.contains("重新说") }),
              draft.cuts.contains(where: { $0.text.contains("学习文件夹") }),
              !draft.cuts.contains(where: { $0.text.contains("保存按钮") || $0.text.contains("本节课就结束了") }) else {
            throw Failure(message: "实际剪辑规划没有正确区分合成重复/重录与应保留内容，请检查保守策略。")
        }
        print("AI 口播剪辑合成测试：\(draft.cuts.count) 条建议通过范围与保留版本校验")
        for cut in draft.cuts {
            print(String(format: "  %.2f–%.2f 秒：%@", cut.start, cut.end, cut.reason))
        }
        return draft
    }

}
