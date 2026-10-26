import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var app: AppState!
    private var mainWindow: NSWindow!
    private var controlBar: ControlBarController!
    private var teleprompter: TeleprompterController!
    private var program: ProgramWindowController?
    private var programCanvasObserver: AnyCancellable?
    private var keyMonitor: Any?
    private var statusItem: StatusItemController?
    private var termSource: DispatchSourceSignal?

    private func handleTerminationSignal() {
        app.cancelRecordingMerge()
        guard app.recState.isActive || app.recState == .finishing else {
            app.production.finishOperations { [weak self] in
                self?.app.shutdown()
                exit(0)
            }
            return
        }
        if app.recState.isActive { app.stopRecording(mergeSegments: false) }
        let deadline = Date().addingTimeInterval(8)
        func check() {
            if app.recState == .idle || Date() > deadline {
                app.shutdown()
                exit(0)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: check)
        }
        check()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        app = AppState()
        buildMenu()

        let visible = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1460, height: 920)
        let initial = NSSize(width: min(1460, visible.width - 40), height: min(920, visible.height - 30))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: initial),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "课程录制工具"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.058, blue: 0.075, alpha: 1)
        window.minSize = NSSize(width: min(1200, initial.width), height: min(760, initial.height))
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: MainView().environmentObject(app))
        window.setFrameAutosaveName("MainWindow")
        if !window.setFrameUsingName("MainWindow") { window.center() }
        mainWindow = window

        controlBar = ControlBarController(app: app)
        teleprompter = TeleprompterController(app: app)
        statusItem = StatusItemController(app: app, bar: controlBar)
        statusItem?.onShowMain = { [weak self] in self?.showMain() }
        app.onToggleControlBar = { [weak self] in self?.controlBar.toggle() }
        app.onTeleprompter = { [weak self] cmd in self?.teleprompter.handle(cmd) }
        app.onShowMainWindow = { [weak self] in self?.showMain() }
        app.onShowProgram = { [weak self] in self?.showProgram() }
        programCanvasObserver = app.$settings.map { $0.recording.outputSize }.removeDuplicates()
            .receive(on: DispatchQueue.main).sink { [weak self] size in self?.program?.updateCanvas(size) }

        app.start()
        window.makeKeyAndOrderFront(nil)
        if app.settings.controlBarVisible { controlBar.show() }

        // A plain `kill` (e.g. during updates) still finishes and saves an active recording before quitting.
        signal(SIGTERM, SIG_IGN)
        let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        term.setEventHandler { [weak self] in self?.handleTerminationSignal() }
        term.resume()
        termSource = term

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            (self?.app.handleLocalKey(e) ?? false) ? nil : e
        }
        // Global ← → are only taken while another app is in front (see AppState.registerHotkeys).
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.app.registerHotkeys()
            }
        }
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--auto-record"), i + 2 < args.count, let seconds = Double(args[i + 1]) {
            let folder = URL(fileURLWithPath: args[i + 2], isDirectory: true)
            let segment = i + 3 < args.count ? Double(args[i + 3]) : nil
            // Give the camera and screen streams a few seconds to come up first.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.app.runAutoRecordTest(seconds: seconds, folder: folder, segmentSeconds: segment)
            }
        }
        if let i = CommandLine.arguments.firstIndex(of: "--quit-after"), i + 1 < CommandLine.arguments.count,
           let s = Double(CommandLine.arguments[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + s) {
                print("smoke: scene=\(self.app.scene.rawValue) hotkeyFailures=\(self.app.hotkeyFailures.map(\.rawValue)) controlBar=\(self.controlBar.isVisible)")
                NSApp.terminate(nil)
            }
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMain()
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if app.recState == .finishing {
            app.cancelRecordingMerge()
            waitForFinish()
            return .terminateLater
        }
        guard app.recState.isActive else {
            if app.production.isLoaded || app.production.isFinishingTakes {
                app.production.finishOperations { NSApp.reply(toApplicationShouldTerminate: true) }
                return .terminateLater
            }
            return .terminateNow
        }
        let alert = NSAlert()
        alert.messageText = "正在录制中"
        alert.informativeText = "退出前会先停止并保存当前录制。"
        alert.addButton(withTitle: "保存并退出")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        app.stopRecording(mergeSegments: false)
        waitForFinish()
        return .terminateLater
    }

    private func waitForFinish() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            if self.app.recState == .idle {
                NSApp.reply(toApplicationShouldTerminate: true)
            } else {
                self.waitForFinish()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        app.shutdown()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }

    // MARK: - Windows

    @objc func showMain() {
        mainWindow.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func toggleControlBar() { controlBar.toggle() }
    @objc func toggleTeleprompter() { teleprompter.handle(.toggleVisible) }

    @objc func showProgram() {
        if program == nil {
            program = ProgramWindowController(engine: app.engine, canvas: app.settings.recording.outputSize)
        }
        program?.show()
    }

    @objc func toggleRecording() { app.toggleRecording() }
    @objc func togglePause() { app.togglePause() }
    @objc func chapterMarker() { app.addMarker(.chapter) }
    @objc func mistakeMarker() { app.addMarker(.mistake) }
    @objc func openFolder() { app.openRecordingFolder() }
    @objc func sceneCamera() { app.selectScene(.camera) }
    @objc func sceneSlides() { app.selectScene(.slides) }
    @objc func sceneDemo() { app.selectScene(.demo) }
    @objc func sceneSplit() { app.selectScene(.split) }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于课程录制工具", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏课程录制工具", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "隐藏其他", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "全部显示", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出课程录制工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "编辑")
        edit.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "拷贝", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let recItem = NSMenuItem()
        let rec = NSMenu(title: "录制")
        addItem(rec, "开始 / 停止录制", #selector(toggleRecording))
        addItem(rec, "暂停 / 继续", #selector(togglePause))
        rec.addItem(.separator())
        addItem(rec, "章节打点", #selector(chapterMarker))
        addItem(rec, "口误打点", #selector(mistakeMarker))
        rec.addItem(.separator())
        addItem(rec, "打开录制文件夹", #selector(openFolder))
        recItem.submenu = rec
        main.addItem(recItem)

        let sceneItem = NSMenuItem()
        let scenes = NSMenu(title: "镜头")
        addItem(scenes, "1 出镜", #selector(sceneCamera))
        addItem(scenes, "2 讲解", #selector(sceneSlides))
        addItem(scenes, "3 演示", #selector(sceneDemo))
        addItem(scenes, "4 分屏", #selector(sceneSplit))
        sceneItem.submenu = scenes
        main.addItem(sceneItem)

        let winItem = NSMenuItem()
        let win = NSMenu(title: "窗口")
        addItem(win, "主窗口", #selector(showMain), key: "0")
        addItem(win, "悬浮控制条", #selector(toggleControlBar))
        addItem(win, "提词器", #selector(toggleTeleprompter))
        addItem(win, "会议共享画面 / OBS", #selector(showProgram))
        win.addItem(.separator())
        win.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        winItem.submenu = win
        main.addItem(winItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    private func addItem(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "") {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        menu.addItem(item)
    }
}
