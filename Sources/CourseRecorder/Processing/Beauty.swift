import Foundation
import CoreImage

/// Skin-selective retouching with Core Image: smoothing, whitening, rosy tint and clarity.
/// A 3D lookup table recognises skin tones (YCbCr skin model), so clothes and background keep their colors.
final class BeautyFilter {
    private let dimension = 32
    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private lazy var skinCube: Data = makeCube { r, g, b in
        let w = Self.skinWeight(r, g, b)
        return (w, w, w)
    }
    private var colorCube: Data?
    private var colorKey: (Float, Float) = (-1, -1)

    func apply(_ img: CIImage, _ s: BeautySettings, unit: CGFloat) -> CIImage {
        guard s.enabled else { return img }
        let extent = img.extent
        var out = img
        let skin = img.applyingFilter("CIColorCubeWithColorSpace", parameters: [
            "inputCubeDimension": dimension,
            "inputCubeData": skinCube,
            "inputColorSpace": srgb,
        ]).cropped(to: extent)

        if s.smooth > 0.01 {
            out = smoothSkin(out, skin: skin, amount: CGFloat(s.smooth), unit: unit)
        }
        if s.whiten > 0.01 || s.rosy > 0.01 {
            out = out.applyingFilter("CIColorCubeWithColorSpace", parameters: [
                "inputCubeDimension": dimension,
                "inputCubeData": toneCube(whiten: Float(s.whiten), rosy: Float(s.rosy)),
                "inputColorSpace": srgb,
            ])
        }
        if s.clarity > 0.01 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [
                "inputSharpness": 0.5 * s.clarity,
                "inputRadius": 1.6 * unit,
            ])
        }
        return out.cropped(to: extent)
    }

    /// Blurs skin with a normalized convolution (only skin pixels contribute), so eyes, brows and lips
    /// never smear dark halos into the surrounding skin.
    private func smoothSkin(_ img: CIImage, skin: CIImage, amount: CGFloat, unit: CGFloat) -> CIImage {
        let extent = img.extent
        // The blur runs at half resolution (the result is smooth anyway), which roughly halves the GPU cost.
        let k: CGFloat = 0.5
        let down = CGAffineTransform(scaleX: k, y: k)
        let smallImg = img.transformed(by: down)
        let smallSkin = skin.transformed(by: down)
        let smallExtent = smallImg.extent
        let sigma = Double((2.5 + 6.5 * amount) * unit * k)
        let weighted = smallImg.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: smallSkin])
        let num = weighted.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: smallExtent)
        let den = smallSkin.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: smallExtent)
        // CIDivideBlendMode returns background / input.
        let blurredSkin = den.applyingFilter("CIDivideBlendMode", parameters: [kCIInputBackgroundImageKey: num])
            .applyingFilter("CIColorClamp")
            .clampedToExtent()
            .transformed(by: CGAffineTransform(scaleX: 1 / k, y: 1 / k))
            .cropped(to: extent)
        let strength = 0.25 + 0.65 * amount
        let mask = skin.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: strength, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: strength, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: strength, w: 0),
        ])
        return blurredSkin.applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: img,
            kCIInputMaskImageKey: mask,
        ]).cropped(to: extent)
    }

    private func toneCube(whiten: Float, rosy: Float) -> Data {
        if colorKey == (whiten, rosy), let c = colorCube { return c }
        let k = 1 + 0.9 * whiten
        let cube = makeCube { r, g, b in
            let w = Self.skinWeight(r, g, b)
            guard w > 0.001 else { return (r, g, b) }
            var R = 1 - pow(1 - r, k), G = 1 - pow(1 - g, k), B = 1 - pow(1 - b, k)
            let L = 0.299 * R + 0.587 * G + 0.114 * B
            let desat = 0.16 * whiten
            R += (L - R) * desat
            G += (L - G) * desat
            B += (L - B) * desat + 0.012 * whiten
            R += 0.045 * rosy
            G -= 0.012 * rosy
            B += 0.01 * rosy
            func mix(_ a: Float, _ b: Float) -> Float { a + (min(1, max(0, b)) - a) * w }
            return (mix(r, R), mix(g, G), mix(b, B))
        }
        colorCube = cube
        colorKey = (whiten, rosy)
        return cube
    }

    private func makeCube(_ f: (Float, Float, Float) -> (Float, Float, Float)) -> Data {
        let n = dimension
        var data = [Float](repeating: 0, count: n * n * n * 4)
        var i = 0
        let d = Float(n - 1)
        for bi in 0..<n {
            for gi in 0..<n {
                for ri in 0..<n {
                    let c = f(Float(ri) / d, Float(gi) / d, Float(bi) / d)
                    data[i] = c.0
                    data[i + 1] = c.1
                    data[i + 2] = c.2
                    data[i + 3] = 1
                    i += 4
                }
            }
        }
        return data.withUnsafeBufferPointer { Data(buffer: $0) }
    }

    /// Soft skin likelihood from an elliptical YCbCr skin region (works across skin tones).
    static func skinWeight(_ r: Float, _ g: Float, _ b: Float) -> Float {
        let y = 0.299 * r + 0.587 * g + 0.114 * b
        let cb = 0.5 - 0.168736 * r - 0.331264 * g + 0.5 * b
        let cr = 0.5 + 0.5 * r - 0.418688 * g - 0.081312 * b
        let dcb = (cb - 0.405) / 0.11
        let dcr = (cr - 0.6) / 0.08
        let d = (dcb * dcb + dcr * dcr).squareRoot()
        var w = smoothstep(1.35, 0.7, d)
        w *= smoothstep(0.1, 0.22, y)
        w *= smoothstep(0.0, 0.05, r - b)
        return w
    }

    private static func smoothstep(_ e0: Float, _ e1: Float, _ x: Float) -> Float {
        let t = min(1, max(0, (x - e0) / (e1 - e0)))
        return t * t * (3 - 2 * t)
    }
}
