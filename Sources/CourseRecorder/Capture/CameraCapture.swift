import Foundation
import AVFoundation
import QuartzCore

struct DeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
}

struct CameraStatus: Equatable {
    var running = false
    var deviceName = ""
    var format = ""
    var error: String?
}

final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    private let videoQueue = DispatchQueue(label: "camera.frames", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private let processor: CameraProcessor
    private let store: FrameStore
    private var counter = FPSCounter()
    private let statsLock = NSLock()
    private var currentKey = ""
    private var requestID = UUID()

    var onStatus: ((CameraStatus) -> Void)?
    /// Every processed frame, on the capture queue (used to record the narration).
    var onFrame: ((CameraFrame) -> Void)?

    init(processor: CameraProcessor, store: FrameStore) {
        self.processor = processor
        self.store = store
        super.init()
        output.alwaysDiscardsLateVideoFrames = true
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.setSampleBufferDelegate(self, queue: videoQueue)
    }

    static func availableDevices() -> [DeviceInfo] {
        let types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external, .continuityCamera]
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
        return found.map { DeviceInfo(id: $0.uniqueID, name: $0.localizedName) }
    }

    var measuredFPS: Double {
        statsLock.lock()
        defer { statsLock.unlock() }
        return counter.fps
    }

    func start(deviceID: String, preferredFPS: Int, targetHeight: Int) {
        let key = "\(deviceID)|\(preferredFPS)|\(targetHeight)"
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if key == self.currentKey && self.session.isRunning { return }
            let request = UUID()
            self.requestID = request
            self.currentKey = key
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .authorized:
                self.configure(deviceID: deviceID, preferredFPS: preferredFPS, targetHeight: targetHeight)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .video) { granted in
                    self.sessionQueue.async {
                        guard self.requestID == request else { return }
                        if granted {
                            self.configure(deviceID: deviceID, preferredFPS: preferredFPS, targetHeight: targetHeight)
                        } else {
                            self.report(CameraStatus(error: "未获得摄像头权限"))
                        }
                    }
                }
            default:
                self.report(CameraStatus(error: "未获得摄像头权限，请在系统设置 → 隐私与安全性 → 摄像头中允许"))
            }
        }
    }

    func stop(completion: (() -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.requestID = UUID()
            self.currentKey = ""
            if self.session.isRunning { self.session.stopRunning() }
            // Drain in-flight processing before a queued restart can publish its first fresh frame.
            self.videoQueue.sync { self.store.setCamera(nil) }
            self.report(CameraStatus())
            DispatchQueue.main.async { completion?() }
        }
    }

    private func configure(deviceID: String, preferredFPS: Int, targetHeight: Int) {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == deviceID })
                ?? AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video) ?? devices.first else {
            report(CameraStatus(error: "没有找到摄像头"))
            return
        }
        session.beginConfiguration()
        if let old = currentInput {
            session.removeInput(old)
            currentInput = nil
        }
        do {
            let input = try AVCaptureDeviceInput(device: device)
            if session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
            }
        } catch {
            session.commitConfiguration()
            report(CameraStatus(error: "无法打开摄像头：\(error.localizedDescription)"))
            return
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        var formatText = ""
        if let (format, fps) = Self.bestFormat(device, targetHeight: targetHeight, preferredFPS: preferredFPS) {
            do {
                try device.lockForConfiguration()
                device.activeFormat = format
                let duration = CMTime(value: 1000, timescale: CMTimeScale(fps * 1000))
                if let range = format.videoSupportedFrameRateRanges.first(where: { $0.minFrameRate <= fps + 0.01 && fps <= $0.maxFrameRate + 0.01 }) {
                    let d = fps >= range.maxFrameRate - 0.01 ? range.minFrameDuration : duration
                    device.activeVideoMinFrameDuration = d
                    device.activeVideoMaxFrameDuration = d
                }
                device.unlockForConfiguration()
            } catch {
                NSLog("[Camera] lockForConfiguration failed: \(error)")
            }
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
            formatText = "\(dims.width)×\(dims.height) · \(Int(fps.rounded()))fps"
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        report(CameraStatus(running: true, deviceName: device.localizedName, format: formatText, error: nil))
    }

    /// Picks a format that reaches the target height (or the best available), then the highest frame rate.
    static func bestFormat(_ device: AVCaptureDevice, targetHeight: Int, preferredFPS: Int) -> (AVCaptureDevice.Format, Double)? {
        let formats = device.formats.filter { CMFormatDescriptionGetMediaType($0.formatDescription) == kCMMediaType_Video }
        guard !formats.isEmpty else { return nil }
        func height(_ f: AVCaptureDevice.Format) -> Int { Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).height) }
        func width(_ f: AVCaptureDevice.Format) -> Int { Int(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width) }
        func maxRate(_ f: AVCaptureDevice.Format) -> Double { f.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0 }
        // Only consider 16:9 formats when the camera has any (square / portrait sensor modes distort the framing).
        func is169(_ f: AVCaptureDevice.Format) -> Bool {
            abs(Double(width(f)) / Double(max(1, height(f))) - 16.0 / 9.0) < 0.05
        }
        let wide = formats.filter(is169)
        let pool = wide.isEmpty ? formats : wide
        let maxH = pool.map(height).max() ?? 0
        let need = min(targetHeight, maxH)
        let candidates = pool.filter { height($0) >= need }
        let pref = Double(preferredFPS)
        let best = candidates.max { a, b in
            let ra = min(maxRate(a), pref), rb = min(maxRate(b), pref)
            if abs(ra - rb) > 0.5 { return ra < rb }
            if height(a) != height(b) { return height(a) > height(b) }
            let a169 = abs(Double(width(a)) / Double(max(1, height(a))) - 16.0 / 9.0) < 0.02
            let b169 = abs(Double(width(b)) / Double(max(1, height(b))) - 16.0 / 9.0) < 0.02
            if a169 != b169 { return !a169 }
            return false
        }
        guard let f = best else { return nil }
        return (f, min(maxRate(f), pref))
    }

    private func report(_ s: CameraStatus) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(s) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let now = CACurrentMediaTime()
        // The capture clock is the host clock; fall back to arrival time if it ever is not.
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let captured = pts.isFinite && abs(now - pts) < 1 ? pts : now
        if let frame = processor.process(pb, hostTime: captured) {
            store.setCamera(frame)
            onFrame?(frame)
        }
        statsLock.lock()
        counter.tick(now)
        statsLock.unlock()
    }
}
