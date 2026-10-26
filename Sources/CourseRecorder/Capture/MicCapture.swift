import Foundation
import AVFoundation

/// Captures the microphone as 48 kHz mono float samples with host-clock timestamps.
final class MicCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "mic.session")
    private let audioQueue = DispatchQueue(label: "mic.samples", qos: .userInteractive)
    private let output = AVCaptureAudioDataOutput()
    private var currentInput: AVCaptureDeviceInput?
    private var scratch: [Float] = []
    private var interleaved: [Float] = []
    private var resampled: [Float] = []
    private var resamplePos: Double = 0
    private var lastInput: Float = 0
    private var reader = AudioSampleReader()
    private var readFailures = 0
    private var loggedFormat = false
    private var currentID = ""

    /// (samples, frameCount, presentation time in host-clock seconds)
    var onSamples: ((UnsafePointer<Float>, Int, Double) -> Void)?
    var onStatus: ((String?, String) -> Void)?   // (error, device name)
    private(set) var isRunning = false

    override init() {
        super.init()
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: audioQueue)
    }

    static func availableDevices() -> [DeviceInfo] {
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        var seen = Set<String>()
        return found.compactMap { d in
            guard !seen.contains(d.uniqueID) else { return nil }
            seen.insert(d.uniqueID)
            return DeviceInfo(id: d.uniqueID, name: d.localizedName)
        }
    }

    func start(deviceID: String) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if deviceID == self.currentID && self.session.isRunning { return }
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                self.configure(deviceID)
            case .notDetermined:
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    self.sessionQueue.async {
                        if ok { self.configure(deviceID) } else { self.report("未获得麦克风权限", "") }
                    }
                }
            default:
                self.report("未获得麦克风权限，请在系统设置 → 隐私与安全性 → 麦克风中允许", "")
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.currentID = ""
            if self.session.isRunning { self.session.stopRunning() }
            self.isRunning = false
        }
    }

    private func configure(_ deviceID: String) {
        let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
        guard let device = devices.first(where: { $0.uniqueID == deviceID }) ?? AVCaptureDevice.default(for: .audio) else {
            isRunning = false
            report("没有找到麦克风", "")
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
            isRunning = false
            report("无法打开麦克风：\(error.localizedDescription)", device.localizedName)
            return
        }
        if !session.outputs.contains(output), session.canAddOutput(output) {
            session.addOutput(output)
        }
        session.commitConfiguration()
        if !session.isRunning { session.startRunning() }
        currentID = deviceID
        isRunning = true
        report(nil, device.localizedName)
    }

    private func report(_ error: String?, _ name: String) {
        let cb = onStatus
        DispatchQueue.main.async { cb?(error, name) }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        guard let r = reader.read(sampleBuffer, into: &interleaved) else {
            readFailures += 1
            if readFailures == 1 || readFailures % 500 == 0 {
                NSLog("[Mic] cannot read samples (%d times): %@", readFailures, reader.lastError ?? "unknown")
            }
            return
        }
        if !loggedFormat {
            loggedFormat = true
            NSLog("[Mic] receiving %d frames/buffer, %d ch, %.0f Hz", r.frames, r.channels, r.sampleRate)
        }
        if scratch.count < r.frames { scratch = [Float](repeating: 0, count: r.frames) }
        let inv = 1 / Float(r.channels)
        for i in 0..<r.frames {
            var s: Float = 0
            for c in 0..<r.channels { s += interleaved[i * r.channels + c] }
            scratch[i] = s * inv
        }
        if abs(r.sampleRate - 48000) < 1 || r.sampleRate <= 0 {
            scratch.withUnsafeBufferPointer { onSamples?($0.baseAddress!, r.frames, pts) }
            return
        }
        // Some devices (e.g. Bluetooth headsets) ignore the requested rate: resample linearly to 48 kHz.
        let step = r.sampleRate / 48000
        let maxOut = Int(Double(r.frames) / step) + 4
        if resampled.count < maxOut { resampled = [Float](repeating: 0, count: maxOut) }
        var n = 0
        var pos = resamplePos
        while pos < Double(r.frames - 1) && n < maxOut {
            let i = Int(pos.rounded(.down))
            let frac = Float(pos - Double(i))
            let a = i < 0 ? lastInput : scratch[i]
            let b = scratch[i + 1]
            resampled[n] = a + (b - a) * frac
            n += 1
            pos += step
        }
        resamplePos = pos - Double(r.frames)
        lastInput = scratch[r.frames - 1]
        resampled.withUnsafeBufferPointer { onSamples?($0.baseAddress!, n, pts) }
    }
}
