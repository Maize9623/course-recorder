import Foundation
import AVFoundation
import CoreMedia
import QuartzCore

struct MixerConfig: Equatable {
    var micGain: Float = 1
    var highPass = true
    var gate = true
    var gateThresholdDB: Double = -52
    var limiter = true
    var systemGain: Float = 0.5
    var bgmGain: Float = 0.1
    var ducking = true
    var duckGain: Float = 0.32
    var micMuted = false
    var avOffset: Double = 0
}

struct AudioLevels {
    var mic: Float = -120
    var output: Float = -120
    var ducking: Float = 1
}

/// Mixes microphone, BGM and system audio into 48 kHz stereo sample buffers for the recorder.
/// The microphone drives the clock; without a microphone a timer takes over.
final class AudioMixer {
    let bgm = BGMPlayer()
    let systemRing = StereoRing(capacityFrames: 48000)
    let monitor = AudioMonitor()

    private let lock = NSLock()
    private var cfg = MixerConfig()
    private var highPass = Biquad.highPass(frequency: 80)
    private var gate = NoiseGate()
    private var ducker = Ducker()
    private var limiter = Limiter()
    private var formatDescription: CMAudioFormatDescription?

    private var mic: [Float] = []
    private var duck: [Float] = []
    private var bgmL: [Float] = []
    private var bgmR: [Float] = []
    private var sys: [Float] = []
    private var mix: [Float] = []
    private var monitorBuf: [Float] = []

    private var micPeak: Float = 0
    private var outPeak: Float = 0
    private let levelLock = NSLock()

    private let clockQueue = DispatchQueue(label: "mixer.clock", qos: .userInteractive)
    private var clockTimer: DispatchSourceTimer?
    private var lastMicCallback: Double = 0

    var onMixed: ((CMSampleBuffer) -> Void)?
    /// Offline rendering feeds timeline times instead of host times; they must not be "corrected" to the clock.
    var trustsTimestamps = false

    init() {
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
                                               mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                               mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                               mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                       magicCookie: nil, extensions: nil, formatDescriptionOut: &formatDescription)
    }

    func update(_ c: MixerConfig) {
        lock.lock()
        cfg = c
        gate.thresholdDB = c.gateThresholdDB
        ducker.duckGain = c.duckGain
        lock.unlock()
    }

    func levels() -> AudioLevels {
        levelLock.lock()
        defer { levelLock.unlock() }
        let l = AudioLevels(mic: linearToDB(micPeak), output: linearToDB(outPeak), ducking: ducker.current)
        micPeak *= 0.5
        outPeak *= 0.5
        return l
    }

    // MARK: - System audio input

    /// Called only from the ScreenCaptureKit audio queue.
    func pushSystemAudio(_ sb: CMSampleBuffer) {
        guard let r = systemReader.read(sb, into: &systemSamples) else {
            systemFailures += 1
            if systemFailures == 1 || systemFailures % 500 == 0 {
                NSLog("[SystemAudio] cannot read samples (%d times): %@", systemFailures, systemReader.lastError ?? "unknown")
            }
            return
        }
        systemSamples.withUnsafeBufferPointer { p in
            let base = p.baseAddress!
            if r.channels == 2 {
                systemRing.writeInterleaved(base, frames: r.frames)
            } else if r.channels == 1 {
                systemRing.write(left: base, right: nil, frames: r.frames)
            } else {
                if systemStereo.count < r.frames * 2 { systemStereo = [Float](repeating: 0, count: r.frames * 2) }
                for i in 0..<r.frames {
                    systemStereo[i * 2] = base[i * r.channels]
                    systemStereo[i * 2 + 1] = base[i * r.channels + 1]
                }
                systemStereo.withUnsafeBufferPointer { systemRing.writeInterleaved($0.baseAddress!, frames: r.frames) }
            }
        }
    }

    private var systemReader = AudioSampleReader()
    private var systemSamples: [Float] = []
    private var systemStereo: [Float] = []
    private var systemFailures = 0

    // MARK: - Fallback clock

    /// Keeps BGM and system audio flowing into the recording when there is no microphone.
    func startFallbackClock() {
        clockQueue.async { [weak self] in
            guard let self, self.clockTimer == nil else { return }
            let t = DispatchSource.makeTimerSource(flags: .strict, queue: self.clockQueue)
            t.schedule(deadline: .now(), repeating: 0.01, leeway: .milliseconds(1))
            let zeros = [Float](repeating: 0, count: 480)
            t.setEventHandler { [weak self] in
                guard let self else { return }
                let now = CACurrentMediaTime()
                if now - self.lastMicCallback < 0.25 { return }
                zeros.withUnsafeBufferPointer { p in
                    self.process(mic: p.baseAddress!, frames: 480, pts: now - 0.01, fromClock: true)
                }
            }
            t.resume()
            self.clockTimer = t
        }
    }

    func stopFallbackClock() {
        clockQueue.async { [weak self] in
            self?.clockTimer?.cancel()
            self?.clockTimer = nil
        }
    }

    // MARK: - Mixing

    func processMic(_ samples: UnsafePointer<Float>, frames: Int, pts: Double) {
        lastMicCallback = CACurrentMediaTime()
        process(mic: samples, frames: frames, pts: pts, fromClock: false)
    }

    private func process(mic samples: UnsafePointer<Float>, frames n: Int, pts rawPTS: Double, fromClock: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let c = cfg
        if mic.count < n {
            mic = [Float](repeating: 0, count: n)
            duck = [Float](repeating: 0, count: n)
            bgmL = [Float](repeating: 0, count: n)
            bgmR = [Float](repeating: 0, count: n)
            sys = [Float](repeating: 0, count: n * 2)
            mix = [Float](repeating: 0, count: n * 2)
            monitorBuf = [Float](repeating: 0, count: n * 2)
        }
        // Sanity check of the capture clock against the host clock.
        let now = CACurrentMediaTime()
        let pts = !trustsTimestamps && abs(rawPTS - now) > 10 ? now - Double(n) / 48000 : rawPTS

        var peakIn: Float = 0
        for i in 0..<n {
            var x = fromClock ? 0 : samples[i]
            if c.highPass { x = highPass.process(x) }
            x *= c.micGain
            if c.gate { x = gate.process(x) }
            if c.micMuted { x = 0 }
            mic[i] = x
            peakIn = max(peakIn, abs(x))
            duck[i] = ducker.process(voice: x, enabled: c.ducking)
        }

        bgmL.withUnsafeMutableBufferPointer { l in
            bgmR.withUnsafeMutableBufferPointer { r in
                bgm.render(frames: n, l: l.baseAddress!, r: r.baseAddress!)
            }
        }

        // Keep system audio latency bounded (handles clock drift between devices).
        let avail = systemRing.available
        if avail > n + 4800 { systemRing.discard(avail - n - 2400) }
        sys.withUnsafeMutableBufferPointer { s in
            _ = systemRing.read(into: s.baseAddress!, frames: n)
        }

        var peakOut: Float = 0
        for i in 0..<n {
            let g = c.bgmGain * duck[i]
            let bl = bgmL[i] * g, br = bgmR[i] * g
            var l = mic[i] + bl + sys[i * 2] * c.systemGain
            var r = mic[i] + br + sys[i * 2 + 1] * c.systemGain
            if c.limiter { limiter.process(&l, &r) }
            mix[i * 2] = l
            mix[i * 2 + 1] = r
            monitorBuf[i * 2] = bl
            monitorBuf[i * 2 + 1] = br
            peakOut = max(peakOut, max(abs(l), abs(r)))
        }

        levelLock.lock()
        micPeak = max(micPeak, peakIn)
        outPeak = max(outPeak, peakOut)
        levelLock.unlock()

        monitorBuf.withUnsafeBufferPointer { p in monitor.push(p.baseAddress!, frames: n) }

        guard let onMixed, let sb = makeSampleBuffer(frames: n, pts: pts + c.avOffset) else { return }
        onMixed(sb)
    }

    private func makeSampleBuffer(frames n: Int, pts: Double) -> CMSampleBuffer? {
        guard let fmt = formatDescription else { return nil }
        let bytes = n * 8
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                                                 flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
              let block else { return nil }
        let ok = mix.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard ok == noErr else { return nil }
        var sb: CMSampleBuffer?
        let time = CMTime(seconds: pts, preferredTimescale: 48000)
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: fmt,
                                                                   sampleCount: n, presentationTimeStamp: time,
                                                                   packetDescriptions: nil, sampleBufferOut: &sb) == noErr else { return nil }
        return sb
    }
}

/// Plays the BGM bus to the default output so the presenter can monitor it on headphones.
final class AudioMonitor {
    private var engine: AVAudioEngine?
    private let ring = StereoRing(capacityFrames: 48000)
    private let lock = NSLock()
    private var enabled = false
    private var scratch = [Float](repeating: 0, count: 8192)
    var volume: Float = 0.6

    func setEnabled(_ on: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard on != enabled else { return }
        enabled = on
        if on {
            ring.clear()
            let engine = AVAudioEngine()
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
            let node = AVAudioSourceNode(format: format) { [weak self] _, _, frameCount, abl in
                guard let self else { return noErr }
                let n = Int(frameCount)
                let list = UnsafeMutableAudioBufferListPointer(abl)
                guard list.count >= 2,
                      let l = list[0].mData?.assumingMemoryBound(to: Float.self),
                      let r = list[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
                if self.ring.available > 9600 { self.ring.discard(self.ring.available - 2400) }
                let count = min(n, self.scratch.count / 2)
                self.scratch.withUnsafeMutableBufferPointer { s in
                    self.ring.read(into: s.baseAddress!, frames: count)
                    let v = self.volume
                    for i in 0..<count {
                        l[i] = s[i * 2] * v
                        r[i] = s[i * 2 + 1] * v
                    }
                }
                if count < n {
                    for i in count..<n { l[i] = 0; r[i] = 0 }
                }
                return noErr
            }
            engine.attach(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            do {
                try engine.start()
                self.engine = engine
            } catch {
                NSLog("[Monitor] start failed: \(error)")
                enabled = false
            }
        } else {
            engine?.stop()
            engine = nil
        }
    }

    func push(_ interleaved: UnsafePointer<Float>, frames: Int) {
        guard enabled else { return }
        ring.writeInterleaved(interleaved, frames: frames)
    }
}
