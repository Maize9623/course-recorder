import Foundation
import CoreGraphics
import CoreImage
import Carbon

// MARK: - Basic value types

struct RGBA: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double = 1

    static let white = RGBA(r: 1, g: 1, b: 1)
    static let violet = RGBA(r: 0.545, g: 0.361, b: 0.965)
    static let amber = RGBA(r: 1.0, g: 0.78, b: 0.22)
    static let chroma = RGBA(r: 0.0, g: 0.69, b: 0.25)

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var ciColor: CIColor { CIColor(red: r, green: g, blue: b, alpha: a, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!) ?? CIColor(red: r, green: g, blue: b, alpha: a) }
    func withAlpha(_ alpha: Double) -> RGBA { RGBA(r: r, g: g, b: b, a: alpha) }
}

enum SceneKind: String, Codable, CaseIterable, Identifiable {
    case camera, slides, demo, split

    var id: String { rawValue }
    var number: Int {
        switch self {
        case .camera: 1
        case .slides: 2
        case .demo: 3
        case .split: 4
        }
    }
    var title: String {
        switch self {
        case .camera: "出镜"
        case .slides: "讲解"
        case .demo: "演示"
        case .split: "分屏"
        }
    }
    var subtitle: String {
        switch self {
        case .camera: "人像全屏出镜"
        case .slides: "PPT + 左下角人像"
        case .demo: "屏幕实操 + 左下角人像"
        case .split: "内容在左 · 人像在右"
        }
    }
    var symbol: String {
        switch self {
        case .camera: "person.crop.rectangle.fill"
        case .slides: "rectangle.inset.bottomleft.filled"
        case .demo: "macwindow.on.rectangle"
        case .split: "rectangle.split.2x1.fill"
        }
    }
    var hasPIP: Bool { self == .slides || self == .demo }
}

/// A capture or content source. Encoded as a compact string, e.g. "display:1", "window:4242", "slides".
enum SourceRef: Hashable, Codable, Identifiable {
    case display(UInt32)
    case window(UInt32)
    case slides

    var id: String { key }

    var key: String {
        switch self {
        case .display(let id): "display:\(id)"
        case .window(let id): "window:\(id)"
        case .slides: "slides"
        }
    }

    var isCapture: Bool {
        if case .slides = self { return false }
        return true
    }

    init?(key: String) {
        if key == "slides" { self = .slides; return }
        let parts = key.split(separator: ":")
        guard parts.count == 2, let n = UInt32(parts[1]) else { return nil }
        switch parts[0] {
        case "display": self = .display(n)
        case "window": self = .window(n)
        default: return nil
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let v = SourceRef(key: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "bad source \(s)")
        }
        self = v
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

// MARK: - Camera & background

enum BackgroundMode: String, Codable, CaseIterable, Identifiable {
    case off, blur, image, color
    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: "原始画面"
        case .blur: "背景虚化"
        case .image: "虚拟背景"
        case .color: "纯色/绿幕"
        }
    }
}

enum SegmentationQuality: String, Codable, CaseIterable, Identifiable {
    case fast, balanced, accurate
    var id: String { rawValue }
    var title: String {
        switch self {
        case .fast: "流畅"
        case .balanced: "均衡"
        case .accurate: "精细"
        }
    }
}

struct CameraSettings: Codable, Equatable {
    var deviceID: String = ""
    /// Camera capture rate. 30 keeps background removal and beauty within the per-frame budget;
    /// the program output still renders at the recording frame rate (60).
    var frameRate: Int = 30
    var mirror: Bool = false
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var warmth: Double = 0
    var fullZoom: Double = 1.0
    var fullOffsetX: Double = 0
    var fullOffsetY: Double = 0
    var faceTracking: Bool = true
}

struct BackgroundSettings: Codable, Equatable {
    var mode: BackgroundMode = .image
    var preset: String = "studio-purple"
    var customImagePath: String = ""
    var blurAmount: Double = 22
    var imageDefocus: Double = 2
    var color: RGBA = .chroma
    var quality: SegmentationQuality = .balanced
    var edgeSmoothing: Double = 1.2
    /// Fill small holes inside the person (dark clothes, arms against the body).
    var fillHoles: Bool = true
    /// 0 = soft matte, 1 = hard matte: semi-transparent leftovers of the real background are pushed to 0 or 1.
    var matteClean: Double = 0.6
    /// Pulls the edge inwards (px at 1080p) to remove the halo of the real background.
    var edgeTighten: Double = 1.5
}

struct BeautySettings: Codable, Equatable {
    var enabled: Bool = true
    /// 磨皮
    var smooth: Double = 0.35
    /// 美白
    var whiten: Double = 0.25
    /// 红润
    var rosy: Double = 0.1
    /// 瘦脸
    var slim: Double = 0.15
    /// 大眼
    var eyes: Double = 0
    /// 清晰度
    var clarity: Double = 0.25

    var needsLandmarks: Bool { enabled && (slim > 0.01 || eyes > 0.01) }
}

enum PIPShape: String, Codable, CaseIterable, Identifiable {
    case circle, rounded, cutout
    var id: String { rawValue }
    var title: String {
        switch self {
        case .circle: "圆形"
        case .rounded: "圆角矩形"
        case .cutout: "抠像人物"
        }
    }
}

enum Corner: String, Codable, CaseIterable, Identifiable {
    case bottomLeft, bottomRight, topLeft, topRight
    var id: String { rawValue }
    var title: String {
        switch self {
        case .bottomLeft: "左下"
        case .bottomRight: "右下"
        case .topLeft: "左上"
        case .topRight: "右上"
        }
    }
    var isLeft: Bool { self == .bottomLeft || self == .topLeft }
    var isBottom: Bool { self == .bottomLeft || self == .bottomRight }
}

struct PIPSettings: Codable, Equatable {
    var shape: PIPShape = .circle
    var corner: Corner = .bottomLeft
    var size: Double = 0.19
    var margin: Double = 0.02
    var zoom: Double = 1.15
    var borderWidth: Double = 4
    var borderColor: RGBA = RGBA(r: 1, g: 1, b: 1, a: 0.92)
    var shadow: Bool = true
}

// MARK: - Scenes

enum ZoomMode: String, Codable, CaseIterable, Identifiable {
    case manual, autoOnClick
    var id: String { rawValue }
    var title: String {
        switch self {
        case .manual: "快捷键手动"
        case .autoOnClick: "点击自动放大"
        }
    }
}

enum PortraitDemoFraming: String, Codable, CaseIterable, Identifiable {
    case leftHalf, fit
    var id: String { rawValue }
    var title: String { self == .leftHalf ? "左半屏" : "完整屏" }
}

struct DemoSettings: Codable, Equatable {
    var backdrop: String = "lavender"
    var customBackdropPath: String = ""
    var padding: Double = 0.035
    var cornerRadius: Double = 0.011
    var shadow: Bool = true
    var sources: [SourceRef] = []
    var zoomFactor: Double = 1.8
    var zoomMode: ZoomMode = .manual
    var autoZoomHold: Double = 2.5
    var clickHighlight: Bool = true
    var showCursor: Bool = true
    var throttleInactive: Bool = true
    /// Horizontal position of the screen inside the free space: -1 left, 0 centered, 1 right.
    var contentAlign: Double = 0
    /// Slide the screen away from the presenter bubble while it is visible.
    var avoidPIP: Bool = false
    /// Source framing for portrait demos, including demo content inside a split scene.
    var portraitFraming: PortraitDemoFraming = .leftHalf
}

enum SlidesFit: String, Codable, CaseIterable, Identifiable {
    case fill, fit
    var id: String { rawValue }
    var title: String { self == .fill ? "铺满" : "完整显示" }
}

struct SlidesSettings: Codable, Equatable {
    /// `nil` means automatic: imported deck if any, otherwise the first display.
    var source: SourceRef? = nil
    var deckPath: String = ""
    var fit: SlidesFit = .fill
    var portraitFit: SlidesFit = .fit
    var clickerKeys: Bool = false
    /// ← → flip slides from any app while the imported slides are on screen.
    var arrowKeys: Bool = true
}

enum SplitContent: String, Codable, CaseIterable, Identifiable {
    case slides, demo
    var id: String { rawValue }
    var title: String { self == .slides ? "讲解内容" : "演示屏幕" }
}

struct SplitSettings: Codable, Equatable {
    var content: SplitContent = .slides
    var cameraOnRight: Bool = true
    /// Width of the presenter column, as a fraction of the frame.
    var personWidth: Double = 0.40
    /// Portrait framing is independent of the user's landscape column placement.
    var portraitCameraAtBottom: Bool = true
    var portraitPersonHeight: Double = 0.25
    /// Soft fade on the presenter column's inner edge, as a fraction of the frame width.
    var edgeSoftness: Double = 0.05
    /// Horizontal nudge of the presenter inside the column (fraction of the camera frame).
    var personOffset: Double = 0
    var personZoom: Double = 1
    var cutout: Bool = false
    /// Show the whole slide / screen on its own side. Off = content fills the frame behind the presenter.
    var fitContent: Bool = true
    /// Presenter as a rounded card instead of a full-height column.
    var cardStyle: Bool = false
}

enum TransitionStyle: String, Codable, CaseIterable, Identifiable {
    case smooth, push, fade, cut
    var id: String { rawValue }
    var title: String {
        switch self {
        case .smooth: "缩放淡入"
        case .push: "推移"
        case .fade: "交叉淡化"
        case .cut: "直切"
        }
    }
}

struct TransitionSettings: Codable, Equatable {
    var sceneDuration: Double = 0.7
    var sourceStyle: TransitionStyle = .push
    var sourceDuration: Double = 0.55
    var pipDuration: Double = 0.4
    var slideDuration: Double = 0.35
}

// MARK: - Audio

struct AudioSettings: Codable, Equatable {
    var micDeviceID: String = ""
    var micGainDB: Double = 0
    var highPass: Bool = true
    var noiseGate: Bool = true
    var gateThresholdDB: Double = -52
    var limiter: Bool = true
    var systemAudio: Bool = false
    var systemGainDB: Double = -6
    var avOffsetMs: Double = 0
    /// Delays audio by the measured camera latency so lips and voice line up.
    var autoSync: Bool = true
}

enum BGMLoopMode: String, Codable, CaseIterable, Identifiable {
    case playlist, single, once
    var id: String { rawValue }
    var title: String {
        switch self {
        case .playlist: "列表循环"
        case .single: "单曲循环"
        case .once: "播完停止"
        }
    }
}

struct BGMSettings: Codable, Equatable {
    var tracks: [String] = []
    var volumeDB: Double = -20
    var ducking: Bool = true
    var duckDB: Double = -10
    var loopMode: BGMLoopMode = .playlist
    var fadeSeconds: Double = 1.5
    var autoStart: Bool = false
    var monitor: Bool = false
    var monitorVolume: Double = 0.6
}

// MARK: - Overlays

struct OverlaySettings: Codable, Equatable {
    var watermarkEnabled: Bool = false
    var watermarkTitle: String = "WORK AGENT"
    var watermarkSubtitle: String = "入门课"
    var watermarkScenes: [SceneKind] = [.demo]
    var watermarkCorner: Corner = .topLeft
    var lowerThirdName: String = "你的名字"
    var lowerThirdTitle: String = "AI 协作系统课程主讲"
    var lowerThirdSeconds: Double = 6
    var accent: RGBA = .violet
    var clickColor: RGBA = .amber
}

// MARK: - Recording

enum OutputAspect: String, Codable, CaseIterable, Identifiable {
    case landscape, portrait
    var id: String { rawValue }
    var title: String { self == .landscape ? "横屏" : "竖屏" }
    var detail: String { self == .landscape ? "16:9" : "9:16" }
    var symbol: String { self == .landscape ? "rectangle" : "rectangle.portrait" }
    var ratio: CGFloat { self == .landscape ? 16.0 / 9.0 : 9.0 / 16.0 }
}

enum OutputResolution: String, Codable, CaseIterable, Identifiable {
    case p1080, p1440, p2160
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .p1080: CGSize(width: 1920, height: 1080)
        case .p1440: CGSize(width: 2560, height: 1440)
        case .p2160: CGSize(width: 3840, height: 2160)
        }
    }
    var title: String {
        switch self {
        case .p1080: "1080p"
        case .p1440: "2K 1440p"
        case .p2160: "4K 2160p"
        }
    }
}

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264, hevc
    var id: String { rawValue }
    var title: String { self == .h264 ? "H.264（兼容性最好）" : "HEVC / H.265（体积更小）" }
}

enum RecordingQuality: String, Codable, CaseIterable, Identifiable {
    case standard, high, ultra
    var id: String { rawValue }
    var title: String {
        switch self {
        case .standard: "标准"
        case .high: "高"
        case .ultra: "极高"
        }
    }
}

struct RecordingSettings: Codable, Equatable {
    var resolution: OutputResolution = .p1080
    var aspect: OutputAspect = .landscape
    var fps: Int = 60
    var codec: VideoCodec = .h264
    var quality: RecordingQuality = .high
    var folder: String = "~/Movies/课程录制"
    var filePrefix: String = "课程录制"
    var countdown: Int = 3
    var countdownSound: Bool = true
    /// A new file every this many minutes, so a crash loses at most one segment; 0 = one file.
    var segmentMinutes: Int = 10
    /// Preserve crash protection while recording, then deliver one validated movie on a normal stop.
    var mergeSegmentsOnStop = true

    var outputSize: CGSize {
        let size = resolution.size
        return aspect == .portrait ? CGSize(width: size.height, height: size.width) : size
    }

    var folderURL: URL {
        URL(fileURLWithPath: (folder as NSString).expandingTildeInPath, isDirectory: true)
    }

    /// Bits per second for the chosen output.
    var videoBitrate: Int {
        let base: Double
        switch quality {
        case .standard: base = 10
        case .high: base = 16
        case .ultra: base = 26
        }
        let resFactor: Double
        switch resolution {
        case .p1080: resFactor = 1
        case .p1440: resFactor = 1.75
        case .p2160: resFactor = 3.6
        }
        let fpsFactor = fps >= 50 ? 1.0 : 0.65
        let codecFactor = codec == .hevc ? 0.65 : 1.0
        return Int(base * resFactor * fpsFactor * codecFactor * 1_000_000)
    }
}

// MARK: - Teleprompter

struct TeleprompterSettings: Codable, Equatable {
    var text: String = "在这里粘贴你的讲稿。\n\n提词器窗口不会被录进视频，可以把它拖到摄像头正下方，眼神就不会飘。\n\n快捷键 ⌃⌥Y 开始/暂停滚动，滚轮可以手动调整位置。"
    var fontSize: Double = 34
    var speed: Double = 36
    var opacity: Double = 0.86
    var lineSpacing: Double = 10
}

// MARK: - Hotkeys

struct KeyCombo: Codable, Hashable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let ctrlOpt = UInt32(controlKey | optionKey)

    static func co(_ key: Int) -> KeyCombo { KeyCombo(keyCode: UInt32(key), modifiers: ctrlOpt) }
}

enum HotkeyAction: String, Codable, CaseIterable, Identifiable {
    case sceneCamera, sceneSlides, sceneDemo, sceneSplit
    case togglePIP, nextSource, toggleZoom
    case record, pause, marker, markerNG
    case bgm, lowerThird, slideNext, slidePrev
    case teleprompter, controlBar, micMute

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sceneCamera: "切换到 1 出镜"
        case .sceneSlides: "切换到 2 讲解"
        case .sceneDemo: "切换到 3 演示"
        case .sceneSplit: "切换到 4 分屏"
        case .togglePIP: "隐藏 / 显示小窗人像"
        case .nextSource: "切换当前镜头的画面来源"
        case .toggleZoom: "鼠标跟随放大"
        case .record: "开始 / 停止录制"
        case .pause: "暂停 / 继续录制"
        case .marker: "打点：章节标记"
        case .markerNG: "打点：口误待剪"
        case .bgm: "BGM 播放 / 暂停"
        case .lowerThird: "显示人名条"
        case .slideNext: "幻灯片下一页"
        case .slidePrev: "幻灯片上一页"
        case .teleprompter: "提词器 开始 / 暂停"
        case .controlBar: "显示 / 隐藏悬浮控制条"
        case .micMute: "麦克风静音"
        }
    }

    var defaultCombo: KeyCombo {
        switch self {
        case .sceneCamera: .co(kVK_ANSI_1)
        case .sceneSlides: .co(kVK_ANSI_2)
        case .sceneDemo: .co(kVK_ANSI_3)
        case .sceneSplit: .co(kVK_ANSI_4)
        case .togglePIP: .co(kVK_ANSI_V)
        case .nextSource: .co(kVK_ANSI_S)
        case .toggleZoom: .co(kVK_ANSI_Z)
        case .record: .co(kVK_ANSI_R)
        case .pause: .co(kVK_ANSI_P)
        case .marker: .co(kVK_ANSI_M)
        case .markerNG: .co(kVK_ANSI_N)
        case .bgm: .co(kVK_ANSI_B)
        case .lowerThird: .co(kVK_ANSI_L)
        case .slideNext: .co(kVK_ANSI_RightBracket)
        case .slidePrev: .co(kVK_ANSI_LeftBracket)
        case .teleprompter: .co(kVK_ANSI_Y)
        case .controlBar: .co(kVK_ANSI_H)
        case .micMute: .co(kVK_ANSI_A)
        }
    }

    static var defaults: [String: KeyCombo] {
        Dictionary(uniqueKeysWithValues: allCases.map { ($0.rawValue, $0.defaultCombo) })
    }
}

// MARK: - Root

struct AppSettings: Codable, Equatable {
    var camera = CameraSettings()
    var background = BackgroundSettings()
    var beauty = BeautySettings()
    var pip = PIPSettings()
    var demo = DemoSettings()
    var slides = SlidesSettings()
    var split = SplitSettings()
    var transitions = TransitionSettings()
    var audio = AudioSettings()
    var bgm = BGMSettings()
    var overlay = OverlaySettings()
    var recording = RecordingSettings()
    var teleprompter = TeleprompterSettings()
    var hotkeys: [String: KeyCombo] = HotkeyAction.defaults
    var showGuides: Bool = false
    var controlBarVisible: Bool = true
    /// Control bar shrunk to a small pill.
    var controlBarCollapsed: Bool = false
    var onboardingDone: Bool = false

    func combo(for action: HotkeyAction) -> KeyCombo {
        hotkeys[action.rawValue] ?? action.defaultCombo
    }
}

// MARK: - Persistence

enum SettingsStore {
    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("CourseRecorder", isDirectory: true)
    }

    static var fileURL: URL { directory.appendingPathComponent("settings.json") }

    static func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL) else { return AppSettings() }
        return decode(data)
    }

    /// Decode older settings by supplying defaults for newly introduced fields, without file I/O.
    static func decode(_ data: Data) -> AppSettings {
        let defaults = AppSettings()
        if let s = try? JSONDecoder().decode(AppSettings.self, from: data) { return s }
        // Older or partially incompatible file: overlay the saved values on top of the defaults
        // so that new fields get default values instead of discarding everything.
        guard let saved = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let defData = try? JSONEncoder().encode(defaults),
              let def = try? JSONSerialization.jsonObject(with: defData) as? [String: Any] else { return defaults }
        let merged = deepMerge(def, saved)
        if let mdata = try? JSONSerialization.data(withJSONObject: merged),
           let s = try? JSONDecoder().decode(AppSettings.self, from: mdata) {
            return s
        }
        return defaults
    }

    static func save(_ settings: AppSettings) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try enc.encode(settings)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            NSLog("[Settings] save failed: \(error)")
        }
    }

    private static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (k, v) in over {
            if let bv = base[k] as? [String: Any], let ov = v as? [String: Any] {
                out[k] = deepMerge(bv, ov)
            } else {
                out[k] = v
            }
        }
        return out
    }
}
