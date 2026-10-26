import Foundation
import CoreGraphics
import CoreImage
import CoreImage.CIFilterBuiltins

// MARK: - Math

@inline(__always) func clamp01(_ v: CGFloat) -> CGFloat { min(1, max(0, v)) }
@inline(__always) func clamp(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> CGFloat { min(hi, max(lo, v)) }
@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
    CGPoint(x: lerp(a.x, b.x, t), y: lerp(a.y, b.y, t))
}

func lerp(_ a: CGRect, _ b: CGRect, _ t: CGFloat) -> CGRect {
    CGRect(x: lerp(a.minX, b.minX, t), y: lerp(a.minY, b.minY, t),
           width: lerp(a.width, b.width, t), height: lerp(a.height, b.height, t))
}

enum Ease {
    static func inOutCubic(_ t: CGFloat) -> CGFloat {
        let t = clamp01(t)
        return t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }
    static func outCubic(_ t: CGFloat) -> CGFloat {
        let t = clamp01(t)
        return 1 - pow(1 - t, 3)
    }
    static func inCubic(_ t: CGFloat) -> CGFloat {
        let t = clamp01(t)
        return t * t * t
    }
    static func outBack(_ t: CGFloat) -> CGFloat {
        let t = clamp01(t)
        let c1: CGFloat = 1.4
        let c3 = c1 + 1
        return 1 + c3 * pow(t - 1, 3) + c1 * pow(t - 1, 2)
    }
    static func inOutQuart(_ t: CGFloat) -> CGFloat {
        let t = clamp01(t)
        return t < 0.5 ? 8 * t * t * t * t : 1 - pow(-2 * t + 2, 4) / 2
    }
}

/// A scalar that animates from its current value to a new target.
struct AnimatedValue {
    private(set) var from: CGFloat
    private(set) var to: CGFloat
    private var start: Double = 0
    private var duration: Double = 0
    var curve: (CGFloat) -> CGFloat = Ease.inOutCubic

    init(_ value: CGFloat) {
        from = value
        to = value
    }

    func value(at t: Double) -> CGFloat {
        guard duration > 0 else { return to }
        let p = CGFloat((t - start) / duration)
        if p >= 1 { return to }
        if p <= 0 { return from }
        return lerp(from, to, curve(p))
    }

    func isAnimating(at t: Double) -> Bool { duration > 0 && t < start + duration }

    mutating func animate(to target: CGFloat, at t: Double, duration d: Double, curve c: ((CGFloat) -> CGFloat)? = nil) {
        from = value(at: t)
        to = target
        start = t
        duration = max(0, d)
        if let c { curve = c }
    }

    mutating func set(_ v: CGFloat) {
        from = v
        to = v
        duration = 0
    }
}

// MARK: - Geometry

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Rect with the aspect ratio of `size`, fitted inside self and centered.
    func aspectFit(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, width > 0, height > 0 else { return self }
        let s = min(width / size.width, height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    /// Rect with the aspect ratio of `size`, covering self and centered.
    func aspectFill(_ size: CGSize) -> CGRect {
        guard size.width > 0, size.height > 0, width > 0, height > 0 else { return self }
        let s = max(width / size.width, height / size.height)
        let w = size.width * s, h = size.height * s
        return CGRect(x: midX - w / 2, y: midY - h / 2, width: w, height: h)
    }

    func scaled(by s: CGFloat, around c: CGPoint) -> CGRect {
        CGRect(x: c.x + (minX - c.x) * s, y: c.y + (minY - c.y) * s, width: width * s, height: height * s)
    }

    func offsetBy(_ p: CGPoint) -> CGRect { offsetBy(dx: p.x, dy: p.y) }
}

/// Output canvas. Layout math uses a top-left origin; Core Image uses bottom-left.
struct Canvas {
    let width: CGFloat
    let height: CGFloat

    var size: CGSize { CGSize(width: width, height: height) }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }
    /// Scale relative to a 1080p canvas, for pixel sized parameters.
    var unit: CGFloat { min(width, height) / 1080 }

    func ci(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }

    func ci(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: height - p.y) }
}

// MARK: - Core Image helpers

enum CIX {
    static let clear = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0))

    static func color(_ c: CIColor, _ rect: CGRect) -> CIImage {
        CIImage(color: c).cropped(to: rect)
    }

    static func roundedRect(_ rect: CGRect, radius: CGFloat, color: CIColor = .white) -> CIImage {
        guard rect.width > 0.5, rect.height > 0.5 else { return clear.cropped(to: .zero) }
        let r = max(0, min(radius, min(rect.width, rect.height) / 2))
        if r < 0.5 {
            return CIImage(color: color).cropped(to: rect)
        }
        let f = CIFilter.roundedRectangleGenerator()
        f.extent = rect
        f.radius = Float(r)
        f.color = color
        return (f.outputImage ?? clear).cropped(to: rect.insetBy(dx: -1, dy: -1))
    }

    /// Blurred drop shadow for a rounded rect, computed at quarter resolution for speed.
    static func shadow(for rect: CGRect, radius: CGFloat, blur: CGFloat, opacity: CGFloat, offset: CGPoint) -> CIImage {
        guard opacity > 0.001, rect.width > 1, rect.height > 1 else { return clear.cropped(to: .zero) }
        let k: CGFloat = 0.25
        let small = CGRect(x: rect.minX * k, y: rect.minY * k, width: rect.width * k, height: rect.height * k)
        let base = roundedRect(small, radius: radius * k, color: CIColor(red: 0, green: 0, blue: 0, alpha: opacity))
        let blurred = base.applyingGaussianBlur(sigma: Double(max(0.5, blur * k)))
        return blurred
            .transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
            .transformed(by: CGAffineTransform(translationX: offset.x, y: offset.y))
    }

    /// Alpha ramp along x: transparent at x0, opaque at x1 (x1 may be < x0 for a reversed ramp).
    static func horizontalRamp(from x0: CGFloat, to x1: CGFloat) -> CIImage {
        let f = CIFilter.smoothLinearGradient()
        f.point0 = CGPoint(x: x0, y: 0)
        f.point1 = CGPoint(x: x1, y: 0)
        f.color0 = CIColor(red: 1, green: 1, blue: 1, alpha: 0)
        f.color1 = CIColor(red: 1, green: 1, blue: 1, alpha: 1)
        return f.outputImage ?? clear
    }

    /// Anti-aliased ring (annulus) with outer radius `r` and width `w`.
    static func ring(center: CGPoint, radius r: CGFloat, width w: CGFloat, color: CIColor) -> CIImage {
        let outer = CIFilter.radialGradient()
        outer.center = center
        outer.radius0 = Float(max(0, r - 0.8))
        outer.radius1 = Float(r + 0.8)
        outer.color0 = color
        outer.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let inner = CIFilter.radialGradient()
        inner.center = center
        inner.radius0 = Float(max(0, r - w - 0.8))
        inner.radius1 = Float(max(0.1, r - w + 0.8))
        inner.color0 = .white
        inner.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let o = outer.outputImage, let i = inner.outputImage else { return clear }
        let ringImg = o.applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: i])
        let box = CGRect(x: center.x - r - 2, y: center.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)
        return ringImg.cropped(to: box)
    }

    static func disc(center: CGPoint, radius r: CGFloat, color: CIColor) -> CIImage {
        let f = CIFilter.radialGradient()
        f.center = center
        f.radius0 = Float(max(0, r - 0.8))
        f.radius1 = Float(r + 0.8)
        f.color0 = color
        f.color1 = CIColor(red: 0, green: 0, blue: 0, alpha: 0)
        let box = CGRect(x: center.x - r - 2, y: center.y - r - 2, width: 2 * r + 4, height: 2 * r + 4)
        return (f.outputImage ?? clear).cropped(to: box)
    }
}

extension CIImage {
    /// Crops `src` (in this image's coordinates) and maps it onto `dst`.
    func mapped(from src: CGRect, to dst: CGRect, highQuality: Bool = false) -> CIImage {
        guard src.width > 0, src.height > 0, dst.width > 0, dst.height > 0 else { return CIX.clear.cropped(to: .zero) }
        let sx = dst.width / src.width
        let sy = dst.height / src.height
        let base = cropped(to: src).clampedToExtent()
        let t = CGAffineTransform(translationX: -src.minX, y: -src.minY)
            .concatenating(CGAffineTransform(scaleX: sx, y: sy))
            .concatenating(CGAffineTransform(translationX: dst.minX, y: dst.minY))
        if highQuality && min(sx, sy) < 0.5 {
            return base.transformed(by: t, highQualityDownsample: true).cropped(to: dst)
        }
        return base.transformed(by: t).cropped(to: dst)
    }

    func opacity(_ a: CGFloat) -> CIImage {
        if a >= 0.999 { return self }
        if a <= 0.001 { return CIX.clear.cropped(to: .zero) }
        return applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: a)])
    }

    /// Keeps this image only where `mask` has alpha.
    func masked(by mask: CIImage) -> CIImage {
        applyingFilter("CISourceInCompositing", parameters: [kCIInputBackgroundImageKey: mask])
    }

    func mirroredHorizontally() -> CIImage {
        let e = extent
        return transformed(by: CGAffineTransform(scaleX: -1, y: 1).concatenating(CGAffineTransform(translationX: e.minX + e.maxX, y: 0)))
    }
}
