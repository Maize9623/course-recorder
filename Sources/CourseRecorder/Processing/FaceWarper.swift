import Foundation
import Metal
import CoreVideo
import Vision

/// Face slimming and eye enlargement as a per-pixel GPU warp driven by Vision face landmarks.
final class FaceWarper {
    struct Params {
        /// Forward displacements: content around `point` moves by `vector` (pixels, top-left origin).
        var pushes: [(point: CGPoint, vector: CGVector)] = []
        var pushRadius: CGFloat = 1
        /// Magnification around each eye: center, radius, strength (0...0.4).
        var eyes: [(center: CGPoint, radius: CGFloat, strength: CGFloat)] = []

        var isIdentity: Bool { pushes.isEmpty && eyes.isEmpty }
    }

    static let maxPushes = 12

    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var cache: CVMetalTextureCache?

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;
    struct VOut { float4 position [[position]]; float2 uv; };
    vertex VOut warp_vertex(uint vid [[vertex_id]]) {
        float2 pos[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
        float2 uv[3] = { float2(0, 1), float2(2, 1), float2(0, -1) };
        VOut o;
        o.position = float4(pos[vid], 0, 1);
        o.uv = uv[vid];
        return o;
    }
    fragment float4 warp_fragment(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], constant float4* u [[buffer(0)]]) {
        float2 size = u[0].xy;
        float radius = u[0].z;
        int pushCount = int(u[0].w);
        int eyeCount = int(u[1].x);
        float2 p = in.uv * size;
        float2 src = p;
        for (int i = 0; i < pushCount; i++) {
            float4 pv = u[2 + i];
            float d = length(p - pv.xy) / radius;
            if (d < 1.0) {
                float f = 1.0 - d * d;
                src -= pv.zw * (f * f);
            }
        }
        for (int i = 0; i < eyeCount; i++) {
            float4 e = u[14 + i];
            float2 dv = src - e.xy;
            float d = length(dv) / e.z;
            if (d < 1.0) {
                float f = 1.0 - d * d;
                src = e.xy + dv * (1.0 - e.w * f);
            }
        }
        constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
        return tex.sample(s, src / size);
    }
    """

    init?(device: MTLDevice) {
        guard let q = device.makeCommandQueue(),
              let lib = try? device.makeLibrary(source: Self.source, options: nil),
              let vf = lib.makeFunction(name: "warp_vertex"),
              let ff = lib.makeFunction(name: "warp_fragment") else { return nil }
        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction = vf
        desc.fragmentFunction = ff
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let p = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
        queue = q
        pipeline = p
        CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
    }

    /// Renders `src` warped into `dst` (both BGRA, same size). Returns false if nothing was rendered.
    func warp(_ src: CVPixelBuffer, into dst: CVPixelBuffer, params: Params) -> Bool {
        guard let cache, let inTex = texture(src, cache), let outTex = texture(dst, cache),
              let input = CVMetalTextureGetTexture(inTex), let output = CVMetalTextureGetTexture(outTex) else { return false }
        var u = [SIMD4<Float>](repeating: .zero, count: 16)
        let pushes = params.pushes.prefix(Self.maxPushes)
        u[0] = SIMD4(Float(input.width), Float(input.height), Float(max(1, params.pushRadius)), Float(pushes.count))
        u[1] = SIMD4(Float(min(2, params.eyes.count)), 0, 0, 0)
        for (i, p) in pushes.enumerated() {
            u[2 + i] = SIMD4(Float(p.point.x), Float(p.point.y), Float(p.vector.dx), Float(p.vector.dy))
        }
        for (i, e) in params.eyes.prefix(2).enumerated() {
            u[14 + i] = SIMD4(Float(e.center.x), Float(e.center.y), Float(max(1, e.radius)), Float(e.strength))
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store
        guard let cb = queue.makeCommandBuffer(), let enc = cb.makeRenderCommandEncoder(descriptor: pass) else { return false }
        enc.setRenderPipelineState(pipeline)
        enc.setFragmentTexture(input, index: 0)
        u.withUnsafeBytes { enc.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        _ = (inTex, outTex)
        return cb.status == .completed
    }

    private func texture(_ pb: CVPixelBuffer, _ cache: CVMetalTextureCache) -> CVMetalTexture? {
        var t: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, .bgra8Unorm,
                                                  CVPixelBufferGetWidth(pb), CVPixelBufferGetHeight(pb), 0, &t)
        return t
    }

    // MARK: - Landmarks → warp parameters

    /// Face shape from Vision landmarks, in pixel coordinates with a top-left origin.
    struct FaceShape {
        var contour: [CGPoint]
        var leftEye: [CGPoint]
        var rightEye: [CGPoint]
        var center: CGPoint
        var width: CGFloat

        init?(_ obs: VNFaceObservation, imageSize: CGSize) {
            guard let lm = obs.landmarks, let c = lm.faceContour?.pointsInImage(imageSize: imageSize), c.count >= 7 else { return nil }
            func flip(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: imageSize.height - p.y) }
            contour = c.map(flip)
            leftEye = lm.leftEye?.pointsInImage(imageSize: imageSize).map(flip) ?? []
            rightEye = lm.rightEye?.pointsInImage(imageSize: imageSize).map(flip) ?? []
            let nose = lm.nose?.pointsInImage(imageSize: imageSize).map(flip) ?? []
            if nose.isEmpty {
                let bb = obs.boundingBox
                center = flip(CGPoint(x: bb.midX * imageSize.width, y: bb.midY * imageSize.height))
            } else {
                center = CGPoint(x: nose.map(\.x).reduce(0, +) / CGFloat(nose.count), y: nose.map(\.y).reduce(0, +) / CGFloat(nose.count))
            }
            width = hypot(contour.last!.x - contour.first!.x, contour.last!.y - contour.first!.y)
            guard width > 8 else { return nil }
        }

        /// Exponential smoothing against the previous shape to remove landmark jitter.
        func blended(with old: FaceShape?, keep: CGFloat) -> FaceShape {
            guard let old, old.contour.count == contour.count, old.leftEye.count == leftEye.count,
                  old.rightEye.count == rightEye.count, hypot(old.center.x - center.x, old.center.y - center.y) < width * 0.25 else { return self }
            func mix(_ a: CGPoint, _ b: CGPoint) -> CGPoint { CGPoint(x: b.x + (a.x - b.x) * keep, y: b.y + (a.y - b.y) * keep) }
            var s = self
            s.contour = zip(old.contour, contour).map(mix)
            s.leftEye = zip(old.leftEye, leftEye).map(mix)
            s.rightEye = zip(old.rightEye, rightEye).map(mix)
            s.center = mix(old.center, center)
            s.width = old.width + (width - old.width) * (1 - keep)
            return s
        }

        func params(slim: CGFloat, eyes: CGFloat) -> Params {
            var p = Params()
            let n = contour.count
            let chin = n / 2
            if slim > 0.01 {
                // Jaw and cheek points on both sides (skip the points near the ears and the chin tip).
                var indices = Array(1..<chin) + Array((chin + 1)..<(n - 1))
                if indices.count > FaceWarper.maxPushes {
                    let step = Double(indices.count) / Double(FaceWarper.maxPushes)
                    indices = (0..<FaceWarper.maxPushes).map { indices[Int(Double($0) * step)] }
                }
                let perPoint = slim * width * 0.022
                for i in indices {
                    let c = contour[i]
                    let side: CGFloat = c.x < center.x ? 1 : -1
                    // Stronger along the lower cheeks and jaw, softer near the ears.
                    let t = CGFloat(i < chin ? i : n - 1 - i) / CGFloat(chin)
                    let w = 0.35 + 0.65 * sin(.pi * min(1, t * 1.1))
                    p.pushes.append((c, CGVector(dx: side * perPoint * w, dy: -perPoint * 0.15 * w)))
                }
                p.pushRadius = width * 0.2
            }
            if eyes > 0.01 {
                for eye in [leftEye, rightEye] where eye.count >= 4 {
                    let xs = eye.map(\.x), ys = eye.map(\.y)
                    let center = CGPoint(x: xs.reduce(0, +) / CGFloat(xs.count), y: ys.reduce(0, +) / CGFloat(ys.count))
                    let eyeWidth = (xs.max()! - xs.min()!)
                    p.eyes.append((center, eyeWidth * 1.15, eyes * 0.22))
                }
            }
            return p
        }
    }
}
