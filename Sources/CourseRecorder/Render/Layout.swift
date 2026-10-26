import Foundation
import CoreGraphics

/// Where and how the presenter (camera) is drawn. All rects use a top-left origin in output pixels.
struct CameraLayer: Equatable {
    var rect: CGRect = .zero
    var cornerRadius: CGFloat = 0
    var opacity: CGFloat = 1
    var borderWidth: CGFloat = 0
    var shadow: CGFloat = 0
    /// Crop zoom (1 = largest crop of the camera frame with the layer's aspect ratio).
    var zoom: CGFloat = 1
    /// Crop center in normalized camera coordinates (top-left origin).
    var center: CGPoint = CGPoint(x: 0.5, y: 0.5)
    var featherLeft: CGFloat = 0
    var featherRight: CGFloat = 0
    /// 1 = processed camera with its (virtual) background, 0 = person cut out on transparency.
    var backgroundOpacity: CGFloat = 1
    /// Where `center.x` lands inside the layer (0 = left edge, 1 = right edge).
    var anchorX: CGFloat = 0.5

    func lerp(to b: CameraLayer, _ t: CGFloat) -> CameraLayer {
        CameraLayer(
            rect: CourseRecorder.lerp(rect, b.rect, t),
            cornerRadius: CourseRecorder.lerp(cornerRadius, b.cornerRadius, t),
            opacity: CourseRecorder.lerp(opacity, b.opacity, t),
            borderWidth: CourseRecorder.lerp(borderWidth, b.borderWidth, t),
            shadow: CourseRecorder.lerp(shadow, b.shadow, t),
            zoom: CourseRecorder.lerp(zoom, b.zoom, t),
            center: CourseRecorder.lerp(center, b.center, t),
            featherLeft: CourseRecorder.lerp(featherLeft, b.featherLeft, t),
            featherRight: CourseRecorder.lerp(featherRight, b.featherRight, t),
            backgroundOpacity: CourseRecorder.lerp(backgroundOpacity, b.backgroundOpacity, t),
            anchorX: CourseRecorder.lerp(anchorX, b.anchorX, t)
        )
    }
}

/// The region where the scene's content (slides / screen) is placed.
struct ContentSlot: Equatable {
    var rect: CGRect = .zero
    var cornerRadius: CGFloat = 0
    var opacity: CGFloat = 0
    var shadow: CGFloat = 0
    /// 0 = aspect fit inside `rect`, 1 = aspect fill (cropped to `rect`).
    var fill: CGFloat = 0
    /// Horizontal placement of fitted content in the free space: -1 left, 0 center, 1 right.
    var alignX: CGFloat = 0
    /// The content's left edge must be at least this x (0 = no constraint), to clear a bubble on the left.
    var avoidLeft: CGFloat = 0
    /// The content's right edge must stay this far from the canvas' right edge (0 = no constraint).
    var avoidRightInset: CGFloat = 0
    /// Selected source region in normalized top-left coordinates, before follow-cursor zoom.
    var sourceCrop: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)

    func lerp(to b: ContentSlot, _ t: CGFloat) -> ContentSlot {
        ContentSlot(
            rect: CourseRecorder.lerp(rect, b.rect, t),
            cornerRadius: CourseRecorder.lerp(cornerRadius, b.cornerRadius, t),
            opacity: CourseRecorder.lerp(opacity, b.opacity, t),
            shadow: CourseRecorder.lerp(shadow, b.shadow, t),
            fill: CourseRecorder.lerp(fill, b.fill, t),
            alignX: CourseRecorder.lerp(alignX, b.alignX, t),
            avoidLeft: CourseRecorder.lerp(avoidLeft, b.avoidLeft, t),
            avoidRightInset: CourseRecorder.lerp(avoidRightInset, b.avoidRightInset, t),
            sourceCrop: CourseRecorder.lerp(sourceCrop, b.sourceCrop, t)
        )
    }

    /// Places content of `rect`'s size horizontally inside the slot according to alignment and bubble avoidance.
    func aligned(_ rect: CGRect, canvasWidth: CGFloat) -> CGRect {
        let free = self.rect.width - rect.width
        guard free > 0.5 else { return rect }
        var x = self.rect.minX + free * (clamp(alignX, -1, 1) + 1) / 2
        let maxX = self.rect.maxX - rect.width
        if avoidLeft > 0.5 { x = max(x, min(maxX, avoidLeft)) }
        if avoidRightInset > 0.5 { x = min(x, max(self.rect.minX, canvasWidth - avoidRightInset - rect.width)) }
        var r = rect
        r.origin.x = x
        return r
    }
}

struct SceneLayout: Equatable {
    var camera = CameraLayer()
    var content = ContentSlot()
    var watermark: CGFloat = 0

    func lerp(to b: SceneLayout, _ t: CGFloat) -> SceneLayout {
        SceneLayout(camera: camera.lerp(to: b.camera, t),
                    content: content.lerp(to: b.content, t),
                    watermark: CourseRecorder.lerp(watermark, b.watermark, t))
    }
}

/// The subset of settings the layout needs, copied so the render thread never touches shared state.
struct LayoutConfig {
    /// Runtime visibility of the live presenter; offline project exports keep their recorded presenter.
    var presenterVisible = true
    var pip = PIPSettings()
    var camera = CameraSettings()
    var demo = DemoSettings()
    var slides = SlidesSettings()
    var split = SplitSettings()
    var overlay = OverlaySettings()
}

enum LayoutBuilder {
    static func layout(for scene: SceneKind,
                       canvas: Canvas,
                       config: LayoutConfig,
                       pipVisibility: CGFloat,
                       face: CGPoint?) -> SceneLayout {
        var out = SceneLayout()
        out.watermark = (config.overlay.watermarkEnabled && config.overlay.watermarkScenes.contains(scene)) ? 1 : 0

        switch scene {
        case .camera:
            // Reuse the engine's smoothed face position while preserving the user's vertical framing.
            // The camera crop clamps to the source edges when the selected zoom leaves no pan room.
            let centerX = config.camera.faceTracking ? (face?.x ?? 0.5) : 0.5
            out.camera = CameraLayer(
                rect: canvas.bounds,
                cornerRadius: 0, opacity: 1, borderWidth: 0, shadow: 0,
                zoom: CGFloat(max(1, config.camera.fullZoom)),
                center: CGPoint(x: centerX + CGFloat(config.camera.fullOffsetX), y: 0.5 + CGFloat(config.camera.fullOffsetY)),
                featherLeft: 0, featherRight: 0, backgroundOpacity: 1)
            var slot = demoSlot(canvas: canvas, config: config)
            slot.opacity = 0
            out.content = slot

        case .slides:
            out.content = ContentSlot(rect: canvas.bounds, cornerRadius: 0, opacity: 1, shadow: 0,
                                      fill: (canvas.width < canvas.height ? config.slides.portraitFit : config.slides.fit) == .fill ? 1 : 0)
            out.camera = pipLayer(canvas: canvas, config: config, visibility: config.presenterVisible ? pipVisibility : 0, face: face)

        case .demo:
            out.content = demoSlot(canvas: canvas, config: config)
            out.camera = pipLayer(canvas: canvas, config: config, visibility: config.presenterVisible ? pipVisibility : 0, face: face)
            if canvas.width >= canvas.height && config.demo.avoidPIP && config.pip.shape != .cutout {
                let pip = pipRect(canvas: canvas, pip: config.pip)
                let gap = canvas.height * 0.025
                let v = config.presenterVisible ? clamp01(pipVisibility) : 0
                if config.pip.corner.isLeft {
                    out.content.avoidLeft = (pip.maxX + gap) * v
                } else {
                    out.content.avoidRightInset = (canvas.width - pip.minX + gap) * v
                }
            }

        case .split:
            out = canvas.width < canvas.height
                ? portraitSplitLayout(canvas: canvas, config: config, face: face, watermark: out.watermark)
                : splitLayout(canvas: canvas, config: config, face: face, watermark: out.watermark)
            if !config.presenterVisible {
                out.content = ContentSlot(rect: canvas.bounds, cornerRadius: 0, opacity: 1, shadow: 0,
                                          fill: config.split.fitContent ? 0 : 1)
                if canvas.width < canvas.height && config.split.content == .demo {
                    out.content.sourceCrop = portraitDemoCrop(config)
                }
            }
        }
        if !config.presenterVisible { out.camera.opacity = 0 }
        return out
    }

    /// Portrait splits reserve separate top and bottom regions, even when content is cropped to fill.
    private static func portraitSplitLayout(canvas: Canvas, config: LayoutConfig, face: CGPoint?, watermark: CGFloat) -> SceneLayout {
        let W = canvas.width, H = canvas.height
        let s = config.split
        let cameraAtBottom = s.portraitCameraAtBottom
        let cameraHeight = H * CGFloat(clamp(s.portraitPersonHeight, 0.18, 0.4))
        let pad = W * 0.055
        let gap = pad * 0.7
        let card = s.cardStyle && s.fitContent
        var cameraRect = CGRect(x: 0, y: cameraAtBottom ? H - cameraHeight : 0, width: W, height: cameraHeight)
        if card { cameraRect = cameraRect.insetBy(dx: pad, dy: pad) }
        var cx = 0.5 + CGFloat(s.personOffset)
        if config.camera.faceTracking, let f = face { cx = f.x + CGFloat(s.personOffset) }
        var out = SceneLayout()
        out.watermark = watermark
        out.camera = CameraLayer(rect: cameraRect,
                                 cornerRadius: card ? W * CGFloat(config.demo.cornerRadius) * 1.4 : 0,
                                 opacity: 1, borderWidth: 0, shadow: card && !s.cutout ? 1 : 0,
                                 zoom: CGFloat(max(1, s.personZoom)), center: CGPoint(x: cx, y: 0.5),
                                 backgroundOpacity: s.cutout ? 0 : 1)
        let contentHeight = H - cameraHeight
        let region = CGRect(x: 0, y: cameraAtBottom ? 0 : cameraHeight, width: W, height: contentHeight)
        let area = s.fitContent ? region.insetBy(dx: pad, dy: gap * 0.5) : region
        out.content = ContentSlot(rect: area, cornerRadius: s.fitContent ? W * CGFloat(config.demo.cornerRadius) : 0,
                                  opacity: 1, shadow: s.fitContent && config.demo.shadow ? 1 : 0,
                                  fill: s.fitContent ? 0 : 1)
        if s.content == .demo { out.content.sourceCrop = portraitDemoCrop(config) }
        return out
    }

    private static func portraitDemoCrop(_ config: LayoutConfig) -> CGRect {
        CGRect(x: 0, y: 0, width: config.demo.portraitFraming == .leftHalf ? 0.5 : 1, height: 1)
    }

    /// Presenter column on one side, content on the other.
    private static func splitLayout(canvas: Canvas, config: LayoutConfig, face: CGPoint?, watermark: CGFloat) -> SceneLayout {
        let W = canvas.width, H = canvas.height
        let s = config.split
        let onRight = s.cameraOnRight
        let cw = W * CGFloat(clamp(s.personWidth, 0.25, 0.6))
        let pad = H * 0.055
        let gap = pad * 0.7
        let card = s.cardStyle && s.fitContent

        // Presenter
        var camRect = onRight ? CGRect(x: W - cw, y: 0, width: cw, height: H) : CGRect(x: 0, y: 0, width: cw, height: H)
        var soft = s.cutout ? 0 : W * CGFloat(clamp(s.edgeSoftness, 0, 0.2))
        if card {
            camRect = onRight
                ? CGRect(x: W - cw + gap * 0.5, y: pad, width: cw - pad - gap * 0.5, height: H - pad * 2)
                : CGRect(x: pad, y: pad, width: cw - pad - gap * 0.5, height: H - pad * 2)
            soft = 0
        }
        var cx = 0.5 + CGFloat(s.personOffset)
        if config.camera.faceTracking, let f = face { cx = f.x + CGFloat(s.personOffset) }
        // Center the person in the opaque part of the column, so the shoulders never reach the faded edge.
        let w = camRect.width
        let anchor = w > 0 ? (onRight ? (soft + (w - soft) / 2) / w : ((w - soft) / 2) / w) : 0.5
        var layout = SceneLayout()
        layout.watermark = watermark
        layout.camera = CameraLayer(
            rect: camRect,
            cornerRadius: card ? W * CGFloat(config.demo.cornerRadius) * 1.4 : 0,
            opacity: 1, borderWidth: 0,
            shadow: card && !s.cutout ? 1 : 0,
            zoom: CGFloat(max(1, s.personZoom)),
            center: CGPoint(x: cx, y: 0.5),
            featherLeft: onRight ? soft : 0,
            featherRight: onRight ? 0 : soft,
            backgroundOpacity: s.cutout ? 0 : 1,
            anchorX: anchor)

        // Content
        if s.fitContent {
            let area = onRight
                ? CGRect(x: pad, y: pad, width: W - cw - pad - gap * 0.5, height: H - pad * 2)
                : CGRect(x: cw + gap * 0.5, y: pad, width: W - cw - pad - gap * 0.5, height: H - pad * 2)
            layout.content = ContentSlot(rect: area, cornerRadius: W * CGFloat(config.demo.cornerRadius),
                                         opacity: 1, shadow: config.demo.shadow ? 1 : 0, fill: 0)
        } else {
            layout.content = ContentSlot(rect: canvas.bounds, cornerRadius: 0, opacity: 1, shadow: 0, fill: 1)
        }
        return layout
    }

    static func demoSlot(canvas: Canvas, config: LayoutConfig) -> ContentSlot {
        let pad = min(canvas.width, canvas.height) * CGFloat(clamp(config.demo.padding, 0, 0.2))
        var top = pad, bottom = pad
        let o = config.overlay
        if o.watermarkEnabled && o.watermarkScenes.contains(.demo) {
            // Leave a header (or footer) band so the watermark never covers the demo.
            if o.watermarkCorner.isBottom { bottom = max(pad, canvas.height * 0.095) } else { top = max(pad, canvas.height * 0.095) }
        }
        let rect = CGRect(x: pad, y: top, width: canvas.width - pad * 2, height: canvas.height - top - bottom)
        return ContentSlot(rect: rect,
                           cornerRadius: canvas.width * CGFloat(config.demo.cornerRadius),
                           opacity: 1,
                           shadow: config.demo.shadow ? 1 : 0,
                           fill: 0,
                           alignX: CGFloat(config.demo.contentAlign),
                           sourceCrop: canvas.width < canvas.height ? portraitDemoCrop(config) : CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    /// The fully visible picture-in-picture rect for the current settings.
    static func pipRect(canvas: Canvas, pip: PIPSettings) -> CGRect {
        let W = canvas.width, H = canvas.height
        let relativeSize = W < H ? min(pip.size * 1.5, 0.4) : pip.size
        let d = W * CGFloat(clamp(relativeSize, 0.08, 0.4))
        let m = W * CGFloat(clamp(pip.margin, 0, 0.1))
        let size: CGSize
        switch pip.shape {
        case .circle: size = CGSize(width: d, height: d)
        case .rounded: size = CGSize(width: d * 1.35, height: d)
        case .cutout: size = CGSize(width: d * 1.3, height: d * 1.5)
        }
        let bottomMargin = pip.shape == .cutout ? 0 : m
        let x = pip.corner.isLeft ? m : W - m - size.width
        let y = pip.corner.isBottom ? H - bottomMargin - size.height : (pip.shape == .cutout ? 0 : m)
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    static func pipLayer(canvas: Canvas, config: LayoutConfig, visibility v: CGFloat, face: CGPoint?) -> CameraLayer {
        let pip = config.pip
        var rect = pipRect(canvas: canvas, pip: pip)
        let zoom = CGFloat(max(1, pip.zoom))
        var center = CGPoint(x: 0.5, y: 0.45)
        if config.camera.faceTracking, let f = face {
            // Keep the face a little above the middle of the bubble.
            center = CGPoint(x: f.x, y: f.y + 0.12 / zoom)
        }
        let radius: CGFloat
        switch pip.shape {
        case .circle: radius = rect.width / 2
        case .rounded: radius = rect.height * 0.14
        case .cutout: radius = 0
        }
        let scale = 0.55 + 0.45 * v
        let anchor = CGPoint(x: rect.midX, y: pip.shape == .cutout ? rect.maxY : rect.midY)
        rect = rect.scaled(by: scale, around: anchor)
        let border = pip.shape == .cutout ? 0 : CGFloat(pip.borderWidth) * canvas.unit
        return CameraLayer(
            rect: rect,
            cornerRadius: radius * scale,
            opacity: v,
            borderWidth: border * scale,
            shadow: (pip.shadow && pip.shape != .cutout) ? 1 : 0,
            zoom: zoom,
            center: center,
            featherLeft: 0, featherRight: 0,
            backgroundOpacity: pip.shape == .cutout ? 0 : 1)
    }
}

/// User zoom / pan of a content layer inside its slot (used for imported slides and PDF pages).
struct ContentViewport: Equatable {
    /// Relative to the slot's base fit/fill size.
    var scale: CGFloat = 1
    /// -1 … 1 across the overflow: -1 shows the left / top edge, 1 the right / bottom edge.
    var panX: CGFloat = 0
    var panY: CGFloat = 0

    func rect(base: CGRect, slot: CGRect) -> CGRect {
        let w = base.width * scale, h = base.height * scale
        let ox = max(0, w - slot.width) / 2
        let oy = max(0, h - slot.height) / 2
        return CGRect(x: slot.midX - w / 2 - panX * ox, y: slot.midY - h / 2 - panY * oy, width: w, height: h)
    }

    /// Tall pages that overflow the slot start at their top, like a document.
    static func initial(base: CGRect, slot: CGRect) -> ContentViewport {
        var v = ContentViewport()
        if base.height > slot.height + 1 { v.panY = -1 }
        return v
    }

    static func scaleLimits(base: CGRect, slot: CGRect, contentSize: CGSize) -> ClosedRange<CGFloat> {
        let fit = slot.aspectFit(contentSize)
        let minScale = min(1, fit.width / max(1, base.width))
        return minScale...max(3, minScale * 6)
    }

    mutating func pan(by d: CGVector, base: CGRect, slot: CGRect) {
        let ox = max(0, base.width * scale - slot.width) / 2
        let oy = max(0, base.height * scale - slot.height) / 2
        if ox > 0 { panX = clamp(panX - d.dx / ox, -1, 1) }
        if oy > 0 { panY = clamp(panY - d.dy / oy, -1, 1) }
    }

    /// Zooms by `factor` keeping the content point under `q` (output pixels) fixed.
    mutating func zoom(by factor: CGFloat, at q: CGPoint, base: CGRect, slot: CGRect, limits: ClosedRange<CGFloat>) {
        let r0 = rect(base: base, slot: slot)
        guard r0.width > 0, r0.height > 0 else { return }
        let c = CGPoint(x: (q.x - r0.minX) / r0.width, y: (q.y - r0.minY) / r0.height)
        let s1 = clamp(scale * factor, limits.lowerBound, limits.upperBound)
        let w = base.width * s1, h = base.height * s1
        let x1 = q.x - c.x * w, y1 = q.y - c.y * h
        let ox = max(0, w - slot.width) / 2
        let oy = max(0, h - slot.height) / 2
        scale = s1
        panX = ox > 0 ? clamp((slot.midX - w / 2 - x1) / ox, -1, 1) : 0
        panY = oy > 0 ? clamp((slot.midY - h / 2 - y1) / oy, -1, 1) : 0
    }
}

/// Camera crop rect (in camera pixel coordinates, top-left origin) for a layer.
/// `anchorX` is where the crop center point lands inside the layer (0.5 = middle).
func cameraCrop(cameraSize: CGSize, layerSize: CGSize, zoom: CGFloat, center: CGPoint, anchorX: CGFloat = 0.5) -> CGRect {
    guard cameraSize.width > 0, cameraSize.height > 0, layerSize.width > 0, layerSize.height > 0 else {
        return CGRect(origin: .zero, size: cameraSize)
    }
    let a = layerSize.width / layerSize.height
    let camA = cameraSize.width / cameraSize.height
    var w: CGFloat, h: CGFloat
    if a > camA {
        w = cameraSize.width
        h = w / a
    } else {
        h = cameraSize.height
        w = h * a
    }
    let z = max(1, zoom)
    w /= z
    h /= z
    let x = clamp(center.x * cameraSize.width - clamp01(anchorX) * w, 0, cameraSize.width - w)
    let cy = clamp(center.y * cameraSize.height, h / 2, cameraSize.height - h / 2)
    return CGRect(x: x, y: cy - h / 2, width: w, height: h)
}
