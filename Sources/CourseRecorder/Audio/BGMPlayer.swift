import Foundation
import AVFoundation

struct BGMStatus: Equatable {
    var playing = false
    var trackName = ""
    var position: Double = 0
    var duration: Double = 0
    var index = 0
    var count = 0
}

/// Streams a playlist of audio files as 48 kHz stereo, pulled by the mixer.
final class BGMPlayer {
    private let lock = NSLock()
    private var tracks: [URL] = []
    private var index = 0
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var inBuffer: AVAudioPCMBuffer?
    private let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: false)!
    private let outBuffer: AVAudioPCMBuffer
    private var fifoL: [Float] = []
    private var fifoR: [Float] = []
    private var fifoPos = 0
    private var playing = false
    private var fade: Float = 0
    private var fadeStep: Float = 1.0 / (1.5 * 48000)
    private var framesPlayed: Int64 = 0
    private var duration: Double = 0
    var loopMode: BGMLoopMode = .playlist

    init() {
        outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: 4096)!
    }

    func setFadeSeconds(_ s: Double) {
        lock.lock()
        fadeStep = Float(1.0 / max(0.05, s) / 48000)
        lock.unlock()
    }

    func setTracks(_ paths: [String]) {
        let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        lock.lock()
        defer { lock.unlock() }
        let currentURL = tracks.indices.contains(index) ? tracks[index] : nil
        tracks = urls
        if let currentURL, let i = urls.firstIndex(of: currentURL) {
            index = i
        } else {
            index = 0
            closeLocked()
            if urls.isEmpty { playing = false }
        }
    }

    func play() {
        lock.lock()
        defer { lock.unlock() }
        guard !tracks.isEmpty else { return }
        if file == nil { _ = openLocked(index) }
        playing = file != nil
    }

    func pause() {
        lock.lock()
        playing = false
        lock.unlock()
    }

    func toggle() {
        if status().playing { pause() } else { play() }
    }

    func next() { jump(by: 1) }
    func previous() { jump(by: -1) }

    func select(_ i: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard tracks.indices.contains(i) else { return }
        if openLocked(i) {
            playing = true
            fade = 0
        }
    }

    private func jump(by d: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard !tracks.isEmpty else { return }
        let i = (index + d + tracks.count) % tracks.count
        if openLocked(i) {
            playing = true
            fade = 0
        }
    }

    func status() -> BGMStatus {
        lock.lock()
        defer { lock.unlock() }
        return BGMStatus(playing: playing,
                         trackName: tracks.indices.contains(index) ? tracks[index].deletingPathExtension().lastPathComponent : "",
                         position: Double(framesPlayed) / 48000,
                         duration: duration,
                         index: index,
                         count: tracks.count)
    }

    // MARK: - Rendering (mixer thread)

    /// Writes `frames` of BGM (with fades) into `l`/`r`.
    func render(frames: Int, l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        l.update(repeating: 0, count: frames)
        r.update(repeating: 0, count: frames)
        lock.lock()
        defer { lock.unlock() }
        if !playing && fade <= 0 { return }
        var produced = 0
        while produced < frames {
            if fifoL.count - fifoPos <= 0 {
                if !decodeLocked() { break }
                continue
            }
            let take = min(frames - produced, fifoL.count - fifoPos)
            for i in 0..<take {
                if playing {
                    if fade < 1 { fade = min(1, fade + fadeStep) }
                } else {
                    fade = max(0, fade - fadeStep)
                }
                l[produced + i] = fifoL[fifoPos + i] * fade
                r[produced + i] = fifoR[fifoPos + i] * fade
            }
            fifoPos += take
            produced += take
            framesPlayed += Int64(take)
            if !playing && fade <= 0 { break }
        }
    }

    private func decodeLocked() -> Bool {
        guard let file, let converter, let inBuffer else {
            return tracks.isEmpty ? false : advanceLocked()
        }
        if fifoPos > 0 {
            fifoL.removeFirst(fifoPos)
            fifoR.removeFirst(fifoPos)
            fifoPos = 0
        }
        outBuffer.frameLength = 0
        var reachedEnd = false
        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { packets, outStatus in
            let cap = min(AVAudioFrameCount(packets), inBuffer.frameCapacity)
            inBuffer.frameLength = 0
            do {
                try file.read(into: inBuffer, frameCount: cap)
            } catch {
                reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            if inBuffer.frameLength == 0 {
                reachedEnd = true
                outStatus.pointee = .endOfStream
                return nil
            }
            outStatus.pointee = .haveData
            return inBuffer
        }
        let n = Int(outBuffer.frameLength)
        if n > 0, let ch = outBuffer.floatChannelData {
            fifoL.append(contentsOf: UnsafeBufferPointer(start: ch[0], count: n))
            fifoR.append(contentsOf: UnsafeBufferPointer(start: ch[1], count: n))
        }
        if reachedEnd || status == .endOfStream || status == .error {
            if n > 0 {
                // Let the mixer drain what we decoded first; the next call advances.
                closeFileOnlyLocked()
                return true
            }
            return advanceLocked()
        }
        return n > 0
    }

    private func advanceLocked() -> Bool {
        guard !tracks.isEmpty else {
            playing = false
            return false
        }
        switch loopMode {
        case .single:
            return openLocked(index, resetFade: false)
        case .playlist:
            return openLocked((index + 1) % tracks.count, resetFade: false)
        case .once:
            if index + 1 < tracks.count {
                return openLocked(index + 1, resetFade: false)
            }
            playing = false
            fade = 0
            index = 0
            closeLocked()
            return false
        }
    }

    @discardableResult
    private func openLocked(_ i: Int, resetFade: Bool = true) -> Bool {
        closeLocked()
        guard tracks.indices.contains(i) else { return false }
        index = i
        do {
            let f = try AVAudioFile(forReading: tracks[i])
            let fmt = f.processingFormat
            guard let conv = AVAudioConverter(from: fmt, to: outFormat),
                  let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096) else { return false }
            if fmt.channelCount == 1 { conv.channelMap = [0, 0] }
            file = f
            converter = conv
            inBuffer = buf
            duration = Double(f.length) / fmt.sampleRate
            framesPlayed = 0
            if resetFade { fade = 0 }
            return true
        } catch {
            NSLog("[BGM] cannot open \(tracks[i].path): \(error)")
            return false
        }
    }

    private func closeFileOnlyLocked() {
        file = nil
        converter = nil
        inBuffer = nil
    }

    private func closeLocked() {
        closeFileOnlyLocked()
        fifoL.removeAll(keepingCapacity: true)
        fifoR.removeAll(keepingCapacity: true)
        fifoPos = 0
    }
}
