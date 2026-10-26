import Foundation
import AVFoundation
import CoreVideo

/// Sequential frame access to a video file for offline rendering: `frame(at:)` returns the newest frame whose
/// presentation time is not after the requested time.
final class VideoFrameReader {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var current: (pts: Double, buffer: CVPixelBuffer)?
    private var next: (pts: Double, buffer: CVPixelBuffer)?
    private(set) var finished = false
    let naturalSize: CGSize

    /// `from` is the file time to start reading at.
    init?(url: URL, from: Double = 0) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first, let r = try? AVAssetReader(asset: asset) else { return nil }
        naturalSize = track.naturalSize
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ])
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return nil }
        r.add(out)
        if from > 0 { r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600), duration: .positiveInfinity) }
        guard r.startReading() else { return nil }
        reader = r
        output = out
    }

    private func readNext() -> (pts: Double, buffer: CVPixelBuffer)? {
        guard !finished, let sb = output.copyNextSampleBuffer() else {
            finished = true
            return nil
        }
        guard let pb = CMSampleBufferGetImageBuffer(sb) else { return readNext() }
        return (CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb)), pb)
    }

    func frame(at t: Double) -> CVPixelBuffer? {
        if next == nil, !finished { next = readNext() }
        while let n = next, n.pts <= t + 1e-6 {
            current = n
            next = readNext()
        }
        return current?.buffer
    }

    func cancel() { reader.cancelReading() }
}

/// Reads a file's audio as 48 kHz mono float samples, in order.
final class AudioSampleStream {
    private let reader: AVAssetReader
    private let output: AVAssetReaderTrackOutput
    private var sampleReader = AudioSampleReader()
    private var scratch: [Float] = []
    private(set) var finished = false

    init?(url: URL) {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first, let r = try? AVAssetReader(asset: asset) else { return nil }
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        out.alwaysCopiesSampleData = false
        guard r.canAdd(out) else { return nil }
        r.add(out)
        guard r.startReading() else { return nil }
        reader = r
        output = out
    }

    /// Next chunk of samples with the presentation time of its first sample, or nil at the end.
    func next() -> (pts: Double, samples: [Float])? {
        while !finished {
            guard let sb = output.copyNextSampleBuffer() else {
                finished = true
                return nil
            }
            guard let r = sampleReader.read(sb, into: &scratch), r.frames > 0 else { continue }
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sb))
            if r.channels == 1 {
                return (pts, Array(scratch[0..<r.frames]))
            }
            var mono = [Float](repeating: 0, count: r.frames)
            for i in 0..<r.frames {
                var s: Float = 0
                for c in 0..<r.channels { s += scratch[i * r.channels + c] }
                mono[i] = s / Float(r.channels)
            }
            return (pts, mono)
        }
        return nil
    }

    func cancel() { reader.cancelReading() }
}
