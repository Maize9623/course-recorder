import Foundation
import AppKit
import Carbon

/// System-wide hotkeys via Carbon, so they work while another app (the demo) is focused.
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var refs: [EventHotKeyRef] = []
    private var actions: [UInt32: HotkeyAction] = [:]
    private var handler: EventHandlerRef?
    var onAction: ((HotkeyAction) -> Void)?
    var suspended = false

    func install() {
        guard handler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            if status == noErr { HotkeyManager.shared.fire(hk.id) }
            return noErr
        }, 1, &spec, nil, &handler)
    }

    /// Registers the bindings and returns the actions that could not be registered (taken by another app).
    @discardableResult
    func register(_ bindings: [(HotkeyAction, KeyCombo)]) -> [HotkeyAction] {
        unregisterAll()
        var failed: [HotkeyAction] = []
        for (i, (action, combo)) in bindings.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: OSType(0x4352_5344), id: UInt32(i + 1))
            let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, id, GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref {
                refs.append(ref)
                actions[UInt32(i + 1)] = action
            } else {
                failed.append(action)
            }
        }
        return failed
    }

    func unregisterAll() {
        for r in refs { UnregisterEventHotKey(r) }
        refs.removeAll()
        actions.removeAll()
    }

    private func fire(_ id: UInt32) {
        guard !suspended, let a = actions[id] else { return }
        let cb = onAction
        DispatchQueue.main.async { cb?(a) }
    }
}

extension KeyCombo {
    static let unassigned = KeyCombo(keyCode: UInt32.max, modifiers: 0)
    var isUnassigned: Bool { keyCode == UInt32.max }

    var display: String {
        if isUnassigned { return "未设置" }
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyCombo.keyName(keyCode)
    }

    var hasModifier: Bool {
        modifiers & UInt32(controlKey | optionKey | cmdKey | shiftKey) != 0
    }

    init?(event: NSEvent) {
        guard event.type == .keyDown else { return nil }
        var m: UInt32 = 0
        let f = event.modifierFlags
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: m)
    }

    static let names: [Int: String] = [
        kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D", kVK_ANSI_E: "E", kVK_ANSI_F: "F",
        kVK_ANSI_G: "G", kVK_ANSI_H: "H", kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
        kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P", kVK_ANSI_Q: "Q", kVK_ANSI_R: "R",
        kVK_ANSI_S: "S", kVK_ANSI_T: "T", kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
        kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4",
        kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]", kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=",
        kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
        kVK_ANSI_Slash: "/", kVK_ANSI_Backslash: "\\", kVK_ANSI_Grave: "`",
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_PageUp: "PgUp", kVK_PageDown: "PgDn", kVK_Home: "Home", kVK_End: "End",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        kVK_F13: "F13", kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16",
    ]

    static func keyName(_ code: UInt32) -> String {
        names[Int(code)] ?? "#\(code)"
    }

    static let pageDown = KeyCombo(keyCode: UInt32(kVK_PageDown), modifiers: 0)
    static let pageUp = KeyCombo(keyCode: UInt32(kVK_PageUp), modifiers: 0)
}
