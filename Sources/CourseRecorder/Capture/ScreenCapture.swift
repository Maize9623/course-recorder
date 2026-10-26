import Foundation
import AppKit
import ScreenCaptureKit
import CoreMedia

struct CaptureSourceInfo: Identifiable, Hashable {
    let ref: SourceRef
    let name: String
    let detail: String
    let pixelSize: CGSize
    /// Global Quartz coordinates (points, top-left origin of the main display).
    let frame: CGRect
    /// False for windows on another desktop, minimized, or of a hidden app. They can still be captured, but a
    /// minimized window's picture only updates once it is restored.
    var onScreen = true
    var id: String { ref.key }
}

/// Manages ScreenCaptureKit streams for displays and windows. Our own windows are always excluded.
final class ScreenCaptureManager: NSObject, SCStreamDelegate, SCStreamOutput {
    private let store: FrameStore
    private let lock = NSLock()
    private var content: SCShareableContent?
    private var streams: [SourceRef: SCStream] = [:]
    private var configs: [SourceRef: SCStreamConfiguration] = [:]
    private var refsByStream: [ObjectIdentifier: SourceRef] = [:]
    private var infos: [SourceRef: CaptureSourceInfo] = [:]
    private var windowFrames: [UInt32: CGRect] = [:]
    private var audioStream: SCStream?
    private let frameQueue = DispatchQueue(label: "screen.frames", qos: .userInteractive)
    private let audioQueue = DispatchQueue(label: "screen.audio", qos: .userInteractive)
    private let controlQueue = DispatchQueue(label: "screen.control")
    private var windowTimer: DispatchSourceTimer?

    private(set) var displays: [CaptureSourceInfo] = []
    private(set) var windows: [CaptureSourceInfo] = []

    var onSourcesChanged: (([CaptureSourceInfo], [CaptureSourceInfo]) -> Void)?
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onError: ((String) -> Void)?
    var onStreamsChanged: (() -> Void)?

    var maxCaptureWidth = 3840
    var fps = 60
    var showsCursor = true

    private static let hiddenBundles: Set<String> = [
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.Spotlight", "com.apple.systemuiserver", "com.apple.wallpaper.agent", "com.apple.TextInputMenuAgent",
        "com.apple.loginwindow", "com.apple.screencaptureui", "com.apple.ViewBridgeAuxiliary",
    ]

    init(store: FrameStore) {
        self.store = store
        super.init()
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    // MARK: - Source discovery

    func refresh(completion: (() -> Void)? = nil) {
        // Off-screen windows are included so that this app is always in `applications` and can be excluded,
        // even while all of its windows are hidden.
        SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: false) { [weak self] content, error in
            guard let self else { return }
            guard let content else {
                let msg = (error as NSError?).map { "无法获取屏幕列表（\($0.code)）：请在 系统设置 → 隐私与安全性 → 录屏与系统录音 中允许本应用，然后重启应用" }
                    ?? "无法获取屏幕列表"
                DispatchQueue.main.async {
                    self.onError?(msg)
                    completion?()
                }
                return
            }
            DispatchQueue.main.async {
                let names = Self.screenNames()
                self.apply(content: content, names: names)
                completion?()
            }
        }
    }

    private static func screenNames() -> [UInt32: (String, CGFloat)] {
        var out: [UInt32: (String, CGFloat)] = [:]
        for s in NSScreen.screens {
            if let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
                out[n.uint32Value] = (s.localizedName, s.backingScaleFactor)
            }
        }
        return out
    }

    private func apply(content: SCShareableContent, names: [UInt32: (String, CGFloat)]) {
        var displayInfos: [CaptureSourceInfo] = []
        for (i, d) in content.displays.enumerated() {
            let id = d.displayID
            var px = CGSize(width: d.width * 2, height: d.height * 2)
            if let mode = CGDisplayCopyDisplayMode(id) {
                px = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            }
            let builtIn = CGDisplayIsBuiltin(id) != 0
            let base = names[id]?.0 ?? (builtIn ? "内建显示器" : "外接显示器")
            let name = "显示器 \(i + 1) · \(base)"
            let info = CaptureSourceInfo(ref: .display(id), name: name,
                                         detail: "\(Int(px.width))×\(Int(px.height))\(CGDisplayIsMain(id) != 0 ? " · 主屏" : "")",
                                         pixelSize: px, frame: CGDisplayBounds(id))
            displayInfos.append(info)
        }
        let pid = ProcessInfo.processInfo.processIdentifier
        var windowInfos: [CaptureSourceInfo] = []
        var frames: [UInt32: CGRect] = [:]
        for w in content.windows {
            guard w.windowLayer == 0, let app = w.owningApplication else { continue }
            if app.processID == pid || Self.hiddenBundles.contains(app.bundleIdentifier) { continue }
            let title = (w.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let running = NSRunningApplication(processIdentifier: app.processID)
            var note: String?
            if w.isOnScreen {
                guard w.frame.width >= 240, w.frame.height >= 160 else { continue }
            } else {
                // Background windows (another desktop, minimized, hidden app): only titled document windows of
                // regular apps, so helper and popup windows don't clutter the list.
                guard running?.activationPolicy == .regular, !title.isEmpty, w.frame.width >= 400, w.frame.height >= 300 else { continue }
                note = running?.isHidden == true ? "后台 · 已隐藏" : "后台 · 其他桌面或已最小化"
            }
            let name = title.isEmpty ? app.applicationName : "\(app.applicationName) — \(title)"
            let scale = names.values.map(\.1).max() ?? 2
            let px = CGSize(width: w.frame.width * scale, height: w.frame.height * scale)
            windowInfos.append(CaptureSourceInfo(ref: .window(w.windowID), name: name,
                                                 detail: "\(Int(w.frame.width))×\(Int(w.frame.height))" + (note.map { " · \($0)" } ?? ""),
                                                 pixelSize: px, frame: w.frame, onScreen: w.isOnScreen))
            frames[w.windowID] = w.frame
        }
        windowInfos.sort {
            if $0.onScreen != $1.onScreen { return $0.onScreen }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        lock.lock()
        self.content = content
        var map: [SourceRef: CaptureSourceInfo] = [:]
        for i in displayInfos + windowInfos { map[i.ref] = i }
        // Keep infos for windows that are currently streaming even if they are temporarily off screen.
        for (ref, info) in infos where streams[ref] != nil && map[ref] == nil { map[ref] = info }
        infos = map
        windowFrames.merge(frames) { _, new in new }
        lock.unlock()

        displays = displayInfos
        windows = windowInfos
        onSourcesChanged?(displayInfos, windowInfos)
    }

    func info(for ref: SourceRef) -> CaptureSourceInfo? {
        lock.lock()
        defer { lock.unlock() }
        return infos[ref]
    }

    /// Latest known global frame of a window (points, top-left origin).
    func windowFrame(_ id: UInt32) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return windowFrames[id]
    }

    // MARK: - Streams

    /// Starts streams for `refs` and stops the others. Non-focused sources run at a low frame rate when `throttle` is on.
    func setWanted(_ refs: [SourceRef], focus: SourceRef?, throttle: Bool) {
        controlQueue.async { [weak self] in
            self?.reconcile(Set(refs.filter(\.isCapture)), focus: focus, throttle: throttle)
        }
    }

    private func reconcile(_ want: Set<SourceRef>, focus: SourceRef?, throttle: Bool) {
        lock.lock()
        let running = streams
        lock.unlock()
        for (ref, stream) in running where !want.contains(ref) {
            stream.stopCapture { _ in }
            lock.lock()
            streams[ref] = nil
            configs[ref] = nil
            refsByStream[ObjectIdentifier(stream)] = nil
            lock.unlock()
            store.removeScreen(ref)
        }
        for ref in want {
            let targetFPS = (!throttle || ref == focus) ? fps : 12
            lock.lock()
            let existing = streams[ref]
            let cfg = configs[ref]
            lock.unlock()
            if let stream = existing, let cfg {
                let interval = CMTime(value: 1, timescale: CMTimeScale(targetFPS))
                if cfg.minimumFrameInterval != interval || cfg.showsCursor != showsCursor {
                    cfg.minimumFrameInterval = interval
                    cfg.showsCursor = showsCursor
                    stream.updateConfiguration(cfg) { err in
                        if let err { NSLog("[Screen] update config failed: \(err)") }
                    }
                }
            } else {
                startStream(ref, fps: targetFPS)
            }
        }
        DispatchQueue.main.async { [weak self] in self?.onStreamsChanged?() }
        if want.contains(where: { if case .window = $0 { return true } else { return false } }) {
            startWindowTracking()
        }
    }

    private func startStream(_ ref: SourceRef, fps: Int) {
        lock.lock()
        let content = self.content
        lock.unlock()
        guard let content else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownApps = content.applications.filter { $0.processID == pid }
        let cfg = SCStreamConfiguration()
        let filter: SCContentFilter
        var pixel = CGSize(width: 1920, height: 1080)
        switch ref {
        case .display(let id):
            guard let d = content.displays.first(where: { $0.displayID == id }) else { return }
            filter = SCContentFilter(display: d, excludingApplications: ownApps, exceptingWindows: [])
            if let mode = CGDisplayCopyDisplayMode(id) {
                pixel = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            } else {
                pixel = CGSize(width: d.width * 2, height: d.height * 2)
            }
        case .window(let id):
            guard let w = content.windows.first(where: { $0.windowID == id }) else { return }
            filter = SCContentFilter(desktopIndependentWindow: w)
            let scale = CGFloat(filter.pointPixelScale)
            pixel = CGSize(width: w.frame.width * scale, height: w.frame.height * scale)
            cfg.ignoreShadowsSingleWindow = true
        case .slides:
            return
        }
        let k = min(1, CGFloat(maxCaptureWidth) / max(1, pixel.width))
        cfg.width = max(2, Int(pixel.width * k) / 2 * 2)
        cfg.height = max(2, Int(pixel.height * k) / 2 * 2)
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 5
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.colorSpaceName = CGColorSpace.sRGB
        cfg.showsCursor = showsCursor
        cfg.capturesAudio = false

        let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
        do {
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: frameQueue)
        } catch {
            NSLog("[Screen] addStreamOutput failed: \(error)")
            return
        }
        lock.lock()
        streams[ref] = stream
        configs[ref] = cfg
        refsByStream[ObjectIdentifier(stream)] = ref
        lock.unlock()
        stream.startCapture { [weak self] error in
            if let error {
                NSLog("[Screen] start failed for \(ref.key): \(error)")
                self?.dropStream(stream)
                DispatchQueue.main.async { self?.onError?("屏幕捕捉启动失败：\(error.localizedDescription)") }
            }
        }
    }

    private func dropStream(_ stream: SCStream) {
        lock.lock()
        let ref = refsByStream[ObjectIdentifier(stream)]
        if let ref {
            streams[ref] = nil
            configs[ref] = nil
        }
        refsByStream[ObjectIdentifier(stream)] = nil
        lock.unlock()
        if let ref { store.removeScreen(ref) }
        DispatchQueue.main.async { [weak self] in self?.onStreamsChanged?() }
    }

    func stopAll() {
        setWanted([], focus: nil, throttle: false)
        setSystemAudio(false)
    }

    func isStreaming(_ ref: SourceRef) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return streams[ref] != nil
    }

    // MARK: - Window tracking (for cursor mapping and resizes)

    private func startWindowTracking() {
        guard windowTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: controlQueue)
        t.schedule(deadline: .now() + 0.25, repeating: 0.25)
        t.setEventHandler { [weak self] in self?.pollWindows() }
        t.resume()
        windowTimer = t
    }

    private func pollWindows() {
        lock.lock()
        let windowRefs = streams.keys.compactMap { ref -> UInt32? in
            if case .window(let id) = ref { return id }
            return nil
        }
        lock.unlock()
        guard !windowRefs.isEmpty else { return }
        for id in windowRefs {
            guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id)) as? [[String: Any]],
                  let first = list.first,
                  let boundsDict = first[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            lock.lock()
            let old = windowFrames[id]
            windowFrames[id] = bounds
            let cfg = configs[.window(id)]
            let stream = streams[.window(id)]
            lock.unlock()
            if let old, let cfg, let stream, abs(old.width - bounds.width) > 2 || abs(old.height - bounds.height) > 2 {
                let scale = CGFloat(cfg.width) / max(1, old.width)
                cfg.width = max(2, Int(bounds.width * scale) / 2 * 2)
                cfg.height = max(2, Int(bounds.height * scale) / 2 * 2)
                stream.updateConfiguration(cfg) { _ in }
            }
        }
    }

    // MARK: - System audio

    func setSystemAudio(_ on: Bool) {
        controlQueue.async { [weak self] in
            guard let self else { return }
            if !on {
                self.audioStream?.stopCapture { _ in }
                self.audioStream = nil
                return
            }
            guard self.audioStream == nil else { return }
            self.lock.lock()
            let content = self.content
            self.lock.unlock()
            guard let content, let display = content.displays.first else { return }
            let pid = ProcessInfo.processInfo.processIdentifier
            let filter = SCContentFilter(display: display, excludingApplications: content.applications.filter { $0.processID == pid }, exceptingWindows: [])
            let cfg = SCStreamConfiguration()
            cfg.capturesAudio = true
            cfg.excludesCurrentProcessAudio = true
            cfg.sampleRate = 48000
            cfg.channelCount = 2
            cfg.width = 2
            cfg.height = 2
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
            let stream = SCStream(filter: filter, configuration: cfg, delegate: self)
            do {
                try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: self.audioQueue)
            } catch {
                NSLog("[Screen] audio output failed: \(error)")
                return
            }
            self.audioStream = stream
            stream.startCapture { error in
                if let error { NSLog("[Screen] system audio failed: \(error)") }
            }
        }
    }

    // MARK: - SCStreamOutput / Delegate

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        switch type {
        case .screen:
            handleScreen(stream, sampleBuffer)
        case .audio:
            onAudio?(sampleBuffer)
        default:
            break
        }
    }

    private func handleScreen(_ stream: SCStream, _ sb: CMSampleBuffer) {
        guard sb.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pb = sb.imageBuffer else { return }
        lock.lock()
        let ref = refsByStream[ObjectIdentifier(stream)]
        lock.unlock()
        guard let ref else { return }

        let bw = CGFloat(CVPixelBufferGetWidth(pb)), bh = CGFloat(CVPixelBufferGetHeight(pb))
        let full = CGRect(x: 0, y: 0, width: bw, height: bh)
        var rect = full
        if let dictAny = info[.contentRect] {
            let dict = dictAny as! CFDictionary
            if let cr = CGRect(dictionaryRepresentation: dict) {
                let scale = (info[.scaleFactor] as? CGFloat) ?? 1
                let contentScale = (info[.contentScale] as? CGFloat) ?? 1
                let k = scale * contentScale
                let r = CGRect(x: cr.minX * k, y: cr.minY * k, width: cr.width * k, height: cr.height * k).intersection(full)
                if !r.isNull, r.width > 16, r.height > 16 { rect = r.integral.intersection(full) }
            }
        }
        store.setScreen(ScreenFrame(pixelBuffer: pb, contentRect: rect, hostTime: CACurrentMediaTime()), for: ref)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("[Screen] stream stopped: \(error)")
        if stream === audioStream {
            controlQueue.async { [weak self] in self?.audioStream = nil }
            return
        }
        dropStream(stream)
        DispatchQueue.main.async { [weak self] in
            self?.onError?("一个屏幕/窗口捕捉已停止（可能是窗口关闭或显示器断开）")
            self?.refresh()
        }
    }
}
