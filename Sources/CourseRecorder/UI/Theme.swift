import SwiftUI
import AppKit
import Carbon

/// Local view state. The macOS 27 SDK implements `@State` as a macro that needs Xcode's plugins,
/// so views keep their local state in a `@StateObject` of this type instead.
final class ViewState<Value>: ObservableObject {
    @Published var value: Value
    init(_ value: Value) { self.value = value }
}

enum Theme {
    static let bg = Color(red: 0.055, green: 0.058, blue: 0.075)
    static let panel = Color(red: 0.082, green: 0.086, blue: 0.106)
    static let card = Color(red: 0.112, green: 0.117, blue: 0.145)
    static let cardHi = Color(red: 0.15, green: 0.155, blue: 0.195)
    static let stroke = Color.white.opacity(0.07)
    static let strokeHi = Color.white.opacity(0.14)
    static let text = Color.white.opacity(0.93)
    static let text2 = Color.white.opacity(0.6)
    static let text3 = Color.white.opacity(0.38)
    static let accent = Color(red: 0.545, green: 0.361, blue: 0.965)
    static let accentSoft = Color(red: 0.66, green: 0.55, blue: 0.98)
    static let red = Color(red: 1, green: 0.27, blue: 0.23)
    static let green = Color(red: 0.2, green: 0.82, blue: 0.4)
    static let amber = Color(red: 1, green: 0.76, blue: 0.2)
}

extension RGBA {
    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    init(color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent), a: Double(ns.alphaComponent))
    }
}

func colorBinding(_ b: Binding<RGBA>) -> Binding<Color> {
    Binding(get: { b.wrappedValue.color }, set: { b.wrappedValue = RGBA(color: $0) })
}

// MARK: - Containers

struct SectionCard<Content: View>: View {
    let title: String
    let icon: String
    var note: String? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.accentSoft)
                    .frame(width: 18)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
            }
            if let note {
                Text(note)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Theme.stroke))
    }
}

// MARK: - Rows

struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format: (Double) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.text2)
                Spacer()
                Text(format(value))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Theme.text3)
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(Theme.accent)
        }
    }
}

struct ToggleRow: View {
    let title: String
    var subtitle: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12)).foregroundStyle(Theme.text)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.text3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Toggle("", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
                .tint(Theme.accent)
        }
    }
}

struct LabeledRow<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 12)).foregroundStyle(Theme.text2)
            Spacer(minLength: 8)
            content
        }
    }
}

// MARK: - Buttons

enum ButtonTone { case primary, secondary, danger, ghost }

struct PillButtonStyle: ButtonStyle {
    var tone: ButtonTone = .secondary
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 11 : 12, weight: .medium))
            .padding(.horizontal, compact ? 9 : 12)
            .padding(.vertical, compact ? 5 : 7)
            .foregroundStyle(tone == .ghost ? Theme.text2 : Color.white)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(fill(configuration.isPressed))
            )
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(tone == .secondary || tone == .ghost ? Theme.stroke : .clear))
            .contentShape(Rectangle())
    }

    private func fill(_ pressed: Bool) -> Color {
        switch tone {
        case .primary: return Theme.accent.opacity(pressed ? 0.75 : 1)
        case .danger: return Theme.red.opacity(pressed ? 0.75 : 0.92)
        case .secondary: return Theme.cardHi.opacity(pressed ? 0.6 : 1)
        case .ghost: return Color.white.opacity(pressed ? 0.08 : 0.001)
        }
    }
}

struct KeyHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(Theme.text3)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.06)))
    }
}

struct ChipButton: View {
    let title: String
    var icon: String? = nil
    var active = false
    var hint: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11, weight: .semibold)) }
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                if let hint { KeyHint(text: hint) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .foregroundStyle(active ? Color.white : Theme.text2)
            .background(Capsule().fill(active ? Theme.accent.opacity(0.85) : Theme.card))
            .overlay(Capsule().stroke(active ? Theme.accentSoft.opacity(0.6) : Theme.stroke))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Meters

struct LevelMeter: View {
    let db: Float
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let v = CGFloat(max(0, min(1, (db + 60) / 60)))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [Theme.green, Theme.green, Theme.amber, Theme.red],
                                         startPoint: .leading, endPoint: .trailing))
                    .mask(alignment: .leading) {
                        Rectangle().frame(width: geo.size.width * v)
                    }
            }
        }
        .frame(height: height)
        .animation(.linear(duration: 0.08), value: db)
    }
}

// MARK: - Swatches

struct SwatchItem: View {
    let title: String
    let image: NSImage?
    let colors: [Color]
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack {
                    if let image {
                        Image(nsImage: image).resizable().aspectRatio(16 / 9, contentMode: .fill)
                    } else {
                        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
                .frame(height: 46)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(selected ? Theme.accentSoft : Theme.stroke, lineWidth: selected ? 2 : 1))
                Text(title)
                    .font(.system(size: 10.5))
                    .foregroundStyle(selected ? Theme.text : Theme.text2)
                    .lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Hotkey recorder

final class HotkeyRecorder: ObservableObject {
    @Published var recording = false
    var monitor: Any?
    /// True while any hotkey field waits for a key, so other key handlers stay out of the way.
    static var isRecording = false

    private static let standalone: Set<Int> = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8, kVK_F9, kVK_F10,
                                               kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19,
                                               kVK_F20, kVK_PageUp, kVK_PageDown]

    func start(app: AppState, action: HotkeyAction) {
        guard !recording else { return }
        recording = true
        Self.isRecording = true
        HotkeyManager.shared.unregisterAll()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak app] e in
            guard let self, let app else { return e }
            if Int(e.keyCode) == kVK_Escape {
                self.stop(app: app)
                return nil
            }
            if let combo = KeyCombo(event: e), combo.hasModifier || Self.standalone.contains(Int(combo.keyCode)) {
                app.setHotkey(action, combo)
                self.stop(app: app)
            }
            return nil
        }
    }

    func stop(app: AppState?) {
        guard recording || monitor != nil else { return }
        recording = false
        Self.isRecording = false
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil
        app?.registerHotkeys()
    }
}

struct HotkeyField: View {
    @EnvironmentObject var app: AppState
    let action: HotkeyAction
    @StateObject private var recorder = HotkeyRecorder()

    var body: some View {
        let failed = app.hotkeyFailures.contains(action)
        let recording = recorder.recording
        Button {
            recording ? recorder.stop(app: app) : recorder.start(app: app, action: action)
        } label: {
            Text(recording ? "按下组合键…" : app.settings.combo(for: action).display)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(recording ? Color.white : (failed ? Theme.amber : Theme.text))
                .frame(minWidth: 92)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .background(RoundedRectangle(cornerRadius: 6).fill(recording ? Theme.accent.opacity(0.8) : Theme.cardHi))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(failed ? Theme.amber.opacity(0.7) : Theme.stroke))
        }
        .buttonStyle(.plain)
        .help(failed ? "这个组合键被其他应用占用了，请换一个" : "点击后按下新的组合键（Esc 取消）")
        .onDisappear { recorder.stop(app: app) }
    }
}

// MARK: - AppKit bridges

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

func formatBytes(_ b: Int64) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    return f.string(fromByteCount: b)
}
