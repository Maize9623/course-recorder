import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// `CourseRecorder --make-icon out.png` renders the 1024 px app icon (used by the build script).
enum IconMaker {
    static func run(_ args: [String]) -> Int32 {
        let path = args.first ?? "AppIcon.png"
        let size = 1024
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 1 }
        let body = CGRect(x: 100, y: 100, width: 824, height: 824)
        let bodyPath = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -14), blur: 30, color: CGColor(gray: 0, alpha: 0.35))
        c.addPath(bodyPath)
        c.setFillColor(CGColor(srgbRed: 0.4, green: 0.2, blue: 0.8, alpha: 1))
        c.fillPath()
        c.restoreGState()

        c.saveGState()
        c.addPath(bodyPath)
        c.clip()
        let colors = [CGColor(srgbRed: 0.42, green: 0.22, blue: 0.93, alpha: 1),
                      CGColor(srgbRed: 0.93, green: 0.33, blue: 0.68, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: [0, 1]) {
            c.drawLinearGradient(g, start: CGPoint(x: 100, y: 924), end: CGPoint(x: 924, y: 100), options: [])
        }
        let gloss = [CGColor(gray: 1, alpha: 0.22), CGColor(gray: 1, alpha: 0)] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: gloss, locations: [0, 1]) {
            c.drawRadialGradient(g, startCenter: CGPoint(x: 330, y: 860), startRadius: 0, endCenter: CGPoint(x: 330, y: 860), endRadius: 520, options: [])
        }
        c.restoreGState()

        // Screen
        let screen = CGRect(x: 232, y: 352, width: 580, height: 390)
        c.saveGState()
        c.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: CGColor(gray: 0, alpha: 0.25))
        c.addPath(CGPath(roundedRect: screen, cornerWidth: 44, cornerHeight: 44, transform: nil))
        c.setFillColor(CGColor(gray: 1, alpha: 0.96))
        c.fillPath()
        c.restoreGState()
        c.setFillColor(CGColor(srgbRed: 0.86, green: 0.83, blue: 0.97, alpha: 1))
        c.addPath(CGPath(roundedRect: CGRect(x: 262, y: 382, width: 120, height: 330), cornerWidth: 22, cornerHeight: 22, transform: nil))
        c.fillPath()
        c.setFillColor(CGColor(srgbRed: 0.8, green: 0.78, blue: 0.88, alpha: 1))
        for (i, w) in [300.0, 250, 330, 210].enumerated() {
            c.addPath(CGPath(roundedRect: CGRect(x: 412, y: 664 - Double(i) * 56, width: w, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
            c.fillPath()
        }

        // Presenter bubble
        let center = CGPoint(x: 330, y: 350)
        let r: CGFloat = 132
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fillEllipse(in: CGRect(x: center.x - r - 16, y: center.y - r - 16, width: (r + 16) * 2, height: (r + 16) * 2))
        c.saveGState()
        c.addEllipse(in: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2))
        c.clip()
        let bubble = [CGColor(srgbRed: 0.24, green: 0.12, blue: 0.48, alpha: 1), CGColor(srgbRed: 0.45, green: 0.22, blue: 0.7, alpha: 1)] as CFArray
        if let g = CGGradient(colorsSpace: cs, colors: bubble, locations: [0, 1]) {
            c.drawLinearGradient(g, start: CGPoint(x: center.x, y: center.y + r), end: CGPoint(x: center.x, y: center.y - r), options: [])
        }
        c.setFillColor(CGColor(srgbRed: 0.98, green: 0.88, blue: 0.82, alpha: 1))
        c.fillEllipse(in: CGRect(x: center.x - 44, y: center.y + 4, width: 88, height: 96))
        c.setFillColor(CGColor(srgbRed: 0.97, green: 0.93, blue: 0.85, alpha: 1))
        c.fillEllipse(in: CGRect(x: center.x - 100, y: center.y - 170, width: 200, height: 190))
        c.restoreGState()

        // Record dot
        let dot = CGPoint(x: 772, y: 752)
        c.setFillColor(CGColor(gray: 1, alpha: 1))
        c.fillEllipse(in: CGRect(x: dot.x - 58, y: dot.y - 58, width: 116, height: 116))
        c.setFillColor(CGColor(srgbRed: 1, green: 0.23, blue: 0.19, alpha: 1))
        c.fillEllipse(in: CGRect(x: dot.x - 44, y: dot.y - 44, width: 88, height: 88))

        guard let img = c.makeImage(),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil) else { return 1 }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest) ? 0 : 1
    }
}
