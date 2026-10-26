import AppKit

let arguments = CommandLine.arguments
if let i = arguments.firstIndex(of: "--meeting-output-test") {
    guard i + 1 < arguments.count, !arguments[i + 1].hasPrefix("--") else {
        print("Usage: CourseRecorder --meeting-output-test <dir> --no-capture")
        exit(1)
    }
    var result: Int32?
    Task { @MainActor in
        do {
            let count = try await MeetingOutputSelfTest.run(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Meeting output: \(count) checks passed")
            result = 0
        } catch {
            print("Meeting output test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if arguments.contains("--presenter-tracking-test") {
    do {
        print("Presenter tracking: \(try PresenterTrackingSelfTest.runCPU()) CPU checks passed")
        exit(0)
    } catch {
        print("Presenter tracking CPU test failed: \(error.localizedDescription)")
        exit(1)
    }
}
if let i = arguments.firstIndex(of: "--output-format-state-test"), i + 1 < arguments.count {
    var result: Int32?
    Task { @MainActor in
        do {
            let count = try await OutputFormatStateSelfTest.run(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Output format state: \(count) checks passed")
            result = 0
        } catch {
            print("Output format state test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if arguments.contains("--output-aspect-cpu-test") {
    do {
        print("Output aspect: \(try OutputAspectSelfTest.runCPU()) CPU checks passed")
        exit(0)
    } catch {
        print("Output aspect CPU test failed: \(error.localizedDescription)")
        exit(1)
    }
}
if let i = arguments.firstIndex(of: "--output-aspect-test"), i + 1 < arguments.count {
    var result: Int32?
    Task {
        do {
            let count = try await OutputAspectSelfTest.runMedia(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Output aspect: \(count) checks passed")
            result = 0
        } catch {
            print("Output aspect test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if arguments.contains("--device-quick-toggle-test") {
    do {
        print("Device quick toggles: \(try DeviceQuickToggleSelfTest.runCPU()) CPU checks passed")
        exit(0)
    } catch {
        print("Device quick toggle test failed: \(error.localizedDescription)")
        exit(1)
    }
}
if let i = arguments.firstIndex(of: "--device-quick-toggle-media-test"), i + 1 < arguments.count {
    var result: Int32?
    Task { @MainActor in
        do {
            let count = try await DeviceQuickToggleSelfTest.runMedia(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Device quick toggles: \(count) media checks passed")
            result = 0
        } catch {
            print("Device quick toggle media test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if let i = arguments.firstIndex(of: "--narration-import-preview-test"), i + 1 < arguments.count {
    var result: Int32?
    Task { @MainActor in
        do {
            let count = try await NarrationImportPreviewSelfTest.run(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Narration import preview: \(count) checks passed")
            result = 0
        } catch {
            print("Narration import preview test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if arguments.contains("--narration-edit-planner-test") || arguments.contains("--narration-edit-live-test") {
    var result: Int32?
    Task {
        do {
            let count = try NarrationEditPlanningSelfTest.run()
            let lifecycle = try await NarrationEditPlanningSelfTest.runProcessChecks()
            let subtitles = try NarrationEditMediaSelfTest.runCPU()
            let store = try NarrationEditStoreSelfTest.run()
            print("Narration edit: \(count) planning, \(lifecycle) process, \(subtitles) subtitle/timeline, \(store) transaction checks passed")
            if arguments.contains("--narration-edit-live-test") {
                let draft = try await NarrationEditPlanningSelfTest.runLive()
                print("ChatGPT live narration edit: \(draft.cuts.count) validated suggestions")
            }
            result = 0
        } catch { print("Narration edit test failed: \(error.localizedDescription)"); result = 1 }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if let i = arguments.firstIndex(of: "--narration-edit-media-test"), i + 1 < arguments.count {
    var result: Int32?
    Task {
        do {
            let count = try await NarrationEditMediaSelfTest.runMedia(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Narration edit media: \(count) checks passed")
            result = 0
        } catch { print("Narration edit media test failed: \(error.localizedDescription)"); result = 1 }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if let i = arguments.firstIndex(of: "--recording-merge-test"), i + 1 < arguments.count {
    var result: Int32?
    Task {
        do {
            let count = try await RecordingMergeSelfTest.run(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Recording merge: \(count) checks passed")
            result = 0
        } catch { print("Recording merge test failed: \(error.localizedDescription)"); result = 1 }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if arguments.contains("--project-music-test") {
    do {
        print("Project music: \(try ProjectMusicSelfTest.run()) checks passed")
        exit(0)
    } catch {
        print("Project music test failed: \(error.localizedDescription)")
        exit(1)
    }
}
if arguments.contains("--project-trash-test") {
    do {
        print("Project trash: \(try ProjectTrashSelfTest.run()) checks passed")
        exit(0)
    } catch {
        print("Project trash test failed: \(error.localizedDescription)")
        exit(1)
    }
}
if let i = arguments.firstIndex(of: "--narration-import-test"), i + 1 < arguments.count {
    var result: Int32?
    Task {
        do {
            let count = try await NarrationImportSelfTest.run(URL(fileURLWithPath: arguments[i + 1], isDirectory: true))
            print("Narration import: \(count) checks passed")
            result = 0
        } catch {
            print("Narration import test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if arguments.contains("--codex-connection-test") {
    var result: Int32?
    Task {
        do {
            let count = try await CodexConnectionSelfTest.run()
            print("Codex connection: \(count) CPU checks passed")
            result = 0
        } catch {
            print("Codex connection test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if arguments.contains("--ai-planner-test") || arguments.contains("--ai-planner-live-test") {
    var result: Int32?
    Task {
        do {
            let count = try AIPlanningSelfTest.run()
            let processCount = try await AIPlanningSelfTest.runProcessChecks()
            print("AI validation: \(count) checks; CLI lifecycle: \(processCount) checks passed")
            if arguments.contains("--ai-planner-live-test") {
                let draft = try await AIPlanningSelfTest.runLive()
                print("ChatGPT live planning: \(draft.cues.count) validated cues")
            }
            result = 0
        } catch {
            print("AI test failed: \(error.localizedDescription)")
            result = 1
        }
    }
    while result == nil { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    exit(result ?? 1)
}
if let i = arguments.firstIndex(of: "--selftest") {
    exit(SelfTest.run(Array(arguments[(i + 1)...])))
}
if let i = arguments.firstIndex(of: "--make-icon") {
    exit(IconMaker.run(Array(arguments[(i + 1)...])))
}
if let i = arguments.firstIndex(of: "--ui-snapshot") {
    exit(UISnapshot.run(Array(arguments[(i + 1)...])))
}
if arguments.contains("--capture-test") {
    exit(CaptureTest.run())
}
if let i = arguments.firstIndex(of: "--camera-bench"), i + 1 < arguments.count {
    exit(SelfTest.cameraBench(arguments[i + 1]))
}
if let i = arguments.firstIndex(of: "--writer-test"), i + 4 < arguments.count {
    exit(SelfTest.writerTest(arguments[i + 1], seconds: Double(arguments[i + 2]) ?? 7,
                             offset: Double(arguments[i + 3]) ?? 0, mode: arguments[i + 4]))
}
if let i = arguments.firstIndex(of: "--production-test"), i + 1 < arguments.count {
    exit(SelfTest.productionTest(arguments[i + 1], camImage: i + 2 < arguments.count ? arguments[i + 2] : nil,
                                 deck: i + 3 < arguments.count ? arguments[i + 3] : ""))
}
if let i = arguments.firstIndex(of: "--convert"), i + 1 < arguments.count {
    do {
        let pdf = try PresentationConverter.convert(URL(fileURLWithPath: arguments[i + 1]))
        print("converted: \(pdf.path), pages: \(SlideDeck(path: pdf.path)?.pageCount ?? 0)")
        exit(0)
    } catch {
        print("failed: \(error.localizedDescription)")
        exit(1)
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
