import Foundation
import CoreImage
import CoreVideo
import QuartzCore
import AppKit

protocol FrameSink: AnyObject {
    func consume(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval)
}

struct SceneSources: Equatable {
    var slides: SourceRef?
    var demo: SourceRef?
}

struct EngineStats {
    var fps: Double = 0
    var renderMs: Double = 0
    var late: Int = 0
}

/// Owns the animated scene state and the render loop.
final class RenderEngine {
    let context: CIContext
    let store: FrameStore
    let assets: AssetFactory
    let cursor: CursorTracker
    weak var screens: ScreenCaptureManager?

    private(set) var compositor: Compositor
    private var pool: CVPixelBufferPool?
    private let queue = DispatchQueue(label: "render.loop", qos: .userInteractive)
    private let assetQueue = DispatchQueue(label: "render.assets", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var fps = 60

    private let lock = NSLock()
    private var config = LayoutConfig()
    private var transitions = TransitionSettings()
    private var scene: SceneKind = .camera
    private var sceneFrom = SceneLayout()
    private var sceneStart: Double = 0
    private var sceneDuration: Double = 0
    private var lastLayout = SceneLayout()
    private var pipVisible = AnimatedValue(1)
    private var sources = SceneSources()
    private var currentContent: SourceRef?
    private var previousContent: SourceRef?
    private var contentStart: Double = 0
    private var contentDuration: Double = 0
    private var contentStyle: TransitionStyle = .fade
    private var contentDirection: CGFloat = 1
    private var zoomActive = false
    private var zoomAmount = AnimatedValue(1)
    private var zoomCenter = CGPoint(x: 0.5, y: 0.5)
    private var zoomTarget = CGPoint(x: 0.5, y: 0.5)
    private var autoZoomOffAt: Double?
    private var faceSmoothed: CGPoint?
    private var deck: SlideDeck?
    private var slideIndex = 0
    private var slidePrevIndex = 0
    private var slideStart: Double = 0
    private var lowerThird = AnimatedValue(0)
    private var lowerThirdHideAt: Double?
    private var lastTick: Double = 0

    private var sinks: [ObjectIdentifier: FrameSink] = [:]
    private let sinkLock = NSLock()

    private var stats = EngineStats()
    private var fpsCounter = FPSCounter()
    private var renderAvg: Double = 0

    /// For tests: a normalized cursor position on the current content.
    var cursorOverride: CGPoint?

    init(context: CIContext, store: FrameStore, assets: AssetFactory, cursor: CursorTracker, canvasSize: CGSize) {
        self.context = context
        self.store = store
        self.assets = assets
        self.cursor = cursor
        let canvas = Canvas(width: canvasSize.width, height: canvasSize.height)
        canvasValue = canvas
        compositor = Compositor(context: context, canvas: canvas)
        pool = compositor.makeOutputPool()
    }

    private var canvasValue: Canvas

    var canvas: Canvas {
        lock.lock()
        defer { lock.unlock() }
        return canvasValue
    }

    // MARK: - Loop

    var isRunning: Bool { queue.sync { timer != nil } }

    func start(fps: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.fps = max(15, min(120, fps))
            self.timer?.cancel()
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.queue)
            let interval = 1.0 / Double(self.fps)
            t.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(0))
            t.setEventHandler { [weak self] in self?.tick() }
            t.resume()
            self.timer = t
        }
    }

    func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Main-thread barrier before a writer starts with a newly selected output size.
    func synchronize() {
        queue.sync {}
    }

    /// Rebuilds the compositor for a new output size. Assets must be re-applied afterwards.
    func setCanvasSize(_ size: CGSize) {
        queue.async { [weak self] in
            guard let self, self.compositor.canvas.size != size else { return }
            let old = self.compositor
            let c = Compositor(context: self.context, canvas: Canvas(width: size.width, height: size.height))
            c.borderColor = old.borderColor
            c.clickColor = old.clickColor
            self.compositor = c
            self.pool = c.makeOutputPool()
            self.assetsVersion &+= 1
            self.lastOutput = nil
            self.lock.lock()
            self.canvasValue = c.canvas
            self.sceneDuration = 0
            self.contentDuration = 0
            self.lastLayout = SceneLayout()
            self.slideViewports = [:]
            let deck = self.deck
            let slide = self.slideIndex
            self.lock.unlock()
            deck?.prefetch(around: slide, size: size)
        }
    }

    func addSink(_ s: FrameSink) {
        sinkLock.lock()
        sinks[ObjectIdentifier(s)] = s
        sinkLock.unlock()
    }

    func removeSink(_ s: FrameSink) {
        sinkLock.lock()
        sinks[ObjectIdentifier(s)] = nil
        sinkLock.unlock()
    }

    func currentStats() -> EngineStats {
        lock.lock()
        defer { lock.unlock() }
        return stats
    }

    private var videoLagValue: Double = 0

    /// Smoothed delay between camera capture and the composited frame (seconds).
    var videoLag: Double {
        lock.lock()
        defer { lock.unlock() }
        return videoLagValue
    }

    private func tick() {
        let now = CACurrentMediaTime()
        if lastTick > 0 && now - lastTick > 1.6 / Double(fps) {
            lock.lock()
            stats.late += 1
            lock.unlock()
        }
        lastTick = now
        guard let pb = renderFrame(at: now) else { return }
        sinkLock.lock()
        let targets = Array(sinks.values)
        sinkLock.unlock()
        for s in targets { s.consume(pb, hostTime: now) }
        let dt = (CACurrentMediaTime() - now) * 1000
        renderAvg = renderAvg * 0.95 + dt * 0.05
        fpsCounter.tick(now)
        lock.lock()
        stats.fps = fpsCounter.fps
        stats.renderMs = renderAvg
        lock.unlock()
    }

    /// Renders one output frame for host time `now`.
    func renderFrame(at now: Double) -> CVPixelBuffer? {
        lock.lock()
        let presenterVisible = config.presenterVisible
        lock.unlock()
        let camera = presenterVisible ? store.camera() : nil
        if let c = camera {
            let lag = now - c.captureTime
            if lag > 0 && lag < 0.5 {
                lock.lock()
                videoLagValue = videoLagValue == 0 ? lag : videoLagValue * 0.97 + lag * 0.03
                lock.unlock()
            }
        }
        let (fd, needed, slideImage) = describe(now: now, face: camera?.face)
        // Same description and same inputs as the previous frame: reuse it (it is still appended / shown at full rate).
        let signature = FrameSignature(description: fd,
                                       camera: camera.map { ObjectIdentifier($0) },
                                       screens: needed.map { ref in store.screen(ref).map { ObjectIdentifier($0) } },
                                       slide: slideImage.map { ObjectIdentifier($0) },
                                       assets: assetsVersion)
        if signature == lastSignature, let last = lastOutput {
            return last
        }
        var inputs = FrameInputs(camera: camera)
        for ref in needed {
            switch ref {
            case .slides:
                if let img = slideImage { inputs.contents[ref] = img }
            default:
                if let f = store.screen(ref) {
                    let img = CIImage(cvPixelBuffer: f.pixelBuffer)
                    let h = img.extent.height
                    let r = f.contentRect
                    let ci = CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
                    inputs.contents[ref] = img.cropped(to: ci).transformed(by: CGAffineTransform(translationX: -ci.minX, y: -ci.minY))
                }
            }
        }
        let image = compositor.compose(fd, inputs)
        guard let pool, let pb = Self.buffer(from: pool) else { return nil }
        compositor.render(image, to: pb)
        lastSignature = signature
        lastOutput = pb
        return pb
    }

    private struct FrameSignature: Equatable {
        var description: FrameDescription
        var camera: ObjectIdentifier?
        var screens: [ObjectIdentifier?]
        var slide: ObjectIdentifier?
        var assets: Int
    }

    private var lastSignature: FrameSignature?
    private var lastOutput: CVPixelBuffer?
    /// Bumped on the render queue whenever compositor assets (backdrop, overlays…) change.
    private var assetsVersion = 0

    private static func buffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }

    // MARK: - Frame description

    private func describe(now: Double, face: CGPoint?) -> (FrameDescription, [SourceRef], CIImage?) {
        lock.lock()
        let canvas = canvasValue
        defer { lock.unlock() }
        let dt = lastDescribe > 0 ? min(0.1, now - lastDescribe) : 1.0 / 60
        lastDescribe = now

        // Share one smoothed face position across full-frame, bubble and split layouts.
        // Missing detections retain the last position instead of snapping the presenter back to center.
        if let f = face {
            if let s = faceSmoothed {
                let dx = f.x - s.x, dy = f.y - s.y
                let dist = sqrt(dx * dx + dy * dy)
                if dist > 0.015 {
                    let k = CGFloat(1 - exp(-dt / 0.7))
                    faceSmoothed = CGPoint(x: s.x + dx * k, y: s.y + dy * k)
                }
            } else {
                faceSmoothed = f
            }
        }

        let pv = pipVisible.value(at: now)
        var target = LayoutBuilder.layout(for: scene, canvas: canvas, config: config, pipVisibility: pv, face: faceSmoothed)
        if scene == .demo { target.content.alignX = demoAlign.value(at: now) }
        var layout = target
        if sceneDuration > 0 {
            let p = CGFloat((now - sceneStart) / sceneDuration)
            if p < 1 { layout = sceneFrom.lerp(to: target, Ease.inOutCubic(max(0, p))) }
        }
        // A device-off request must also hide a presenter captured in an in-flight scene transition.
        if !config.presenterVisible { layout.camera.opacity = 0 }
        lastLayout = layout

        var fd = FrameDescription()
        fd.layout = layout
        fd.watermarkCorner = config.overlay.watermarkCorner
        fd.watermarkLightText = watermarkDarkScenes.contains(scene)

        // Content layers
        var needed: [SourceRef] = []
        if let cur = currentContent {
            let cp = contentDuration > 0 ? CGFloat((now - contentStart) / contentDuration) : 1
            if cp < 1, let prev = previousContent, prev != cur {
                let e = Ease.inOutCubic(max(0, cp))
                switch contentStyle {
                case .push:
                    let w = canvas.width * contentDirection
                    fd.contents = [ContentDraw(source: prev, opacity: 1, offset: CGPoint(x: -w * e, y: 0)),
                                   ContentDraw(source: cur, opacity: 1, offset: CGPoint(x: w * (1 - e), y: 0))]
                case .smooth:
                    fd.contents = [ContentDraw(source: prev, opacity: 1 - e * e, scale: 1 - 0.03 * e),
                                   ContentDraw(source: cur, opacity: e, scale: 1.05 - 0.05 * e)]
                case .fade:
                    fd.contents = [ContentDraw(source: prev, opacity: 1 - e * e), ContentDraw(source: cur, opacity: e)]
                case .cut:
                    fd.contents = [ContentDraw(source: cur)]
                }
                needed = [prev, cur]
            } else {
                previousContent = nil
                fd.contents = [ContentDraw(source: cur)]
                needed = [cur]
            }
        }

        // Follow-cursor zoom on the current capture source
        if let auto = autoZoomOffAt, now >= auto {
            autoZoomOffAt = nil
            if zoomActive { setZoomLocked(false, now: now) }
        }
        if let cur = currentContent, cur.isCapture {
            let factor = zoomAmount.value(at: now)
            if factor > 1.001 {
                let region = layout.content.sourceCrop
                let halfX = region.width / factor / 2
                let halfY = region.height / factor / 2
                if let n = cursorOverride ?? normalizedCursor(on: cur) {
                    let innerX = halfX * 0.5, innerY = halfY * 0.5
                    var t = zoomTarget
                    if n.x > t.x + innerX { t.x = n.x - innerX } else if n.x < t.x - innerX { t.x = n.x + innerX }
                    if n.y > t.y + innerY { t.y = n.y - innerY } else if n.y < t.y - innerY { t.y = n.y + innerY }
                    zoomTarget = t
                }
                zoomTarget = CGPoint(x: clamp(zoomTarget.x, region.minX + halfX, region.maxX - halfX),
                                     y: clamp(zoomTarget.y, region.minY + halfY, region.maxY - halfY))
                let k = CGFloat(1 - exp(-dt / 0.16))
                zoomCenter = lerp(zoomCenter, zoomTarget, k)
            }
            fd.zoom[cur] = ZoomState(factor: factor, center: zoomCenter)
            if let prev = previousContent, prev != cur { fd.zoom[prev] = ZoomState() }
        }

        // Click highlights
        if config.demo.clickHighlight, let cur = currentContent, cur.isCapture {
            if cursorOverride == nil {
                for c in cursor.recentClicks(within: 0.6, now: now) {
                    if let n = normalized(c.point, on: cur) {
                        fd.clicks.append(ClickMark(source: cur, point: n, age: now - c.time))
                    }
                }
            } else {
                for c in injectedClicks where now - c.time >= 0 && now - c.time < 0.6 {
                    fd.clicks.append(ClickMark(source: cur, point: c.point, age: now - c.time))
                }
            }
        }

        // Lower third
        if let hideAt = lowerThirdHideAt, now >= hideAt {
            lowerThirdHideAt = nil
            lowerThird.animate(to: 0, at: now, duration: 0.4, curve: Ease.inCubic)
        }
        fd.lowerThird = lowerThird.value(at: now)
        if fd.lowerThird > 0 {
            let u = canvas.unit
            let pipRect = LayoutBuilder.pipRect(canvas: canvas, pip: config.pip)
            if canvas.width >= canvas.height && scene.hasPIP && pv > 0.5 && config.pip.corner == .bottomLeft {
                fd.lowerThirdAnchor = CGPoint(x: pipRect.maxX + 6 * u, y: pipRect.maxY - pipRect.height * 0.04)
            } else if canvas.width < canvas.height && scene.hasPIP && pv > 0.5 && config.pip.corner.isBottom {
                fd.lowerThirdAnchor = CGPoint(x: canvas.width * 0.05, y: pipRect.minY - 12 * u)
            } else {
                fd.lowerThirdAnchor = CGPoint(x: canvas.width * 0.05, y: canvas.height * 0.93)
            }
        }

        // Slides
        var slideImage: CIImage?
        if needed.contains(.slides), let deck {
            let size = canvas.size
            let cur = deck.image(at: slideIndex, size: size)
            let sp = transitions.slideDuration > 0 ? CGFloat((now - slideStart) / transitions.slideDuration) : 1
            if sp < 1, slidePrevIndex != slideIndex, let prev = deck.image(at: slidePrevIndex, size: size), let cur {
                // Pages may differ in size: scale the previous page onto the current one for the dissolve.
                let p = prev.transformed(by: CGAffineTransform(scaleX: cur.extent.width / max(1, prev.extent.width),
                                                               y: cur.extent.height / max(1, prev.extent.height)))
                slideImage = p.applyingFilter("CIDissolveTransition", parameters: [
                    kCIInputTargetImageKey: cur,
                    kCIInputTimeKey: Ease.inOutCubic(max(0, sp)),
                ]).cropped(to: cur.extent)
            } else {
                slideImage = cur
            }
            if let img = slideImage {
                lastSlideSize = img.extent.size
                let vp = slideViewportLocked(slot: layout.content)
                for i in fd.contents.indices where fd.contents[i].source == .slides { fd.contents[i].viewport = vp }
            }
        }
        return (fd, needed, slideImage)
    }

    // MARK: - Slide zoom / pan

    enum SlideViewAction {
        /// Delta in normalized preview coordinates.
        case pan(CGVector)
        /// Zoom factor at a normalized point.
        case zoom(CGFloat, CGPoint)
        case reset
    }

    private var slideViewports: [Int: ContentViewport] = [:]
    private var lastSlideSize: CGSize = .zero

    private func slideBase(slot: ContentSlot) -> CGRect {
        lerp(slot.rect.aspectFit(lastSlideSize), slot.rect.aspectFill(lastSlideSize), slot.fill)
    }

    private func slideViewportLocked(slot: ContentSlot) -> ContentViewport {
        slideViewports[slideIndex] ?? .initial(base: slideBase(slot: slot), slot: slot.rect)
    }

    /// Applies a zoom / pan gesture to the current page. Returns the zoom (1 = default view) or nil if the view is the default.
    @discardableResult
    func slideView(_ action: SlideViewAction) -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        guard deck != nil, lastSlideSize.width > 0 else { return nil }
        let slot = lastLayout.content
        let base = slideBase(slot: slot)
        var vp = slideViewportLocked(slot: slot)
        let W = canvasValue.width, H = canvasValue.height
        switch action {
        case .pan(let d):
            vp.pan(by: CGVector(dx: d.dx * W, dy: d.dy * H), base: base, slot: slot.rect)
        case .zoom(let f, let p):
            vp.zoom(by: f, at: CGPoint(x: p.x * W, y: p.y * H), base: base, slot: slot.rect,
                    limits: ContentViewport.scaleLimits(base: base, slot: slot.rect, contentSize: lastSlideSize))
        case .reset:
            slideViewports[slideIndex] = nil
            return nil
        }
        slideViewports[slideIndex] = vp
        return vp.scale
    }

    /// Zoom of the current page, or nil when it shows the default view.
    func slideViewZoom() -> CGFloat? {
        lock.lock()
        defer { lock.unlock() }
        return slideViewports[slideIndex]?.scale
    }

    private var lastDescribe: Double = 0

    private func normalizedCursor(on ref: SourceRef) -> CGPoint? {
        normalized(cursor.location(), on: ref)
    }

    /// Converts a global Quartz point into normalized coordinates of a capture source.
    private func normalized(_ p: CGPoint, on ref: SourceRef) -> CGPoint? {
        let frame: CGRect
        switch ref {
        case .display(let id): frame = CGDisplayBounds(id)
        case .window(let id):
            guard let f = screens?.windowFrame(id) else { return nil }
            frame = f
        case .slides: return nil
        }
        guard frame.width > 0, frame.height > 0 else { return nil }
        let n = CGPoint(x: (p.x - frame.minX) / frame.width, y: (p.y - frame.minY) / frame.height)
        guard n.x >= 0, n.x <= 1, n.y >= 0, n.y <= 1 else { return nil }
        return n
    }

    // MARK: - Commands (thread-safe)

    func update(config c: LayoutConfig, transitions t: TransitionSettings) {
        let now = CACurrentMediaTime()
        lock.lock()
        if !configApplied {
            demoAlign.set(CGFloat(c.demo.contentAlign))
            configApplied = true
        } else if c.demo.contentAlign != config.demo.contentAlign {
            demoAlign.animate(to: CGFloat(c.demo.contentAlign), at: now, duration: 0.45, curve: Ease.inOutCubic)
        }
        config = c
        transitions = t
        lock.unlock()
    }

    private var configApplied = false
    /// Animated horizontal position of the demo screen.
    private var demoAlign = AnimatedValue(0)

    func setScene(_ s: SceneKind, animated: Bool = true, at time: Double? = nil) {
        let now = time ?? CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard s != scene else { return }
        sceneFrom = lastLayoutOrTarget(now)
        scene = s
        sceneStart = now
        sceneDuration = animated ? transitions.sceneDuration : 0
        retargetContent(now: now, style: .smooth, duration: animated ? transitions.sceneDuration * 0.9 : 0, direction: 1)
    }

    private func lastLayoutOrTarget(_ now: Double) -> SceneLayout {
        lastLayout.camera.rect.width > 0 ? lastLayout
            : LayoutBuilder.layout(for: scene, canvas: canvasValue, config: config, pipVisibility: pipVisible.value(at: now), face: faceSmoothed)
    }

    var currentScene: SceneKind {
        lock.lock()
        defer { lock.unlock() }
        return scene
    }

    func setSources(_ s: SceneSources, direction: CGFloat = 1, style: TransitionStyle? = nil, at time: Double? = nil) {
        let now = time ?? CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard s != sources else { return }
        sources = s
        retargetContent(now: now, style: style ?? transitions.sourceStyle, duration: transitions.sourceDuration, direction: direction)
    }

    private func contentRef(for scene: SceneKind) -> SourceRef? {
        switch scene {
        case .camera: return nil
        case .slides: return sources.slides
        case .demo: return sources.demo
        case .split: return config.split.content == .slides ? sources.slides : sources.demo
        }
    }

    private func retargetContent(now: Double, style: TransitionStyle, duration: Double, direction: CGFloat) {
        guard let next = contentRef(for: scene) else { return }
        guard next != currentContent else { return }
        let visible = lastLayout.content.opacity > 0.05
        if currentContent == nil || !visible || duration <= 0 || style == .cut {
            currentContent = next
            previousContent = nil
            contentDuration = 0
        } else {
            previousContent = currentContent
            currentContent = next
            contentStart = now
            contentDuration = duration
            contentStyle = style
            contentDirection = direction
        }
        if zoomActive { setZoomLocked(false, now: now) }
    }

    func setPIPVisible(_ visible: Bool, at time: Double? = nil) {
        let now = time ?? CACurrentMediaTime()
        lock.lock()
        pipVisible.animate(to: visible ? 1 : 0, at: now, duration: transitions.pipDuration,
                           curve: visible ? Ease.outBack : Ease.inOutCubic)
        lock.unlock()
    }

    func setZoom(_ on: Bool, at time: Double? = nil) {
        let now = time ?? CACurrentMediaTime()
        lock.lock()
        setZoomLocked(on, now: now)
        lock.unlock()
    }

    var isZoomed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return zoomActive
    }

    private func setZoomLocked(_ on: Bool, now: Double) {
        guard on != zoomActive else { return }
        zoomActive = on
        if on, let cur = currentContent, let n = cursorOverride ?? normalizedCursor(on: cur) {
            let f = CGFloat(max(1.2, config.demo.zoomFactor))
            let region = LayoutBuilder.layout(for: scene, canvas: canvasValue, config: config,
                                              pipVisibility: pipVisible.value(at: now), face: faceSmoothed).content.sourceCrop
            let halfX = region.width / f / 2, halfY = region.height / f / 2
            zoomTarget = CGPoint(x: clamp(n.x, region.minX + halfX, region.maxX - halfX),
                                 y: clamp(n.y, region.minY + halfY, region.maxY - halfY))
            if zoomAmount.value(at: now) < 1.01 { zoomCenter = zoomTarget }
        }
        zoomAmount.animate(to: on ? CGFloat(max(1.2, config.demo.zoomFactor)) : 1, at: now, duration: on ? 0.6 : 0.5, curve: Ease.inOutCubic)
        if !on { autoZoomOffAt = nil }
    }

    /// Called on every global click when auto zoom is enabled.
    func autoZoom(click: ClickEvent) {
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard config.demo.zoomMode == .autoOnClick, let cur = currentContent, cur.isCapture,
              scene != .camera, normalized(click.point, on: cur) != nil else { return }
        if !zoomActive { setZoomLocked(true, now: now) }
        autoZoomOffAt = now + max(1, config.demo.autoZoomHold)
    }

    /// Offline rendering: a recorded click at a normalized position on the current content, at timeline time `time`.
    /// Used for the click highlight (while `cursorOverride` is set) and for click-triggered auto zoom.
    private var injectedClicks: [(point: CGPoint, time: Double)] = []

    func injectClick(_ point: CGPoint, at time: Double) {
        lock.lock()
        defer { lock.unlock() }
        injectedClicks.append((point, time))
        if injectedClicks.count > 32 { injectedClicks.removeFirst(injectedClicks.count - 32) }
        guard config.demo.zoomMode == .autoOnClick, let cur = currentContent, cur.isCapture, scene != .camera else { return }
        if !zoomActive {
            cursorOverride = point
            setZoomLocked(true, now: time)
        }
        autoZoomOffAt = time + max(1, config.demo.autoZoomHold)
    }

    func setDeck(_ d: SlideDeck?) {
        lock.lock()
        deck = d
        slideIndex = 0
        slidePrevIndex = 0
        slideViewports = [:]
        let size = canvasValue.size
        lock.unlock()
        d?.prefetch(around: 0, size: size)
    }

    @discardableResult
    func setSlide(_ index: Int, at time: Double? = nil) -> Int {
        let now = time ?? CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        guard let deck else { return 0 }
        let i = max(0, min(deck.pageCount - 1, index))
        guard i != slideIndex else { return i }
        slidePrevIndex = slideIndex
        slideIndex = i
        slideStart = now
        deck.prefetch(around: i, size: canvasValue.size)
        return i
    }

    func showLowerThird(seconds: Double, at time: Double? = nil) {
        let now = time ?? CACurrentMediaTime()
        lock.lock()
        lowerThird.animate(to: 1, at: now, duration: 0.5, curve: Ease.outCubic)
        lowerThirdHideAt = now + max(1, seconds)
        lock.unlock()
    }

    func hideLowerThird() {
        let now = CACurrentMediaTime()
        lock.lock()
        lowerThirdHideAt = nil
        lowerThird.animate(to: 0, at: now, duration: 0.4, curve: Ease.inCubic)
        lock.unlock()
    }

    /// For tests: jump the clock-dependent state to a scene instantly.
    func resetAnimations() {
        lock.lock()
        sceneDuration = 0
        contentDuration = 0
        previousContent = nil
        lock.unlock()
    }

    // MARK: - Assets

    struct AssetConfig: Equatable {
        var backdrop = "lavender"
        var customBackdrop = ""
        var overlay = OverlaySettings()
        var borderColor = RGBA.white
        var canvas = CGSize(width: 1920, height: 1080)
        /// Whether the presenter's background is dark, so the watermark over it uses light text.
        var cameraBackgroundDark = true
    }

    private var assetConfig: AssetConfig?
    /// Scenes whose background behind the watermark is dark (light text is used there).
    private var watermarkDarkScenes: Set<SceneKind> = [.camera]

    func applyAssets(_ a: AssetConfig, completion: (() -> Void)? = nil) {
        guard a != assetConfig else { completion?(); return }
        assetConfig = a
        let assets = self.assets
        assetQueue.async { [weak self] in
            let size = a.canvas
            let unit = min(size.width, size.height) / 1080
            let backdrop = assets.demoBackdrop(id: a.backdrop, customPath: a.customBackdrop, size: size).map { CIImage(cgImage: $0) }
            let dark = a.backdrop == "custom" ? false : AssetCatalog.demoBackdropIsDark(a.backdrop)
            let wmLight = assets.watermark(title: a.overlay.watermarkTitle, subtitle: a.overlay.watermarkSubtitle,
                                           accent: a.overlay.accent, dark: true, unit: unit).map { CIImage(cgImage: $0) }
            let wmDark = assets.watermark(title: a.overlay.watermarkTitle, subtitle: a.overlay.watermarkSubtitle,
                                          accent: a.overlay.accent, dark: false, unit: unit).map { CIImage(cgImage: $0) }
            let lt = assets.lowerThird(name: a.overlay.lowerThirdName, title: a.overlay.lowerThirdTitle,
                                       accent: a.overlay.accent, unit: unit).map { CIImage(cgImage: $0) }
            let camPh = assets.cameraPlaceholder(size: CGSize(width: 1920, height: 1080)).map { CIImage(cgImage: $0) }
            let srcPh = assets.sourcePlaceholder(size: CGSize(width: 1920, height: 1200), title: "正在等待画面…",
                                                 detail: "如长时间没有画面，请检查「录屏与系统录音」权限，或在「屏幕」页重新选择", dark: dark).map { CIImage(cgImage: $0) }
            guard let self else { return }
            self.queue.async {
                let c = self.compositor
                if c.canvas.size == size {
                    self.assetsVersion &+= 1
                    if let backdrop { c.backdrop = backdrop }
                    c.watermarkLight = wmLight
                    c.watermarkDark = wmDark
                    self.lock.lock()
                    self.watermarkDarkScenes = Set(SceneKind.allCases.filter { s in
                        switch s {
                        case .camera: return a.cameraBackgroundDark
                        case .demo: return dark
                        case .slides, .split: return false
                        }
                    })
                    self.lock.unlock()
                    c.lowerThirdImage = lt
                    c.cameraPlaceholder = camPh
                    c.sourcePlaceholder = srcPh
                    c.borderColor = a.borderColor.ciColor
                    c.clickColor = a.overlay.clickColor.ciColor
                }
                completion?()
            }
        }
    }

    /// Forces assets to be rebuilt (e.g. after a canvas size change).
    func invalidateAssets() {
        assetConfig = nil
    }
}
