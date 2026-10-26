import Foundation
import AVFoundation
import CoreImage
import Vision

/// A processed camera frame, ready for the compositor.
final class CameraFrame {
    /// Opaque frame: background applied, color adjusted and mirrored.
    let processed: CVPixelBuffer
    /// Person only on transparency (premultiplied), produced when a cutout layout is enabled.
    let cutout: CVPixelBuffer?
    let size: CGSize
    /// Smoothed-free face center in normalized output coordinates (top-left origin), if detected.
    let face: CGPoint?
    /// Host-clock time when the sensor captured this frame.
    let captureTime: CFTimeInterval

    init(processed: CVPixelBuffer, cutout: CVPixelBuffer?, size: CGSize, face: CGPoint?, captureTime: CFTimeInterval) {
        self.processed = processed
        self.cutout = cutout
        self.size = size
        self.face = face
        self.captureTime = captureTime
    }
}

struct CameraProcessingConfig: Equatable {
    var background = BackgroundSettings()
    var camera = CameraSettings()
    var beauty = BeautySettings()
    var needCutout = false
    /// The input already went through this pipeline (a recorded narration): only face tracking and, when a
    /// cutout is needed, the matte are computed; background, beauty, colour and mirroring are not applied again.
    var preprocessed = false
}

final class CameraProcessor {
    private let context: CIContext
    private let assets: AssetFactory
    private let lock = NSLock()
    private var config = CameraProcessingConfig()

    // Segmentation state, only touched on `segQueue` (except the lock-protected mask slot).
    private let segQueue = DispatchQueue(label: "camera.segmentation", qos: .userInteractive)
    private let sequence = VNSequenceRequestHandler()
    private var segRequest = VNGeneratePersonSegmentationRequest()
    private var segQuality: SegmentationQuality = .balanced
    private let maskLock = NSLock()
    private var latestMask: CVPixelBuffer?
    private var segInFlight = false

    private let faceRequest = VNDetectFaceRectanglesRequest()
    private var frameIndex = 0
    private var lastFace: CGPoint?
    private var faceMisses = 0
    private var lastHostTime: Double = 0
    private var frameInterval: Double = 1.0 / 30

    private var processedPool: CVPixelBufferPool?
    private var cutoutPool: CVPixelBufferPool?
    private var warpPool: CVPixelBufferPool?
    private var maskPool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero

    private let beautyFilter = BeautyFilter()
    private let warper: FaceWarper?
    // Face analysis state; requests run on `faceQueue`, results are shared under `faceLock`.
    private let faceQueue = DispatchQueue(label: "camera.face", qos: .userInitiated)
    private let faceLock = NSLock()
    private var faceInFlight = false
    private let landmarksRequest = VNDetectFaceLandmarksRequest()
    private var faceShape: FaceWarper.FaceShape?
    private var faceShapeMisses = 0
    private(set) var lastSegmentationMs: Double = 0
    /// Smoothed per-stage cost of `process`: face warp, waiting for the mask, final render (ms).
    private(set) var stageMs: (warp: Double, wait: Double, render: Double) = (0, 0, 0)

    private var backgroundKey = ""
    private var backgroundImage: CIImage?
    private var backgroundPending = ""
    private let backgroundQueue = DispatchQueue(label: "camera.background", qos: .utility)

    private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!
    private(set) var lastProcessingMs: Double = 0

    init(context: CIContext, assets: AssetFactory) {
        // A dedicated GPU queue: camera processing must not wait behind the 60 fps program renders.
        if let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() {
            self.context = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false, .name: "camera"])
        } else {
            self.context = context
        }
        self.assets = assets
        warper = MTLCreateSystemDefaultDevice().flatMap { FaceWarper(device: $0) }
        segRequest.qualityLevel = .balanced
        segRequest.outputPixelFormat = kCVPixelFormatType_OneComponent8
    }

    func update(_ c: CameraProcessingConfig) {
        lock.lock()
        config = c
        lock.unlock()
    }

    private func currentConfig() -> CameraProcessingConfig {
        lock.lock()
        defer { lock.unlock() }
        return config
    }

    // MARK: - Processing

    func process(_ rawBuffer: CVPixelBuffer, hostTime: CFTimeInterval) -> CameraFrame? {
        let t0 = CACurrentMediaTime()
        var cfg = currentConfig()
        if cfg.preprocessed {
            cfg.beauty.enabled = false
            cfg.beauty.slim = 0
            cfg.beauty.eyes = 0
            cfg.background.mode = .off
            cfg.camera.mirror = false
            cfg.camera.brightness = 0
            cfg.camera.contrast = 1
            cfg.camera.saturation = 1
            cfg.camera.warmth = 0
        }
        let w = CVPixelBufferGetWidth(rawBuffer), h = CVPixelBufferGetHeight(rawBuffer)
        let size = CGSize(width: w, height: h)
        let unit = CGFloat(h) / 1080
        ensurePools(size)

        // Face analysis runs on its own queue; the warp uses the latest finished landmarks (smoothed, so the
        // one-frame delay is invisible) and never blocks this thread.
        var pb = rawBuffer
        let useLandmarks = cfg.beauty.needsLandmarks
        let wantFaceRect = cfg.camera.faceTracking && !useLandmarks && frameIndex % 4 == 0
        if useLandmarks || wantFaceRect {
            faceLock.lock()
            let busy = faceInFlight
            if !busy { faceInFlight = true }
            faceLock.unlock()
            if !busy {
                let mirror = cfg.camera.mirror
                faceQueue.async { [weak self] in
                    guard let self else { return }
                    if useLandmarks {
                        self.detectLandmarks(rawBuffer, size: size, mirror: mirror)
                    } else {
                        let handler = VNImageRequestHandler(cvPixelBuffer: rawBuffer, orientation: .up, options: [:])
                        if (try? handler.perform([self.faceRequest])) != nil { self.updateFace(mirror: mirror) }
                    }
                    self.faceLock.lock()
                    self.faceInFlight = false
                    self.faceLock.unlock()
                }
            }
        }
        if useLandmarks {
            faceLock.lock()
            let shape = faceShape
            faceLock.unlock()
            if let shape, let warper, let out = makeBuffer(warpPool) {
                let params = shape.params(slim: CGFloat(cfg.beauty.slim), eyes: CGFloat(cfg.beauty.eyes))
                if !params.isIdentity && warper.warp(rawBuffer, into: out, params: params) { pb = out }
            }
        } else {
            faceLock.lock()
            faceShape = nil
            faceLock.unlock()
        }

        let tWarp = CACurrentMediaTime()
        frameIndex += 1
        if lastHostTime > 0 {
            let dt = hostTime - lastHostTime
            if dt > 0 && dt < 0.5 { frameInterval = frameInterval * 0.9 + dt * 0.1 }
        }
        lastHostTime = hostTime

        // Person segmentation runs on its own queue (Neural Engine) while this thread prepares the rest.
        let needMask = cfg.background.mode != .off || cfg.needCutout
        var pending: DispatchSemaphore?
        if needMask {
            maskLock.lock()
            let busy = segInFlight
            if !busy { segInFlight = true }
            maskLock.unlock()
            if !busy {
                let sem = DispatchSemaphore(value: 0)
                let quality = cfg.background.quality
                let buffer = pb
                segQueue.async { [weak self] in
                    self?.segment(buffer, quality: quality)
                    sem.signal()
                }
                pending = sem
            }
        } else {
            maskLock.lock()
            latestMask = nil
            maskLock.unlock()
        }

        if !cfg.camera.faceTracking {
            faceLock.lock()
            lastFace = nil
            faceLock.unlock()
        }

        // Wait for this frame's mask when segmentation keeps up (exact alignment); otherwise keep the frame rate
        // and use the latest finished mask.
        if let pending {
            // Bounded wait: when the GPU / Neural Engine is busy the previous mask is used instead of dropping frames.
            let budget = max(0.003, min(0.014, frameInterval * 0.6 - (CACurrentMediaTime() - t0)))
            _ = pending.wait(timeout: .now() + budget)
        }
        var mask: CVPixelBuffer? = nil
        if needMask {
            maskLock.lock()
            mask = latestMask
            maskLock.unlock()
        }
        let tWait = CACurrentMediaTime()

        let src = CIImage(cvPixelBuffer: pb)
        let extent = src.extent
        let adjusted = colorAdjusted(beautyFilter.apply(src, cfg.beauty, unit: unit), cfg.camera)
        // The matte is refined once at half resolution into a small buffer, then shared by every render below.
        var maskImage: CIImage? = nil
        if let mask, let mb = makeBuffer(maskPool) {
            let halfSize = CGSize(width: CVPixelBufferGetWidth(mb), height: CVPixelBufferGetHeight(mb))
            let refined = refinedMask(mask, guide: src, settings: cfg.background, unit: unit, size: halfSize)
            context.render(refined, to: mb, bounds: CGRect(origin: .zero, size: halfSize), colorSpace: nil)
            maskImage = CIImage(cvPixelBuffer: mb, options: [.colorSpace: NSNull()])
                .transformed(by: CGAffineTransform(scaleX: extent.width / halfSize.width, y: extent.height / halfSize.height))
                .cropped(to: extent)
        }

        var out: CIImage = adjusted
        if let m = maskImage {
            switch cfg.background.mode {
            case .off:
                break
            case .blur:
                let sigma = max(2, cfg.background.blurAmount) * Double(h) / 1080
                let bg = adjusted.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: extent)
                out = blend(adjusted, over: bg, mask: m)
            case .image:
                if let bg = background(for: cfg, size: size) {
                    out = blend(adjusted, over: bg, mask: m)
                } else {
                    let bg = adjusted.clampedToExtent().applyingGaussianBlur(sigma: 20).cropped(to: extent)
                    out = blend(adjusted, over: bg, mask: m)
                }
            case .color:
                let bg = CIImage(color: cfg.background.color.withAlpha(1).ciColor).cropped(to: extent)
                out = blend(adjusted, over: bg, mask: m)
            }
        }
        if cfg.camera.mirror { out = out.mirroredHorizontally() }

        guard let processed = makeBuffer(processedPool) else { return nil }
        context.render(out, to: processed, bounds: extent, colorSpace: srgb)
        let tRender = CACurrentMediaTime()
        stageMs = (stageMs.warp * 0.8 + (tWarp - t0) * 200,
                   stageMs.wait * 0.8 + (tWait - tWarp) * 200,
                   stageMs.render * 0.8 + (tRender - tWait) * 200)

        var cutout: CVPixelBuffer? = nil
        if cfg.needCutout, let m = maskImage, let buf = makeBuffer(cutoutPool) {
            var person = adjusted.masked(by: alphaMask(m))
            if cfg.camera.mirror { person = person.mirroredHorizontally() }
            context.render(person.composited(over: CIX.clear.cropped(to: extent)), to: buf, bounds: extent, colorSpace: srgb)
            cutout = buf
        }

        lastProcessingMs = (CACurrentMediaTime() - t0) * 1000
        faceLock.lock()
        let face = lastFace
        faceLock.unlock()
        return CameraFrame(processed: processed, cutout: cutout, size: size, face: face, captureTime: hostTime)
    }

    /// Runs on `segQueue` only.
    private func segment(_ pb: CVPixelBuffer, quality: SegmentationQuality) {
        if quality != segQuality {
            segQuality = quality
            let r = VNGeneratePersonSegmentationRequest()
            switch quality {
            case .fast: r.qualityLevel = .fast
            case .balanced: r.qualityLevel = .balanced
            case .accurate: r.qualityLevel = .accurate
            }
            r.outputPixelFormat = kCVPixelFormatType_OneComponent8
            segRequest = r
        }
        let segStart = CACurrentMediaTime()
        var result: CVPixelBuffer?
        do {
            try sequence.perform([segRequest], on: pb, orientation: .up)
            result = segRequest.results?.first?.pixelBuffer
        } catch {
            NSLog("[Camera] Vision error: \(error)")
        }
        lastSegmentationMs = lastSegmentationMs * 0.8 + (CACurrentMediaTime() - segStart) * 1000 * 0.2
        maskLock.lock()
        if let result { latestMask = result }
        segInFlight = false
        maskLock.unlock()
    }

    /// Runs on `faceQueue` only.
    private func detectLandmarks(_ pb: CVPixelBuffer, size: CGSize, mirror: Bool) {
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up, options: [:])
        do {
            try handler.perform([landmarksRequest])
        } catch {
            return
        }
        let faces = landmarksRequest.results ?? []
        let best = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        let shape = best.flatMap { FaceWarper.FaceShape($0, imageSize: size) }
        faceLock.lock()
        defer { faceLock.unlock() }
        guard let best, let shape else {
            faceShapeMisses += 1
            if faceShapeMisses > 20 { faceShape = nil }
            faceMisses += 1
            if faceMisses > 60 { lastFace = nil }
            return
        }
        faceShapeMisses = 0
        faceMisses = 0
        faceShape = shape.blended(with: faceShape, keep: 0.45)
        let bb = best.boundingBox
        var c = CGPoint(x: bb.midX, y: 1 - bb.midY)
        if mirror { c.x = 1 - c.x }
        lastFace = c
    }

    /// Runs on `faceQueue` only.
    private func updateFace(mirror: Bool) {
        let faces = faceRequest.results ?? []
        let best = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height })
        faceLock.lock()
        defer { faceLock.unlock() }
        guard let best else {
            faceMisses += 1
            if faceMisses > 30 { lastFace = nil }
            return
        }
        faceMisses = 0
        let bb = best.boundingBox
        var c = CGPoint(x: bb.midX, y: 1 - bb.midY)
        if mirror { c.x = 1 - c.x }
        lastFace = c
    }

    // MARK: - Helpers

    private func colorAdjusted(_ img: CIImage, _ c: CameraSettings) -> CIImage {
        var out = img
        if abs(c.brightness) > 0.001 || abs(c.contrast - 1) > 0.001 || abs(c.saturation - 1) > 0.001 {
            out = out.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: c.brightness,
                kCIInputContrastKey: c.contrast,
                kCIInputSaturationKey: c.saturation,
            ])
        }
        if abs(c.warmth) > 0.001 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 + CGFloat(c.warmth) * 2200, y: 0),
                "inputTargetNeutral": CIVector(x: 6500, y: 0),
            ])
        }
        return out.cropped(to: img.extent)
    }

    /// Vision's person mask → refined matte of `size` (half the camera resolution): hole filling, edge-aware
    /// upsampling, matte cleanup with the edge pulled inwards (removes the real background's halo), feathering.
    private func refinedMask(_ mask: CVPixelBuffer, guide: CIImage, settings b: BackgroundSettings, unit: CGFloat, size: CGSize) -> CIImage {
        let out = CGRect(origin: .zero, size: size)
        // Raw confidences: no color management, so 0.5 really means 50 %.
        var m = CIImage(cvPixelBuffer: mask, options: [.colorSpace: NSNull()])
        let maskExtent = m.extent
        let sx = size.width / maskExtent.width
        let sy = size.height / maskExtent.height
        let scale = size.height / max(1, guide.extent.height)

        if b.fillHoles {
            // Morphological closing at mask resolution fills gaps in dark clothes and between arm and body.
            let r = max(1, 7 * unit * scale / sx)
            m = m.clampedToExtent()
                .applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: r])
                .applyingFilter("CIMorphologyMinimum", parameters: [kCIInputRadiusKey: r])
                .cropped(to: maskExtent)
        }

        var up = m.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        if sx > 1.3 {
            // Upsample guided by the camera image so the edge follows the real outline of hair, arms and clothes.
            let smallGuide = guide.transformed(by: CGAffineTransform(scaleX: size.width / guide.extent.width,
                                                                     y: size.height / guide.extent.height))
            let guided = smallGuide.applyingFilter("CIEdgePreserveUpsampleFilter", parameters: [
                "inputSmallImage": m,
                "inputSpatialSigma": 2.0,
                "inputLumaSigma": 0.14,
            ])
            if !guided.extent.isInfinite && guided.extent.width >= size.width * 0.9 { up = guided }
        }
        up = up.clampedToExtent()

        // Contrast window: faint ghosts of the old background go to 0, semi-transparent clothes go to 1,
        // and moving the window's center up pulls the edge inwards.
        let clean = CGFloat(clamp(b.matteClean, 0, 1))
        let width = max(0.08, 1 - 0.8 * clean)
        let center = clamp(0.5 + 0.08 * CGFloat(b.edgeTighten), 0.25, 0.8)
        let k = 1 / width
        let bias = -(center - width / 2) * k
        up = up.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: k, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0),
            "inputBiasVector": CIVector(x: bias, y: bias, z: bias, w: 0),
        ]).applyingFilter("CIColorClamp")
        if b.edgeSmoothing > 0.2 {
            up = up.applyingGaussianBlur(sigma: b.edgeSmoothing * Double(unit * scale))
        }
        return up.cropped(to: out)
    }

    /// Mask (red channel) → white with alpha, for source-in compositing.
    private func alphaMask(_ m: CIImage) -> CIImage {
        m.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 1, y: 0, z: 0, w: 0),
            "inputBiasVector": CIVector(x: 1, y: 1, z: 1, w: 0),
        ])
    }

    private func blend(_ fg: CIImage, over bg: CIImage, mask: CIImage) -> CIImage {
        fg.applyingFilter("CIBlendWithRedMask", parameters: [
            kCIInputBackgroundImageKey: bg,
            kCIInputMaskImageKey: mask,
        ])
    }

    private func background(for cfg: CameraProcessingConfig, size: CGSize) -> CIImage? {
        let b = cfg.background
        let key = "\(b.preset)|\(b.customImagePath)|\(Int(size.width))x\(Int(size.height))|\(b.imageDefocus)"
        lock.lock()
        let readyKey = backgroundKey
        let readyImage = backgroundImage
        lock.unlock()
        if key == readyKey, let readyImage { return readyImage }
        if backgroundPending != key {
            backgroundPending = key
            let assets = self.assets
            backgroundQueue.async { [weak self] in
                var cg = assets.cameraBackground(id: b.preset, customPath: b.customImagePath, size: size)
                if let c = cg, b.imageDefocus > 0.1 {
                    let blurred = CIImage(cgImage: c).clampedToExtent().applyingGaussianBlur(sigma: b.imageDefocus * Double(size.height) / 1080)
                    cg = assets.bake(blurred, size: size) ?? c
                }
                guard let self else { return }
                let image = cg.map { CIImage(cgImage: $0) }
                self.lock.lock()
                self.backgroundImage = image
                self.backgroundKey = key
                self.lock.unlock()
            }
        }
        return readyImage
    }

    private func ensurePools(_ size: CGSize) {
        guard size != poolSize else { return }
        poolSize = size
        processedPool = Self.makePool(size)
        cutoutPool = Self.makePool(size)
        warpPool = Self.makePool(size)
        maskPool = Self.makePool(CGSize(width: (size.width / 2).rounded(), height: (size.height / 2).rounded()))
    }

    static func makePool(_ size: CGSize) -> CVPixelBufferPool? {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 3] as CFDictionary, attrs as CFDictionary, &pool)
        return pool
    }

    private func makeBuffer(_ pool: CVPixelBufferPool?) -> CVPixelBuffer? {
        guard let pool else { return nil }
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb)
        return pb
    }
}
