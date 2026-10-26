import Foundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo

/// One content layer to draw this frame (several during a transition).
struct ContentDraw: Equatable {
    var source: SourceRef
    var opacity: CGFloat = 1
    /// Offset in output pixels (top-left coordinates), used by push transitions.
    var offset: CGPoint = .zero
    /// Scale around the slot center, used by the "smooth" transition.
    var scale: CGFloat = 1
    /// User zoom / pan (slides).
    var viewport: ContentViewport? = nil
}

struct ZoomState: Equatable {
    var factor: CGFloat = 1
    /// Normalized center in the source (top-left origin).
    var center = CGPoint(x: 0.5, y: 0.5)
}

struct ClickMark: Equatable {
    var source: SourceRef
    /// Normalized position in the source (top-left origin).
    var point: CGPoint
    var age: Double
}

struct FrameDescription: Equatable {
    var layout = SceneLayout()
    var contents: [ContentDraw] = []
    var zoom: [SourceRef: ZoomState] = [:]
    var clicks: [ClickMark] = []
    /// 0 = hidden, 1 = fully shown.
    var lowerThird: CGFloat = 0
    var lowerThirdAnchor: CGPoint = .zero
    var watermarkCorner: Corner = .topLeft
    var watermarkLightText = false
}

struct FrameInputs {
    var camera: CameraFrame?
    /// Upright content images with extent origin at zero.
    var contents: [SourceRef: CIImage] = [:]
}

final class Compositor {
    let context: CIContext
    let canvas: Canvas
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    var backdrop: CIImage
    var cameraPlaceholder: CIImage?
    var sourcePlaceholder: CIImage?
    var watermarkLight: CIImage?
    var watermarkDark: CIImage?
    var lowerThirdImage: CIImage?
    var borderColor: CIColor = .white
    var clickColor: CIColor = CIColor(red: 1, green: 0.78, blue: 0.22)

    init(context: CIContext, canvas: Canvas) {
        self.context = context
        self.canvas = canvas
        backdrop = CIImage(color: CIColor(red: 0.96, green: 0.95, blue: 0.99)).cropped(to: canvas.bounds)
    }

    // MARK: - Compose

    func compose(_ fd: FrameDescription, _ inputs: FrameInputs) -> CIImage {
        let unit = canvas.unit
        var out = backdrop
        var drawn: [SourceRef: (rect: CGRect, crop: CGRect, opacity: CGFloat, visible: CGRect, radius: CGFloat)] = [:]

        // Content layers
        let slot = fd.layout.content
        if slot.opacity > 0.003 {
            for d in fd.contents where d.opacity > 0.003 {
                let img = inputs.contents[d.source] ?? sourcePlaceholder ?? CIX.color(CIColor(red: 0.9, green: 0.9, blue: 0.92), canvas.bounds)
                let size = img.extent.size
                guard size.width > 1, size.height > 1 else { continue }
                let z = fd.zoom[d.source] ?? ZoomState()
                let cropN = Self.contentCrop(slot.sourceCrop, zoom: z)
                let cropCI = CGRect(x: img.extent.minX + cropN.minX * size.width,
                                    y: img.extent.minY + (1 - cropN.maxY) * size.height,
                                    width: cropN.width * size.width, height: cropN.height * size.height)
                // Zoom retains the selected region's aspect ratio; a half-screen source is narrower.
                let framedSize = CGSize(width: size.width * slot.sourceCrop.width, height: size.height * slot.sourceCrop.height)
                let fit = slot.rect.aspectFit(framedSize)
                let fill = slot.rect.aspectFill(framedSize)
                var rect = slot.aligned(lerp(fit, fill, slot.fill), canvasWidth: canvas.width)
                if let vp = d.viewport { rect = vp.rect(base: rect, slot: slot.rect) }
                rect = rect.scaled(by: d.scale, around: slot.rect.center).offsetBy(d.offset)
                let clipSlot = slot.rect.scaled(by: d.scale, around: slot.rect.center).offsetBy(d.offset)
                let visible = rect.intersection(clipSlot)
                guard !visible.isNull, visible.width > 1, visible.height > 1 else { continue }
                let alpha = slot.opacity * d.opacity
                var layer = img.mapped(from: cropCI, to: canvas.ci(rect), highQuality: true)
                let radius = slot.cornerRadius * d.scale
                layer = layer.masked(by: CIX.roundedRect(canvas.ci(visible), radius: radius))
                if slot.shadow > 0.01 {
                    let sh = CIX.shadow(for: canvas.ci(visible), radius: radius, blur: 26 * unit,
                                        opacity: 0.2 * slot.shadow, offset: CGPoint(x: 0, y: -10 * unit))
                    layer = layer.composited(over: sh)
                }
                out = layer.opacity(alpha).composited(over: out)
                drawn[d.source] = (rect, cropN, alpha, visible, radius)
            }
        }

        // Click highlights on capture sources
        for c in fd.clicks {
            guard let info = drawn[c.source], info.opacity > 0.3 else { continue }
            let crop = info.crop
            guard crop.contains(c.point) else { continue }
            let px = info.rect.minX + (c.point.x - crop.minX) / crop.width * info.rect.width
            let py = info.rect.minY + (c.point.y - crop.minY) / crop.height * info.rect.height
            guard info.visible.contains(CGPoint(x: px, y: py)) else { continue }
            let p = CGFloat(min(1, c.age / 0.6))
            let e = Ease.outCubic(p)
            let center = canvas.ci(CGPoint(x: px, y: py))
            let r = (14 + 34 * e) * unit
            let a = (1 - p) * info.opacity
            let ring = CIX.ring(center: center, radius: r, width: 4 * unit, color: clickColor).opacity(0.9 * a)
            let dot = CIX.disc(center: center, radius: (16 - 6 * e) * unit, color: clickColor).opacity(0.35 * a)
            let highlight = ring.composited(over: dot).masked(by: CIX.roundedRect(canvas.ci(info.visible), radius: info.radius))
            out = highlight.composited(over: out)
        }

        // Presenter
        out = drawCamera(fd.layout.camera, inputs.camera, over: out)

        // Lower third (name tag)
        if fd.lowerThird > 0.003, let lt = lowerThirdImage {
            let e = Ease.outCubic(fd.lowerThird)
            let size = lt.extent.size
            let topLeft = CGPoint(x: fd.lowerThirdAnchor.x - 40 * unit * (1 - e), y: fd.lowerThirdAnchor.y - size.height)
            let dst = canvas.ci(CGRect(origin: topLeft, size: size))
            let placed = lt.transformed(by: CGAffineTransform(translationX: dst.minX - lt.extent.minX, y: dst.minY - lt.extent.minY))
            out = placed.opacity(e).composited(over: out)
        }

        // Watermark
        if fd.layout.watermark > 0.003, let wm = fd.watermarkLightText ? watermarkLight : watermarkDark {
            let size = wm.extent.size
            let m = CGPoint(x: canvas.width * 0.028, y: canvas.height * 0.045)
            let x = fd.watermarkCorner.isLeft ? m.x : canvas.width - m.x - size.width
            let y = fd.watermarkCorner.isBottom ? canvas.height - m.y - size.height : m.y
            let dst = canvas.ci(CGRect(x: x, y: y, width: size.width, height: size.height))
            let placed = wm.transformed(by: CGAffineTransform(translationX: dst.minX - wm.extent.minX, y: dst.minY - wm.extent.minY))
            out = placed.opacity(fd.layout.watermark).composited(over: out)
        }

        return out.cropped(to: canvas.bounds)
    }

    private func drawCamera(_ cam: CameraLayer, _ frame: CameraFrame?, over base: CIImage) -> CIImage {
        guard cam.opacity > 0.003, cam.rect.width > 2, cam.rect.height > 2 else { return base }
        let unit = canvas.unit
        let processed: CIImage
        var cutout: CIImage? = nil
        if let f = frame {
            processed = CIImage(cvPixelBuffer: f.processed)
            if let c = f.cutout { cutout = CIImage(cvPixelBuffer: c) }
        } else if let ph = cameraPlaceholder {
            processed = ph
        } else {
            processed = CIX.color(CIColor(red: 0.1, green: 0.1, blue: 0.12), CGRect(x: 0, y: 0, width: 1280, height: 720))
        }
        let camSize = processed.extent.size
        let cropTL = cameraCrop(cameraSize: camSize, layerSize: cam.rect.size, zoom: cam.zoom, center: cam.center, anchorX: cam.anchorX)
        let cropCI = CGRect(x: cropTL.minX, y: camSize.height - cropTL.maxY, width: cropTL.width, height: cropTL.height)
        let dst = canvas.ci(cam.rect)

        var layer = processed.mapped(from: cropCI, to: dst)
        if cam.backgroundOpacity < 0.999 {
            if let cut = cutout {
                let cutLayer = cut.mapped(from: cropCI, to: dst)
                if cam.backgroundOpacity <= 0.001 {
                    layer = cutLayer
                } else {
                    layer = cutLayer.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputTargetImageKey: layer,
                        kCIInputTimeKey: cam.backgroundOpacity,
                    ]).cropped(to: dst)
                }
            }
        }
        if cam.featherLeft > 0.5 {
            layer = layer.masked(by: CIX.horizontalRamp(from: dst.minX, to: dst.minX + cam.featherLeft))
        }
        if cam.featherRight > 0.5 {
            layer = layer.masked(by: CIX.horizontalRamp(from: dst.maxX, to: dst.maxX - cam.featherRight))
        }
        if cam.cornerRadius > 0.5 {
            layer = layer.masked(by: CIX.roundedRect(dst, radius: cam.cornerRadius))
        }
        var group = layer
        let bw = cam.borderWidth
        if bw > 0.3 {
            let ring = CIX.roundedRect(dst.insetBy(dx: -bw, dy: -bw), radius: cam.cornerRadius + bw, color: borderColor)
            group = group.composited(over: ring)
        }
        if cam.shadow > 0.01 {
            let sh = CIX.shadow(for: dst.insetBy(dx: -bw, dy: -bw), radius: cam.cornerRadius + bw, blur: 20 * unit,
                                opacity: 0.32 * cam.shadow, offset: CGPoint(x: 0, y: -7 * unit))
            group = group.composited(over: sh)
        }
        return group.opacity(cam.opacity).composited(over: base)
    }

    static func zoomCrop(_ z: ZoomState) -> CGRect {
        let f = max(1, z.factor)
        let w = 1 / f
        let x = clamp(z.center.x - w / 2, 0, 1 - w)
        let y = clamp(z.center.y - w / 2, 0, 1 - w)
        return CGRect(x: x, y: y, width: w, height: w)
    }

    /// Keep zoom and click coordinates in the full source's coordinate system.
    static func contentCrop(_ sourceCrop: CGRect, zoom: ZoomState) -> CGRect {
        let region = sourceCrop.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !region.isNull, region.width > 0, region.height > 0 else { return zoomCrop(zoom) }
        let factor = max(1, zoom.factor)
        let w = region.width / factor, h = region.height / factor
        let x = clamp(zoom.center.x - w / 2, region.minX, region.maxX - w)
        let y = clamp(zoom.center.y - h / 2, region.minY, region.maxY - h)
        return CGRect(x: x, y: y, width: w, height: h)
    }

    // MARK: - Output

    func render(_ image: CIImage, to pb: CVPixelBuffer) {
        context.render(image, to: pb, bounds: canvas.bounds, colorSpace: srgb)
    }

    func makeOutputPool() -> CVPixelBufferPool? {
        CameraProcessor.makePool(canvas.size)
    }
}
