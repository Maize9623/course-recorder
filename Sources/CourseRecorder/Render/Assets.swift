import Foundation
import AppKit
import CoreGraphics
import CoreImage
import CoreText
import ImageIO

struct BackdropPreset: Identifiable, Hashable {
    let id: String
    let name: String
    let colors: [RGBA]
    let isDark: Bool
}

enum AssetCatalog {
    static let demoBackdrops: [BackdropPreset] = [
        BackdropPreset(id: "lavender", name: "薰衣草", colors: [RGBA(r: 0.98, g: 0.97, b: 1), RGBA(r: 0.88, g: 0.83, b: 0.97)], isDark: false),
        BackdropPreset(id: "aurora", name: "极光夜", colors: [RGBA(r: 0.05, g: 0.05, b: 0.12), RGBA(r: 0.36, g: 0.2, b: 0.75)], isDark: true),
        BackdropPreset(id: "peach", name: "蜜桃", colors: [RGBA(r: 1, g: 0.96, b: 0.93), RGBA(r: 1, g: 0.8, b: 0.72)], isDark: false),
        BackdropPreset(id: "mint", name: "薄荷", colors: [RGBA(r: 0.95, g: 0.99, b: 0.97), RGBA(r: 0.72, g: 0.91, b: 0.83)], isDark: false),
        BackdropPreset(id: "graphite", name: "石墨", colors: [RGBA(r: 0.11, g: 0.11, b: 0.13), RGBA(r: 0.24, g: 0.25, b: 0.29)], isDark: true),
        BackdropPreset(id: "white", name: "纯白", colors: [RGBA(r: 1, g: 1, b: 1), RGBA(r: 0.94, g: 0.94, b: 0.96)], isDark: false),
    ]

    static let cameraBackgrounds: [BackdropPreset] = [
        BackdropPreset(id: "studio-purple", name: "紫夜工作室", colors: [RGBA(r: 0.17, g: 0.08, b: 0.32), RGBA(r: 0.9, g: 0.4, b: 0.85)], isDark: true),
        BackdropPreset(id: "study-warm", name: "暖光书房", colors: [RGBA(r: 0.42, g: 0.29, b: 0.21), RGBA(r: 1, g: 0.85, b: 0.6)], isDark: true),
        BackdropPreset(id: "tech-blue", name: "深蓝科技", colors: [RGBA(r: 0.03, g: 0.07, b: 0.15), RGBA(r: 0.2, g: 0.75, b: 1)], isDark: true),
        BackdropPreset(id: "minimal-gray", name: "极简灰", colors: [RGBA(r: 0.92, g: 0.92, b: 0.94), RGBA(r: 0.76, g: 0.77, b: 0.81)], isDark: false),
        BackdropPreset(id: "brand-lavender", name: "品牌浅紫", colors: [RGBA(r: 0.98, g: 0.97, b: 1), RGBA(r: 0.8, g: 0.72, b: 0.95)], isDark: false),
    ]

    static func demoBackdropIsDark(_ id: String) -> Bool {
        demoBackdrops.first { $0.id == id }?.isDark ?? false
    }
}

/// Seeded RNG so procedural backgrounds look the same every launch.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 11) & ((1 << 53) - 1)) / Double(1 << 53)
    }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * next() }
}

final class AssetFactory {
    let context: CIContext
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

    init(context: CIContext) {
        self.context = context
    }

    // MARK: Bitmap helpers

    func makeContext(_ size: CGSize) -> CGContext? {
        CGContext(data: nil, width: Int(size.width), height: Int(size.height), bitsPerComponent: 8, bytesPerRow: 0,
                  space: srgb, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    }

    func bake(_ image: CIImage, size: CGSize) -> CGImage? {
        context.createCGImage(image.cropped(to: CGRect(origin: .zero, size: size)), from: CGRect(origin: .zero, size: size), format: .RGBA8, colorSpace: srgb)
    }

    func loadImage(path: String) -> CGImage? {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }

    /// Draws `image` aspect-filled into a new bitmap of `size`.
    func fill(_ image: CGImage, size: CGSize) -> CGImage? {
        guard let ctx = makeContext(size) else { return nil }
        let r = CGRect(origin: .zero, size: size).aspectFill(CGSize(width: image.width, height: image.height))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: r)
        return ctx.makeImage()
    }

    private func linearGradient(_ ctx: CGContext, _ colors: [RGBA], from: CGPoint, to: CGPoint) {
        let cgColors = colors.map { $0.cgColor } as CFArray
        guard let g = CGGradient(colorsSpace: srgb, colors: cgColors, locations: nil) else { return }
        ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    }

    private func glow(_ ctx: CGContext, _ color: RGBA, center: CGPoint, radius: CGFloat) {
        let colors = [color.cgColor, color.withAlpha(0).cgColor] as CFArray
        guard let g = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 1]) else { return }
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }

    // MARK: Demo backdrops

    func demoBackdrop(id: String, customPath: String, size: CGSize) -> CGImage? {
        if id == "custom", !customPath.isEmpty, let img = loadImage(path: customPath) {
            return fill(img, size: size)
        }
        guard let ctx = makeContext(size) else { return nil }
        let W = size.width, H = size.height
        // CG origin is bottom-left here.
        switch id {
        case "aurora":
            linearGradient(ctx, [RGBA(r: 0.04, g: 0.05, b: 0.11), RGBA(r: 0.08, g: 0.07, b: 0.2)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
            glow(ctx, RGBA(r: 0.49, g: 0.23, b: 0.93, a: 0.45), center: CGPoint(x: W * 0.12, y: H * 0.05), radius: W * 0.55)
            glow(ctx, RGBA(r: 0.15, g: 0.39, b: 0.92, a: 0.35), center: CGPoint(x: W * 0.9, y: H * 0.95), radius: W * 0.5)
        case "peach":
            linearGradient(ctx, [RGBA(r: 1, g: 0.97, b: 0.95), RGBA(r: 1, g: 0.88, b: 0.83)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
            glow(ctx, RGBA(r: 1, g: 0.72, b: 0.62, a: 0.55), center: CGPoint(x: W * 0.88, y: H * 0.08), radius: W * 0.6)
        case "mint":
            linearGradient(ctx, [RGBA(r: 0.96, g: 0.99, b: 0.98), RGBA(r: 0.84, g: 0.95, b: 0.9)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
            glow(ctx, RGBA(r: 0.62, g: 0.88, b: 0.78, a: 0.55), center: CGPoint(x: W * 0.88, y: H * 0.08), radius: W * 0.6)
        case "graphite":
            linearGradient(ctx, [RGBA(r: 0.1, g: 0.1, b: 0.12), RGBA(r: 0.18, g: 0.19, b: 0.22)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
            glow(ctx, RGBA(r: 0.35, g: 0.37, b: 0.45, a: 0.35), center: CGPoint(x: W * 0.8, y: H * 0.9), radius: W * 0.55)
        case "white":
            linearGradient(ctx, [RGBA(r: 1, g: 1, b: 1), RGBA(r: 0.95, g: 0.95, b: 0.97)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
        default: // lavender
            linearGradient(ctx, [RGBA(r: 0.99, g: 0.98, b: 1), RGBA(r: 0.93, g: 0.9, b: 0.98)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
            glow(ctx, RGBA(r: 0.83, g: 0.74, b: 0.96, a: 0.75), center: CGPoint(x: W * 0.92, y: H * 0.02), radius: W * 0.62)
            glow(ctx, RGBA(r: 1, g: 1, b: 1, a: 0.9), center: CGPoint(x: W * 0.08, y: H * 0.98), radius: W * 0.45)
            drawGrid(ctx, size: size, color: RGBA(r: 0.48, g: 0.38, b: 0.78), maxAlpha: 0.06)
        }
        return ctx.makeImage()
    }

    private func drawGrid(_ ctx: CGContext, size: CGSize, color: RGBA, maxAlpha: Double) {
        let step = size.height / 18
        ctx.setLineWidth(max(1, size.height / 1080))
        var y: CGFloat = 0
        while y < size.height * 0.45 {
            let a = maxAlpha * Double(1 - y / (size.height * 0.45))
            ctx.setStrokeColor(color.withAlpha(a).cgColor)
            ctx.move(to: CGPoint(x: 0, y: y))
            ctx.addLine(to: CGPoint(x: size.width, y: y))
            ctx.strokePath()
            y += step
        }
        var x: CGFloat = 0
        while x <= size.width {
            ctx.saveGState()
            let colors = [color.withAlpha(maxAlpha).cgColor, color.withAlpha(0).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: srgb, colors: colors, locations: [0, 1]) {
                ctx.addRect(CGRect(x: x, y: 0, width: max(1, size.height / 1080), height: size.height * 0.45))
                ctx.clip()
                ctx.drawLinearGradient(g, start: CGPoint(x: x, y: 0), end: CGPoint(x: x, y: size.height * 0.45), options: [])
            }
            ctx.restoreGState()
            x += step
        }
    }

    // MARK: Virtual camera backgrounds

    func cameraBackground(id: String, customPath: String, size: CGSize) -> CGImage? {
        if id == "custom", !customPath.isEmpty, let img = loadImage(path: customPath) {
            return fill(img, size: size)
        }
        guard let ctx = makeContext(size) else { return nil }
        let W = size.width, H = size.height
        var rng = SeededRandom(seed: 42)
        var blurSigma: Double = 5
        switch id {
        case "study-warm":
            linearGradient(ctx, [RGBA(r: 0.3, g: 0.2, b: 0.15), RGBA(r: 0.5, g: 0.35, b: 0.25)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: H * 0.25))
            ctx.setFillColor(RGBA(r: 0.2, g: 0.13, b: 0.1).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.24))
            // Window light
            glow(ctx, RGBA(r: 1, g: 0.88, b: 0.66, a: 0.85), center: CGPoint(x: W * 0.12, y: H * 0.7), radius: W * 0.28)
            ctx.setFillColor(RGBA(r: 1, g: 0.93, b: 0.8, a: 0.55).cgColor)
            ctx.fill(CGRect(x: W * 0.04, y: H * 0.42, width: W * 0.16, height: H * 0.5))
            // Bookshelves with book spines
            for shelf in 0..<2 {
                let sx = shelf == 0 ? W * 0.62 : W * 0.26
                let sw = W * 0.3
                ctx.setFillColor(RGBA(r: 0.24, g: 0.16, b: 0.11).cgColor)
                ctx.fill(CGRect(x: sx, y: H * 0.24, width: sw, height: H * 0.62))
                for row in 0..<4 {
                    let ry = H * 0.28 + CGFloat(row) * H * 0.145
                    ctx.setFillColor(RGBA(r: 0.36, g: 0.25, b: 0.17).cgColor)
                    ctx.fill(CGRect(x: sx, y: ry - H * 0.012, width: sw, height: H * 0.012))
                    var bx = sx + W * 0.008
                    while bx < sx + sw - W * 0.02 {
                        let bw = CGFloat(rng.range(Double(W) * 0.008, Double(W) * 0.018))
                        let bh = CGFloat(rng.range(Double(H) * 0.08, Double(H) * 0.12))
                        let hue = rng.range(0.0, 1.0)
                        let c = NSColor(hue: hue, saturation: 0.35, brightness: rng.range(0.45, 0.8), alpha: 1)
                        ctx.setFillColor(c.cgColor)
                        ctx.fill(CGRect(x: bx, y: ry, width: bw, height: bh))
                        bx += bw + CGFloat(rng.range(1, 4))
                    }
                }
            }
            glow(ctx, RGBA(r: 1, g: 0.78, b: 0.45, a: 0.65), center: CGPoint(x: W * 0.93, y: H * 0.62), radius: W * 0.16)
            for _ in 0..<26 {
                let c = RGBA(r: 1, g: rng.range(0.7, 0.9), b: rng.range(0.4, 0.6), a: rng.range(0.15, 0.4))
                glow(ctx, c, center: CGPoint(x: rng.range(0, Double(W)), y: rng.range(Double(H) * 0.3, Double(H))), radius: CGFloat(rng.range(Double(H) * 0.01, Double(H) * 0.04)))
            }
            blurSigma = 7
        case "tech-blue":
            linearGradient(ctx, [RGBA(r: 0.02, g: 0.05, b: 0.12), RGBA(r: 0.05, g: 0.16, b: 0.34)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
            glow(ctx, RGBA(r: 0.1, g: 0.6, b: 1, a: 0.45), center: CGPoint(x: W * 0.5, y: H * 0.62), radius: W * 0.45)
            ctx.setStrokeColor(RGBA(r: 0.25, g: 0.8, b: 1, a: 0.28).cgColor)
            ctx.setLineWidth(max(1, H / 540))
            let horizon = H * 0.32
            for i in -14...14 {
                ctx.move(to: CGPoint(x: W / 2 + CGFloat(i) * W * 0.012, y: horizon))
                ctx.addLine(to: CGPoint(x: W / 2 + CGFloat(i) * W * 0.12, y: 0))
            }
            var y = horizon
            var gap = H * 0.012
            while y > 0 {
                ctx.move(to: CGPoint(x: 0, y: y))
                ctx.addLine(to: CGPoint(x: W, y: y))
                y -= gap
                gap *= 1.35
            }
            ctx.strokePath()
            for i in 0..<7 {
                let x = W * (0.08 + CGFloat(i) * 0.14)
                ctx.setFillColor(RGBA(r: 0.3, g: 0.85, b: 1, a: 0.18).cgColor)
                ctx.fill(CGRect(x: x, y: horizon, width: W * 0.004, height: H * CGFloat(rng.range(0.25, 0.55))))
            }
            for _ in 0..<20 {
                glow(ctx, RGBA(r: 0.4, g: 0.85, b: 1, a: rng.range(0.15, 0.35)), center: CGPoint(x: rng.range(0, Double(W)), y: rng.range(Double(H) * 0.4, Double(H))), radius: CGFloat(rng.range(Double(H) * 0.008, Double(H) * 0.03)))
            }
            blurSigma = 3.5
        case "minimal-gray":
            linearGradient(ctx, [RGBA(r: 0.94, g: 0.94, b: 0.95), RGBA(r: 0.8, g: 0.81, b: 0.84)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
            glow(ctx, RGBA(r: 1, g: 1, b: 1, a: 0.85), center: CGPoint(x: W * 0.5, y: H * 0.62), radius: W * 0.42)
            blurSigma = 0
        case "brand-lavender":
            linearGradient(ctx, [RGBA(r: 0.98, g: 0.97, b: 1), RGBA(r: 0.88, g: 0.83, b: 0.97)], from: CGPoint(x: 0, y: H), to: CGPoint(x: W, y: 0))
            glow(ctx, RGBA(r: 1, g: 1, b: 1, a: 0.95), center: CGPoint(x: W * 0.5, y: H * 0.6), radius: W * 0.4)
            glow(ctx, RGBA(r: 0.75, g: 0.62, b: 0.95, a: 0.5), center: CGPoint(x: W * 0.95, y: H * 0.05), radius: W * 0.5)
            blurSigma = 0
        default: // studio-purple
            linearGradient(ctx, [RGBA(r: 0.2, g: 0.09, b: 0.38), RGBA(r: 0.3, g: 0.15, b: 0.52), RGBA(r: 0.22, g: 0.11, b: 0.42)],
                           from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: H * 0.22))
            ctx.setFillColor(RGBA(r: 0.13, g: 0.08, b: 0.24).cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: W, height: H * 0.22))
            linearGradient(ctx, [RGBA(r: 0.2, g: 0.12, b: 0.34, a: 0.0), RGBA(r: 0.1, g: 0.06, b: 0.2, a: 0.8)], from: CGPoint(x: 0, y: H * 0.22), to: CGPoint(x: 0, y: 0))
            // Left shelf
            ctx.setFillColor(RGBA(r: 0.16, g: 0.08, b: 0.3).cgColor)
            ctx.fill(CGRect(x: W * 0.02, y: H * 0.22, width: W * 0.3, height: H * 0.5))
            ctx.setFillColor(RGBA(r: 0.32, g: 0.18, b: 0.5).cgColor)
            for r in 0..<3 {
                ctx.fill(CGRect(x: W * 0.02, y: H * (0.3 + CGFloat(r) * 0.15), width: W * 0.3, height: H * 0.012))
            }
            // Right cabinet
            ctx.setFillColor(RGBA(r: 0.24, g: 0.14, b: 0.4).cgColor)
            ctx.fill(CGRect(x: W * 0.68, y: H * 0.22, width: W * 0.3, height: H * 0.3))
            ctx.setFillColor(RGBA(r: 0.62, g: 0.56, b: 0.72).cgColor)
            ctx.fill(CGRect(x: W * 0.86, y: H * 0.23, width: W * 0.12, height: H * 0.28))
            ctx.setFillColor(RGBA(r: 0.2, g: 0.11, b: 0.36).cgColor)
            ctx.fill(CGRect(x: W * 0.7, y: H * 0.56, width: W * 0.28, height: H * 0.3))
            // Shelf items
            for _ in 0..<14 {
                let x = CGFloat(rng.range(Double(W) * 0.04, Double(W) * 0.3))
                let row = Int(rng.range(0, 3))
                let y = H * (0.312 + CGFloat(row) * 0.15)
                let w = CGFloat(rng.range(Double(W) * 0.012, Double(W) * 0.03))
                let h = CGFloat(rng.range(Double(H) * 0.03, Double(H) * 0.09))
                ctx.setFillColor(RGBA(r: rng.range(0.35, 0.7), g: rng.range(0.25, 0.45), b: rng.range(0.55, 0.85), a: 0.9).cgColor)
                ctx.fill(CGRect(x: x, y: y, width: w, height: h))
            }
            // Neon signs
            let neon = CGPoint(x: W * 0.87, y: H * 0.8)
            glow(ctx, RGBA(r: 1, g: 0.4, b: 0.9, a: 0.6), center: neon, radius: H * 0.16)
            ctx.setStrokeColor(RGBA(r: 1, g: 0.75, b: 0.97, a: 1).cgColor)
            ctx.setLineWidth(H * 0.008)
            ctx.setLineCap(.round)
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3
                ctx.move(to: neon)
                ctx.addLine(to: CGPoint(x: neon.x + cos(a) * H * 0.075, y: neon.y + sin(a) * H * 0.075))
            }
            ctx.strokePath()
            let neon2 = CGPoint(x: W * 0.2, y: H * 0.62)
            glow(ctx, RGBA(r: 0.75, g: 0.85, b: 1, a: 0.5), center: neon2, radius: H * 0.09)
            ctx.setStrokeColor(RGBA(r: 0.92, g: 0.95, b: 1, a: 1).cgColor)
            ctx.setLineWidth(H * 0.006)
            ctx.stroke(CGRect(x: neon2.x - H * 0.04, y: neon2.y - H * 0.03, width: H * 0.08, height: H * 0.06))
            let neon3 = CGPoint(x: W * 0.22, y: H * 0.35)
            glow(ctx, RGBA(r: 1, g: 0.35, b: 0.85, a: 0.55), center: neon3, radius: H * 0.1)
            for _ in 0..<30 {
                let c = RGBA(r: rng.range(0.7, 1), g: rng.range(0.3, 0.6), b: rng.range(0.8, 1), a: rng.range(0.12, 0.35))
                glow(ctx, c, center: CGPoint(x: rng.range(0, Double(W)), y: rng.range(Double(H) * 0.2, Double(H))), radius: CGFloat(rng.range(Double(H) * 0.01, Double(H) * 0.035)))
            }
            blurSigma = 6
        }
        guard let raw = ctx.makeImage() else { return nil }
        if blurSigma <= 0 { return raw }
        let ci = CIImage(cgImage: raw).clampedToExtent().applyingGaussianBlur(sigma: blurSigma * Double(H) / 1080)
        return bake(ci, size: size) ?? raw
    }

    // MARK: Placeholders

    func cameraPlaceholder(size: CGSize) -> CGImage? {
        guard let ctx = makeContext(size) else { return nil }
        let W = size.width, H = size.height
        linearGradient(ctx, [RGBA(r: 0.12, g: 0.12, b: 0.16), RGBA(r: 0.07, g: 0.07, b: 0.09)], from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
        ctx.setFillColor(RGBA(r: 0.3, g: 0.3, b: 0.36).cgColor)
        let r = H * 0.11
        ctx.fillEllipse(in: CGRect(x: W / 2 - r, y: H * 0.56, width: r * 2, height: r * 2))
        ctx.fillEllipse(in: CGRect(x: W / 2 - r * 2.1, y: H * 0.18, width: r * 4.2, height: r * 3.2))
        drawText("摄像头未开启", size: H * 0.045, weight: .semibold, color: RGBA(r: 0.85, g: 0.85, b: 0.9), center: CGPoint(x: W / 2, y: H * 0.1), in: ctx)
        return ctx.makeImage()
    }

    func sourcePlaceholder(size: CGSize, title: String, detail: String, dark: Bool) -> CGImage? {
        guard let ctx = makeContext(size) else { return nil }
        let W = size.width, H = size.height
        let bg = dark ? [RGBA(r: 0.12, g: 0.12, b: 0.15), RGBA(r: 0.08, g: 0.08, b: 0.1)] : [RGBA(r: 0.97, g: 0.97, b: 0.99), RGBA(r: 0.92, g: 0.91, b: 0.96)]
        linearGradient(ctx, bg, from: CGPoint(x: 0, y: H), to: CGPoint(x: 0, y: 0))
        let fg = dark ? RGBA(r: 0.9, g: 0.9, b: 0.95) : RGBA(r: 0.2, g: 0.18, b: 0.3)
        drawText(title, size: H * 0.05, weight: .semibold, color: fg, center: CGPoint(x: W / 2, y: H * 0.54), in: ctx)
        drawText(detail, size: H * 0.026, weight: .regular, color: fg.withAlpha(0.6), center: CGPoint(x: W / 2, y: H * 0.45), in: ctx)
        return ctx.makeImage()
    }

    // MARK: Text overlays

    func watermark(title: String, subtitle: String, accent: RGBA, dark: Bool, unit: CGFloat) -> CGImage? {
        let textColor = dark ? RGBA(r: 1, g: 1, b: 1, a: 0.95) : RGBA(r: 0.16, g: 0.14, b: 0.25, a: 0.92)
        let subColor = textColor.withAlpha(0.65)
        let titleFont = font(size: 26 * unit, weight: .medium)
        let subFont = font(size: 22 * unit, weight: .regular)
        let tLine = line(title, font: titleFont, color: textColor, kern: 2.5 * unit)
        let sLine = line(subtitle, font: subFont, color: subColor, kern: 0)
        let tw = lineWidth(tLine), sw = subtitle.isEmpty ? 0 : lineWidth(sLine)
        let box: CGFloat = 22 * unit
        let gap: CGFloat = 16 * unit
        let divider: CGFloat = subtitle.isEmpty ? 0 : 2 * gap + 2 * unit
        let w = ceil(box + gap + tw + divider + sw + 8 * unit)
        let h = ceil(40 * unit)
        guard let ctx = makeContext(CGSize(width: w, height: h)) else { return nil }
        let mid = h / 2
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(2.5 * unit)
        ctx.stroke(CGRect(x: 2 * unit, y: mid - box / 2 + 1, width: box - 4 * unit, height: box - 4 * unit))
        ctx.setFillColor(accent.cgColor)
        ctx.fill(CGRect(x: box / 2 - 5 * unit, y: mid - 5 * unit, width: 10 * unit, height: 10 * unit))
        draw(tLine, at: CGPoint(x: box + gap, y: mid), in: ctx)
        if !subtitle.isEmpty {
            let dx = box + gap + tw + gap
            ctx.setFillColor(textColor.withAlpha(0.3).cgColor)
            ctx.fill(CGRect(x: dx, y: mid - 11 * unit, width: 1.5 * unit, height: 22 * unit))
            draw(sLine, at: CGPoint(x: dx + gap, y: mid), in: ctx)
        }
        return ctx.makeImage()
    }

    func lowerThird(name: String, title: String, accent: RGBA, unit: CGFloat) -> CGImage? {
        let nameFont = font(size: 36 * unit, weight: .bold)
        let titleFont = font(size: 22 * unit, weight: .medium)
        let nLine = line(name, font: nameFont, color: RGBA(r: 0.1, g: 0.09, b: 0.16).cgColor)
        let tLine = line(title, font: titleFont, color: RGBA(r: 0.36, g: 0.33, b: 0.46).cgColor)
        let pad = 26 * unit
        let bar = 7 * unit
        let w = ceil(bar + pad + max(lineWidth(nLine), lineWidth(tLine)) + pad * 1.4)
        let h = ceil(112 * unit)
        let shadowPad = 18 * unit
        guard let ctx = makeContext(CGSize(width: w + shadowPad * 2, height: h + shadowPad * 2)) else { return nil }
        let card = CGRect(x: shadowPad, y: shadowPad, width: w, height: h)
        let path = CGPath(roundedRect: card, cornerWidth: 16 * unit, cornerHeight: 16 * unit, transform: nil)
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -6 * unit), blur: 18 * unit, color: RGBA(r: 0, g: 0, b: 0, a: 0.28).cgColor)
        ctx.addPath(path)
        ctx.setFillColor(RGBA(r: 1, g: 1, b: 1, a: 0.96).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path)
        ctx.clip()
        ctx.setFillColor(accent.cgColor)
        ctx.fill(CGRect(x: card.minX, y: card.minY, width: bar, height: h))
        ctx.restoreGState()
        draw(nLine, at: CGPoint(x: card.minX + bar + pad, y: card.minY + h * 0.64), in: ctx)
        draw(tLine, at: CGPoint(x: card.minX + bar + pad, y: card.minY + h * 0.29), in: ctx)
        return ctx.makeImage()
    }

    // MARK: Text primitives

    func font(size: CGFloat, weight: NSFont.Weight) -> CTFont {
        NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }

    func line(_ s: String, font: CTFont, color: RGBA, kern: CGFloat = 0) -> CTLine {
        line(s, font: font, color: color.cgColor, kern: kern)
    }

    func line(_ s: String, font: CTFont, color: CGColor, kern: CGFloat = 0) -> CTLine {
        let attrs: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
            NSAttributedString.Key(kCTKernAttributeName as String): kern,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
    }

    func lineWidth(_ l: CTLine) -> CGFloat {
        CGFloat(CTLineGetTypographicBounds(l, nil, nil, nil))
    }

    /// Draws a line vertically centered on `at.y` (CG bottom-left coordinates).
    func draw(_ l: CTLine, at p: CGPoint, in ctx: CGContext) {
        var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
        _ = CTLineGetTypographicBounds(l, &ascent, &descent, &leading)
        ctx.textPosition = CGPoint(x: p.x, y: p.y - (ascent - descent) / 2)
        CTLineDraw(l, ctx)
    }

    func drawText(_ s: String, size: CGFloat, weight: NSFont.Weight, color: RGBA, center: CGPoint, in ctx: CGContext) {
        let l = line(s, font: font(size: size, weight: weight), color: color)
        let w = lineWidth(l)
        draw(l, at: CGPoint(x: center.x - w / 2, y: center.y), in: ctx)
    }
}
