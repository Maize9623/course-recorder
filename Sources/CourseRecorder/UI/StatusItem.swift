import AppKit
import Combine

/// Menu bar icon: always reachable even when the control bar and main window are hidden. Turns red while recording.
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item: NSStatusItem
    private weak var app: AppState?
    private weak var bar: ControlBarController?
    private var cancellable: AnyCancellable?
    var onShowMain: (() -> Void)?

    init(app: AppState, bar: ControlBarController) {
        self.app = app
        self.bar = bar
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon(.idle)
        cancellable = app.$recState.receive(on: DispatchQueue.main).sink { [weak self] s in self?.updateIcon(s) }
    }

    private func updateIcon(_ s: RecState) {
        let name = s.isActive ? "record.circle.fill" : "video.circle"
        let image = NSImage(systemSymbolName: name, accessibilityDescription: "课程录制工具")
        image?.isTemplate = true
        item.button?.image = image
        item.button?.contentTintColor = s == .recording ? .systemRed : (s == .paused ? .systemOrange : nil)
        item.button?.toolTip = s.isActive ? "课程录制工具 · 录制中" : "课程录制工具"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let app else { return }
        let barVisible = bar?.isVisible ?? false
        let key = app.settings.combo(for: .controlBar).display
        add(menu, barVisible ? "隐藏悬浮控制条（\(key)）" : "显示悬浮控制条（\(key)）", #selector(toggleBar))
        if barVisible {
            add(menu, app.settings.controlBarCollapsed ? "展开控制条" : "收起成小按钮", #selector(toggleCollapse))
        }
        menu.addItem(.separator())
        switch app.recState {
        case .recording, .paused:
            add(menu, "停止并保存录制", #selector(toggleRecording))
            add(menu, app.recState == .paused ? "继续录制" : "暂停录制", #selector(togglePause))
        case .countdown:
            add(menu, "取消倒计时", #selector(toggleRecording))
        case .finishing:
            add(menu, "正在保存…", nil)
        case .idle:
            add(menu, "开始录制", #selector(toggleRecording))
        }
        menu.addItem(.separator())
        add(menu, "打开主窗口", #selector(showMain))
        add(menu, "提词器", #selector(toggleTeleprompter))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出课程录制工具", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        menu.addItem(quit)
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector?) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: "")
        mi.target = action == nil ? nil : self
        mi.isEnabled = action != nil
        menu.addItem(mi)
    }

    @objc private func toggleBar() { bar?.toggle() }
    @objc private func toggleCollapse() { app?.settings.controlBarCollapsed.toggle() }
    @objc private func toggleRecording() { app?.toggleRecording() }
    @objc private func togglePause() { app?.togglePause() }
    @objc private func showMain() { onShowMain?() }
    @objc private func toggleTeleprompter() { app?.onTeleprompter?(.toggleVisible) }
}
