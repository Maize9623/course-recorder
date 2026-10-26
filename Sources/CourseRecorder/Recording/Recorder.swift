import Foundation
import AVFoundation
import VideoToolbox
import QuartzCore

struct RecorderOptions {
    var url: URL
    var size: CGSize
    var fps: Int
    var codec: VideoCodec
    var bitrate: Int
    /// Starts a new file after this much recording time, so a crash or force quit loses at most one segment.
    var segmentSeconds: Double? = nil
    /// Offline rendering: frames are written synchronously and the caller waits for the encoder instead of
    /// dropping frames when it is busy.
    var offline = false
}

struct RecordingMarker: Identifiable, Equatable {
    enum Kind: String { case chapter = "章节", mistake = "口误待剪" }
    let id = UUID()
    let time: Double
    let kind: Kind
    var note: String
}

struct RecorderStats {
    var duration: Double = 0
    var framesWritten = 0
    var framesDropped = 0
}

struct RecordingResult {
    var files: [URL] = []
    /// Segment numbers (1-based) whose file could not be finished.
    var failedSegments: [Int] = []
    var error: Error?
}

/// One output file. Its time zero is global frame `startIndex`. Only touched on the recorder queue.
private final class Segment {
    let number: Int
    let url: URL
    let writer: AVAssetWriter
    let video: AVAssetWriterInput
    let audio: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let startIndex: Int
    /// Frame index where the next file took over; nothing from there on belongs to this one.
    var endIndex: Int?
    /// Frame index at which the next file is due to take over.
    var plannedEndIndex: Int?
    var lastPTS = -1
    var closed = false
    var audioFinished = false

    init(number: Int, url: URL, writer: AVAssetWriter, video: AVAssetWriterInput, audio: AVAssetWriterInput,
         adaptor: AVAssetWriterInputPixelBufferAdaptor, startIndex: Int) {
        self.number = number
        self.url = url
        self.writer = writer
        self.video = video
        self.audio = audio
        self.adaptor = adaptor
        self.startIndex = startIndex
    }
}

/// Writes composited frames and mixed audio to MP4 files. Every file is a plain (non-fragmented) MP4: AVAssetWriter
/// fails to finalize fragmented MP4s (`MovieHeaderMaker` -16341) and loses everything after the first fragment.
/// Long recordings are split into segments instead; each one is finished while the next keeps recording.
final class Recorder: FrameSink {
    enum State { case idle, recording, paused, finishing }

    private let queue = DispatchQueue(label: "recorder.writer", qos: .userInitiated)

    // Only touched on `queue`.
    private var options: RecorderOptions?
    private var current: Segment?
    private var upcoming: Segment?
    private var retiring: [Segment] = []
    private var segmentCount = 0
    private var prepareRetryIndex = 0
    private var stopping = false
    private var finishGroup = DispatchGroup()
    private var saved: [(number: Int, url: URL, start: Double, end: Double)] = []
    private var failedSegments: [Int] = []
    private var lastError: Error?

    private let lock = NSLock()
    private var state: State = .idle
    private var startHost: Double?
    private var pausedTotal: Double = 0
    private var pauseStart: Double?
    private var lastFrameIndex = -1
    /// Next audio sample position (48 kHz, recording time); -1 until the first buffer.
    private var nextSample: Int64 = -1
    private var stats = RecorderStats()
    private var sessionStarted = false
    private var recordingFPS = 60

    /// Main thread. A new file took over; `reason` is set when the previous file failed rather than filled up.
    var onSegmentStarted: ((URL, Int, Error?) -> Void)?
    /// Main thread. A file closed during recording was saved (`error == nil`) or could not be finished.
    var onSegmentSaved: ((URL, Int, Error?) -> Void)?
    /// Main thread. Recording can't continue at all (e.g. the disk is full).
    var onFailure: ((Error?) -> Void)?

    var currentState: State {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    func start(_ o: RecorderOptions) throws {
        try? FileManager.default.createDirectory(at: o.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let first = try Self.makeSegment(o, number: 1, startIndex: 0)
        if let s = o.segmentSeconds { first.plannedEndIndex = Int(s * Double(o.fps)) }
        queue.sync {
            options = o
            current = first
            upcoming = nil
            retiring = []
            segmentCount = 1
            prepareRetryIndex = 0
            stopping = false
            finishGroup = DispatchGroup()
            saved = []
            failedSegments = []
            lastError = nil
        }
        lock.lock()
        state = .recording
        recordingFPS = o.fps
        offlineMode = o.offline
        startHost = nil
        pausedTotal = 0
        pauseStart = nil
        lastFrameIndex = -1
        nextSample = -1
        stats = RecorderStats()
        sessionStarted = false
        lock.unlock()
    }

    func pause(at time: Double = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .recording else { return }
        state = .paused
        pauseStart = time
    }

    func resume(at time: Double = CACurrentMediaTime()) {
        lock.lock()
        defer { lock.unlock() }
        guard state == .paused else { return }
        if let p = pauseStart { pausedTotal += time - p }
        pauseStart = nil
        state = .recording
    }

    func currentStats() -> RecorderStats {
        lock.lock()
        defer { lock.unlock() }
        var s = stats
        if let start = startHost {
            let now = pauseStart ?? CACurrentMediaTime()
            s.duration = max(0, now - start - pausedTotal)
        }
        return s
    }

    /// Recording time (excluding pauses) for a host time, used for markers.
    func recordingTime(at host: Double = CACurrentMediaTime()) -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard let start = startHost else { return 0 }
        let now = pauseStart ?? host
        return max(0, now - start - pausedTotal)
    }

    // MARK: - Video

    func consume(_ pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
        lock.lock()
        guard state == .recording else {
            lock.unlock()
            return
        }
        if startHost == nil { startHost = hostTime }
        let t = hostTime - startHost! - pausedTotal
        let index = Int((t * Double(recordingFPS)).rounded())
        guard index > lastFrameIndex else {
            lock.unlock()
            return
        }
        lastFrameIndex = index
        sessionStarted = true
        let offline = offlineMode
        lock.unlock()
        if offline {
            queue.sync { self.writeVideo(pixelBuffer, index: index) }
        } else {
            queue.async { [weak self] in self?.writeVideo(pixelBuffer, index: index) }
        }
    }

    private var offlineMode = false

    /// Offline mode: blocks (briefly) until the input accepts more data instead of dropping.
    private func waitUntilReady(_ input: AVAssetWriterInput) -> Bool {
        guard offlineMode else { return input.isReadyForMoreMediaData }
        let deadline = CACurrentMediaTime() + 5
        while !input.isReadyForMoreMediaData {
            if CACurrentMediaTime() > deadline { return false }
            usleep(1000)
        }
        return true
    }

    /// Offline rendering: whether each input would accept more data now. The writer interleaves the tracks, so it
    /// can hold one input until the other has caught up; the caller feeds whichever is ready.
    var inputReadiness: (video: Bool, audio: Bool) {
        queue.sync {
            guard let c = current, c.writer.status == .writing else { return (false, false) }
            return (c.video.isReadyForMoreMediaData, !c.audioFinished && c.audio.isReadyForMoreMediaData)
        }
    }

    /// Offline rendering: there is no more audio, so the writer must stop waiting for it.
    func finishAudioInput() {
        queue.sync {
            guard let c = current, !c.audioFinished, c.writer.status == .writing else { return }
            c.audioFinished = true
            c.audio.markAsFinished()
        }
    }

    /// Runs on `queue`.
    private func writeVideo(_ pixelBuffer: CVPixelBuffer, index: Int) {
        guard let o = options, !stopping, var seg = current else { return }
        if let end = seg.plannedEndIndex {
            if upcoming == nil, index >= end - 5 * o.fps, index >= prepareRetryIndex {
                prepareUpcoming(startIndex: end, now: index)
            }
            if index >= end {
                switchSegment(at: end, now: index)
                guard let next = current else { return }
                seg = next
            }
        }
        if seg.writer.status == .failed {
            abandon(seg, at: index, reason: seg.writer.error)
            guard let next = current else { return }
            seg = next
        }
        // A file's first frame is shown from its very start, even if a late render tick skipped ahead.
        let pts = seg.lastPTS < 0 ? 0 : index - seg.startIndex
        guard seg.writer.status == .writing, pts > seg.lastPTS else { return }
        if waitUntilReady(seg.video),
           seg.adaptor.append(pixelBuffer, withPresentationTime: CMTime(value: CMTimeValue(pts), timescale: CMTimeScale(o.fps))) {
            seg.lastPTS = pts
            bump(written: true)
        } else {
            bump(written: false)
        }
    }

    private func bump(written: Bool) {
        lock.lock()
        if written { stats.framesWritten += 1 } else { stats.framesDropped += 1 }
        lock.unlock()
    }

    // MARK: - Audio

    /// How far buffer timestamps may wander from the running sample count before it is corrected. Within it the
    /// audio stays one contiguous stream: AVAssetWriter closes up small gaps, which would make the sound drift ahead
    /// of the picture over a long recording.
    private static let audioTolerance: Int64 = 960

    func appendAudio(_ sb: CMSampleBuffer) {
        lock.lock()
        guard state == .recording, let start = startHost, sessionStarted else {
            lock.unlock()
            return
        }
        let host = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
        let frames = CMSampleBufferGetNumSamples(sb)
        let ideal = Int64(((host - start - pausedTotal) * 48000).rounded())
        var at = ideal
        var skip = 0
        var gap = 0
        if nextSample >= 0 {
            let drift = ideal - nextSample
            if drift > Self.audioTolerance && drift <= 30 * 48000 {
                gap = Int(drift)
            } else if drift < -Self.audioTolerance {
                skip = Int(-drift)
                at = nextSample
            } else if drift <= Self.audioTolerance {
                at = nextSample
            }
        }
        if at < 0 {
            skip += Int(-at)
            at = 0
        }
        guard skip < frames else {
            lock.unlock()
            return
        }
        nextSample = at + Int64(frames - skip)
        let offline = offlineMode
        lock.unlock()

        let work = { [weak self] in
            guard let self else { return }
            if gap > 0, let quiet = Self.silence(frames: gap, like: sb) { self.writeAudio(quiet, from: 0, at: at - Int64(gap)) }
            self.writeAudio(sb, from: skip, at: at)
        }
        if offline { queue.sync(execute: work) } else { queue.async(execute: work) }
    }

    /// Runs on `queue`. Audio is routed by its own sample position, so samples that arrive just after a hand-over still
    /// land in the file they belong to, and a buffer crossing the hand-over is split exactly between both files.
    private func writeAudio(_ sb: CMSampleBuffer, from skip: Int, at s: Int64) {
        guard let o = options, !stopping else { return }
        func sample(_ frameIndex: Int) -> Int64 { Int64((Double(frameIndex) * 48000 / Double(o.fps)).rounded()) }
        let n = Int64(CMSampleBufferGetNumSamples(sb) - skip)
        var chain = retiring.filter { !$0.closed }
        if let c = current { chain.append(c) }
        if let u = upcoming { chain.append(u) }
        for (i, seg) in chain.enumerated() {
            let segStart = sample(seg.startIndex)
            let segEnd = seg.endIndex.map(sample) ?? (i + 1 < chain.count ? sample(chain[i + 1].startIndex) : Int64.max)
            let from = max(0, segStart - s)
            let to = segEnd == .max ? n : min(n, segEnd - s)
            guard to > from else { continue }
            append(sb, range: (skip + Int(from))..<(skip + Int(to)), pts: s + from - segStart, to: seg)
        }
    }

    private static func silence(frames: Int, like sb: CMSampleBuffer) -> CMSampleBuffer? {
        guard let format = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        let bytes = frames * Int(asbd.mBytesPerFrame)
        var block: CMBlockBuffer?
        guard bytes > 0,
              CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr,
              let block,
              CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes) == noErr
        else { return nil }
        var out: CMSampleBuffer?
        guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: kCFAllocatorDefault, dataBuffer: block,
                                                                   formatDescription: format, sampleCount: frames,
                                                                   presentationTimeStamp: .zero, packetDescriptions: nil,
                                                                   sampleBufferOut: &out) == noErr else { return nil }
        return out
    }

    private func append(_ sb: CMSampleBuffer, range: Range<Int>, pts: Int64, to seg: Segment) {
        guard !seg.closed, !seg.audioFinished, seg.writer.status == .writing, waitUntilReady(seg.audio) else { return }
        var piece = sb
        if range.count != CMSampleBufferGetNumSamples(sb) {
            var sub: CMSampleBuffer?
            guard CMSampleBufferCopySampleBufferForRange(allocator: nil, sampleBuffer: sb,
                                                         sampleRange: CFRange(location: range.lowerBound, length: range.count),
                                                         sampleBufferOut: &sub) == noErr, let sub else { return }
            piece = sub
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000),
                                        presentationTimeStamp: CMTime(value: CMTimeValue(max(0, pts)), timescale: 48000),
                                        decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: piece, sampleTimingEntryCount: 1,
                                                    sampleTimingArray: &timing, sampleBufferOut: &retimed) == noErr,
              let retimed else { return }
        seg.audio.append(retimed)
    }

    // MARK: - Segments

    /// Opens the next file a few seconds ahead, so the hand-over itself costs nothing.
    private func prepareUpcoming(startIndex: Int, now: Int) {
        guard let o = options else { return }
        do {
            upcoming = try Self.makeSegment(o, number: segmentCount + 1, startIndex: startIndex)
        } catch {
            prepareRetryIndex = now + 2 * o.fps
            lastError = error
        }
    }

    /// Planned hand-over at frame `boundary`: the current file is full.
    private func switchSegment(at boundary: Int, now: Int) {
        guard let o = options, let old = current else { return }
        var next = upcoming
        if let u = upcoming, u.startIndex != boundary {
            discard(u)
            next = nil
        }
        upcoming = nil
        if next == nil { next = try? Self.makeSegment(o, number: segmentCount + 1, startIndex: boundary) }
        guard let next else {
            // The next file can't be opened right now: keep writing this one and try again shortly.
            old.plannedEndIndex = now + 10 * o.fps
            prepareRetryIndex = now + 5 * o.fps
            return
        }
        if let s = o.segmentSeconds { next.plannedEndIndex = boundary + Int(s * Double(o.fps)) }
        segmentCount = next.number
        old.endIndex = boundary
        retiring.append(old)
        current = next
        let url = next.url, number = next.number
        DispatchQueue.main.async { self.onSegmentStarted?(url, number, nil) }
        // Audio for the old file's last moments arrives a little after its video; finish it once that is in.
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.close(old) }
    }

    /// The current file's writer failed and can't be finished; recording continues in a new file from `index`.
    private func abandon(_ failed: Segment, at index: Int, reason: Error?) {
        guard let o = options else { return }
        if let u = upcoming {
            discard(u)
            upcoming = nil
        }
        failed.endIndex = index
        do {
            let next = try Self.makeSegment(o, number: segmentCount + 1, startIndex: index)
            if let s = o.segmentSeconds { next.plannedEndIndex = index + Int(s * Double(o.fps)) }
            segmentCount = next.number
            current = next
            close(failed)
            let url = next.url, number = next.number
            let why = reason ?? NSError(domain: "Recorder", code: 4, userInfo: [NSLocalizedDescriptionKey: "文件写入出错"])
            DispatchQueue.main.async { self.onSegmentStarted?(url, number, why) }
        } catch {
            current = nil
            close(failed)
            lastError = error
            DispatchQueue.main.async { self.onFailure?(error) }
        }
    }

    /// Self-test hook: hands over to a new file as if the current writer had just failed.
    func simulateWriterFailure() {
        queue.async { [weak self] in
            guard let self, let seg = self.current else { return }
            self.lock.lock()
            let index = self.lastFrameIndex + 1
            self.lock.unlock()
            self.abandon(seg, at: index, reason: NSError(domain: "Recorder", code: 9, userInfo: [NSLocalizedDescriptionKey: "模拟写入失败"]))
        }
    }

    /// Removes a prepared file that never took over.
    private func discard(_ seg: Segment) {
        seg.closed = true
        seg.writer.cancelWriting()
    }

    /// Finishes a file that no longer receives frames. Runs on `queue`.
    private func close(_ seg: Segment) {
        guard !seg.closed, let o = options else { return }
        seg.closed = true
        retiring.removeAll { $0 === seg }
        guard seg.writer.status == .writing else {
            failedSegments.append(seg.number)
            let error = seg.writer.error
            lastError = error
            if !stopping { DispatchQueue.main.async { self.onSegmentSaved?(seg.url, seg.number, error) } }
            return
        }
        guard seg.lastPTS >= 0, let end = seg.endIndex else {
            seg.writer.cancelWriting()
            return
        }
        seg.video.markAsFinished()
        if !seg.audioFinished {
            seg.audioFinished = true
            seg.audio.markAsFinished()
        }
        seg.writer.endSession(atSourceTime: CMTime(value: CMTimeValue(end - seg.startIndex), timescale: CMTimeScale(o.fps)))
        let group = finishGroup
        let span = (start: Double(seg.startIndex) / Double(o.fps), end: Double(end) / Double(o.fps))
        group.enter()
        seg.writer.finishWriting {
            let error: Error? = seg.writer.status == .completed ? nil
                : (seg.writer.error ?? NSError(domain: "Recorder", code: 5, userInfo: [NSLocalizedDescriptionKey: "文件没能写完"]))
            self.queue.async {
                if let error {
                    self.failedSegments.append(seg.number)
                    self.lastError = error
                } else {
                    self.saved.append((seg.number, seg.url, span.start, span.end))
                }
                if !self.stopping { DispatchQueue.main.async { self.onSegmentSaved?(seg.url, seg.number, error) } }
                group.leave()
            }
        }
    }

    private static func makeSegment(_ o: RecorderOptions, number: Int, startIndex: Int) throws -> Segment {
        let base = o.url.deletingPathExtension().lastPathComponent
        let url = number == 1 ? o.url : o.url.deletingLastPathComponent().appendingPathComponent("\(base)（第\(number)段）.mp4")
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
        w.shouldOptimizeForNetworkUse = false

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: o.bitrate,
            AVVideoExpectedSourceFrameRateKey: o.fps,
            AVVideoMaxKeyFrameIntervalKey: o.fps * 2,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        if o.codec == .h264 {
            compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel
            compression[AVVideoH264EntropyModeKey] = AVVideoH264EntropyModeCABAC
        } else {
            compression[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String
        }
        let videoSettings: [String: Any] = [
            AVVideoCodecKey: o.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(o.size.width),
            AVVideoHeightKey: Int(o.size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        vIn.expectsMediaDataInRealTime = !o.offline
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vIn, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(o.size.width),
            kCVPixelBufferHeightKey as String: Int(o.size.height),
        ])
        let audioSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 192_000,
        ]
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
        aIn.expectsMediaDataInRealTime = !o.offline
        guard w.canAdd(vIn), w.canAdd(aIn) else {
            throw NSError(domain: "Recorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法创建视频/音频轨道"])
        }
        w.add(vIn)
        w.add(aIn)
        guard w.startWriting() else {
            throw w.error ?? NSError(domain: "Recorder", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法开始写入文件"])
        }
        w.startSession(atSourceTime: .zero)
        return Segment(number: number, url: url, writer: w, video: vIn, audio: aIn, adaptor: ad, startIndex: startIndex)
    }

    // MARK: - Finish

    func stop(markers: [RecordingMarker], completion: @escaping (RecordingResult) -> Void) {
        lock.lock()
        guard state == .recording || state == .paused else {
            lock.unlock()
            completion(RecordingResult())
            return
        }
        state = .finishing
        let endIndex = lastFrameIndex
        lock.unlock()

        // Strong capture on purpose: a recorder that is being stopped stays alive until its files are finished,
        // even if nothing else references it any more (short-lived take recorders).
        queue.async {
            self.stopping = true
            if let u = self.upcoming {
                self.discard(u)
                self.upcoming = nil
            }
            if let c = self.current {
                c.endIndex = endIndex + 1
                self.current = nil
                self.close(c)
            }
            for seg in self.retiring { self.close(seg) }
            self.finishGroup.notify(queue: self.queue) {
                let files = self.saved.sorted { $0.number < $1.number }
                for f in files {
                    let inside = markers.filter { $0.time >= f.start && $0.time < f.end }
                        .map { RecordingMarker(time: $0.time - f.start, kind: $0.kind, note: $0.note) }
                    Self.writeMarkers(inside, for: f.url)
                }
                var result = RecordingResult(files: files.map(\.url), failedSegments: self.failedSegments.sorted())
                if files.isEmpty {
                    result.error = self.lastError
                        ?? NSError(domain: "Recorder", code: 3, userInfo: [NSLocalizedDescriptionKey: "没有录到任何画面"])
                }
                self.options = nil
                self.retiring = []
                self.lock.lock()
                self.state = .idle
                self.startHost = nil
                self.lock.unlock()
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    static func writeMarkers(_ markers: [RecordingMarker], for url: URL) {
        guard !markers.isEmpty else { return }
        var lines = ["# \(url.lastPathComponent) 打点标记", "# 时间\t类型\t备注"]
        for m in markers.sorted(by: { $0.time < $1.time }) {
            lines.append("\(formatTimecode(m.time))\t\(m.kind.rawValue)\t\(m.note)")
        }
        let txt = url.deletingPathExtension().appendingPathExtension("markers.txt")
        try? lines.joined(separator: "\n").write(to: txt, atomically: true, encoding: .utf8)
        // SRT version: imports into 剪映 / Premiere / Final Cut as a caption track with the marks.
        var srt: [String] = []
        for (i, m) in markers.sorted(by: { $0.time < $1.time }).enumerated() {
            srt.append("\(i + 1)")
            srt.append("\(srtTime(m.time)) --> \(srtTime(m.time + 2))")
            srt.append("【\(m.kind.rawValue)】\(m.note)")
            srt.append("")
        }
        let srtURL = url.deletingPathExtension().appendingPathExtension("markers.srt")
        try? srt.joined(separator: "\n").write(to: srtURL, atomically: true, encoding: .utf8)
    }

    static func srtTime(_ t: Double) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, ms % 1000)
    }
}

func formatTimecode(_ t: Double) -> String {
    let s = max(0, Int(t))
    return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
}
