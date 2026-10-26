import Foundation
import AVFoundation
import CryptoKit

/// Joins only the ordered files returned by one successful Recorder.stop; never discovers old recordings.
final class RecordingSegmentMerger {
    struct MergeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct SourceIdentity: Equatable {
        let url: URL
        let size: UInt64
        let modified: Date
        let fileNumber: UInt64

        static func read(_ url: URL) throws -> SourceIdentity {
            guard url.isFileURL else { throw MergeError(message: "分段不是本机文件") }
            let values = try FileManager.default.attributesOfItem(atPath: url.path)
            guard values[.type] as? FileAttributeType == .typeRegular,
                  let size = values[.size] as? NSNumber, size.uint64Value > 0,
                  let modified = values[.modificationDate] as? Date,
                  let number = values[.systemFileNumber] as? NSNumber else {
                throw MergeError(message: "分段文件无效或为空：\(url.lastPathComponent)")
            }
            return SourceIdentity(url: url.standardizedFileURL, size: size.uint64Value,
                                  modified: modified, fileNumber: number.uint64Value)
        }
    }

    struct MergedRecording {
        let url: URL
        let sourceFiles: [URL]
        let duration: Double
        let videoFrameCount: Int
        fileprivate let identities: [SourceIdentity]
        fileprivate let outputIdentity: SourceIdentity

        /// The caller must check again immediately before moving source segments to Trash.
        func validateSourcesUnchanged() throws {
            guard try SourceIdentity.read(url) == outputIdentity else {
                throw MergeError(message: "合并成片发生变化，已保留所有原分段")
            }
            for expected in identities {
                guard try SourceIdentity.read(expected.url) == expected else {
                    throw MergeError(message: "分段在合并期间发生变化，已保留所有原文件：\(expected.url.lastPathComponent)")
                }
            }
        }
    }

    private let lock = NSLock()
    private var cancelled = false
    private var exportSession: AVAssetExportSession?

    func cancel() {
        lock.lock()
        cancelled = true
        let active = exportSession
        lock.unlock()
        active?.cancelExport()
    }

    private func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }

    /// Uses compressed passthrough only. An incompatible or unverifiable set stays as source segments.
    func merge(files: [URL], progress: @escaping (Double, String) -> Void) async throws -> MergedRecording {
        try checkCancellation()
        guard files.count > 1 else { throw MergeError(message: "至少需要两个录制分段才能合并") }
        let sources = files.map(\.standardizedFileURL)
        guard Set(sources).count == sources.count, let first = sources.first else {
            throw MergeError(message: "分段列表包含重复文件")
        }
        let parent = first.deletingLastPathComponent()
        guard sources.allSatisfy({ $0.deletingLastPathComponent() == parent }) else {
            throw MergeError(message: "同一次录制的分段必须位于同一目录")
        }
        let identities = try sources.map(SourceIdentity.read)
        progress(0, "正在检查录制分段…")
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw MergeError(message: "无法创建合并音画轨道")
        }
        var total = CMTime.zero
        var expectedVideo = SHA256()
        var expectedFrames = 0
        var expectedSize: CGSize?
        var expectedTransform: CGAffineTransform?
        var expectedCodec: FourCharCode?
        var tolerance = 0.05
        for (index, url) in sources.enumerated() {
            try checkCancellation()
            let asset = AVURLAsset(url: url)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            guard videos.count == 1, audios.count == 1, let video = videos.first, let audio = audios.first else {
                throw MergeError(message: "分段缺少完整音画轨道：\(url.lastPathComponent)")
            }
            let videoRange = try await video.load(.timeRange)
            let audioRange = try await audio.load(.timeRange)
            let seconds = CMTimeGetSeconds(videoRange.duration)
            let fps = try await video.load(.nominalFrameRate)
            let localTolerance = max(0.05, fps > 0 ? 1 / Double(fps) : 0.05)
            tolerance = max(tolerance, localTolerance)
            guard videoRange.isValid, audioRange.isValid, seconds.isFinite, seconds > 0,
                  abs(CMTimeGetSeconds(CMTimeSubtract(audioRange.start, videoRange.start))) <= localTolerance,
                  abs(CMTimeGetSeconds(CMTimeSubtract(CMTimeRangeGetEnd(audioRange), CMTimeRangeGetEnd(videoRange)))) <= localTolerance else {
                throw MergeError(message: "分段的声音和画面时长不一致，未合并：\(url.lastPathComponent)")
            }
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let formats = try await video.load(.formatDescriptions)
            guard let format = formats.first else { throw MergeError(message: "分段缺少视频格式") }
            let codec = CMFormatDescriptionGetMediaSubType(format)
            if let expectedSize, let expectedTransform, let expectedCodec {
                guard size == expectedSize, transform == expectedTransform, codec == expectedCodec else {
                    throw MergeError(message: "分段画幅或编码不同，已保留原文件")
                }
            } else {
                expectedSize = size; expectedTransform = transform; expectedCodec = codec
                picture.preferredTransform = transform
            }
            // Every boundary follows video duration, so AAC padding cannot accumulate as sync drift.
            try picture.insertTimeRange(videoRange, of: video, at: total)
            let overlap = CMTimeRangeGetIntersection(videoRange, otherRange: audioRange)
            guard overlap.isValid, CMTimeGetSeconds(overlap.duration) > 0 else {
                throw MergeError(message: "分段没有可同步的声音")
            }
            try sound.insertTimeRange(overlap, of: audio,
                                      at: CMTimeAdd(total, CMTimeSubtract(overlap.start, videoRange.start)))
            total = CMTimeAdd(total, videoRange.duration)
            expectedFrames += try hashVideo(asset: asset, track: video, into: &expectedVideo)
            progress(0.02 + 0.13 * Double(index + 1) / Double(sources.count), "已检查第 \(index + 1) / \(sources.count) 段…")
        }
        let totalSeconds = CMTimeGetSeconds(total)
        guard totalSeconds.isFinite, totalSeconds > 0, expectedFrames > 0 else {
            throw MergeError(message: "分段总时长或画面无效")
        }
        let temporary = parent.appendingPathComponent(".recording-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer {
            lock.lock(); exportSession = nil; lock.unlock()
            try? FileManager.default.removeItem(at: temporary)
        }
        let output = temporary.appendingPathComponent("完整录制.mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough),
              exporter.supportedFileTypes.contains(.mp4) else {
            throw MergeError(message: "系统无法无损合并这些分段，已保留原文件")
        }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.timeRange = CMTimeRange(start: .zero, duration: total)
        exporter.shouldOptimizeForNetworkUse = false
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { progress(0.15 + Double(exporter.progress) * 0.6, "正在合并完整录制，保留原画质…") }
        timer.resume()
        defer { timer.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                guard !self.cancelled else {
                    self.lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.exportSession = exporter
                exporter.exportAsynchronously {
                    switch exporter.status {
                    case .completed: continuation.resume()
                    case .cancelled: continuation.resume(throwing: CancellationError())
                    default: continuation.resume(throwing: exporter.error ?? MergeError(message: "分段合并未完成，已保留原文件"))
                    }
                }
                self.lock.unlock()
            }
        }, onCancel: { self.cancel() })
        timer.cancel()
        try checkCancellation()
        progress(0.76, "正在核对完整视频与声音…")
        let joined = AVURLAsset(url: output)
        guard let joinedVideo = try await joined.loadTracks(withMediaType: .video).first,
              let joinedAudio = try await joined.loadTracks(withMediaType: .audio).first else {
            throw MergeError(message: "合并结果缺少音画轨道，已保留原分段")
        }
        let joinedVideoRange = try await joinedVideo.load(.timeRange)
        let joinedAudioRange = try await joinedAudio.load(.timeRange)
        let resultSize = try await joinedVideo.load(.naturalSize)
        let resultTransform = try await joinedVideo.load(.preferredTransform)
        guard resultSize == expectedSize, resultTransform == expectedTransform,
              abs(CMTimeGetSeconds(joinedVideoRange.start)) <= tolerance,
              abs(CMTimeGetSeconds(joinedAudioRange.start)) <= tolerance,
              abs(CMTimeGetSeconds(joinedVideoRange.duration) - totalSeconds) <= tolerance,
              abs(CMTimeGetSeconds(CMTimeRangeGetEnd(joinedAudioRange)) - totalSeconds) <= tolerance else {
            throw MergeError(message: "合并结果的时长或画幅核对失败，已保留原分段")
        }
        var actualVideo = SHA256()
        let actualFrames = try hashVideo(asset: joined, track: joinedVideo, into: &actualVideo)
        guard actualFrames == expectedFrames, actualVideo.finalize() == expectedVideo.finalize() else {
            throw MergeError(message: "合并结果的画面数量或顺序核对失败，已保留原分段")
        }
        progress(0.87, "正在核对音频完整性…")
        try validateAudio(asset: joined, track: joinedAudio, duration: totalSeconds, tolerance: tolerance)
        let target = uniqueOutput(beside: first)
        for expected in identities {
            guard try SourceIdentity.read(expected.url) == expected else {
                throw MergeError(message: "分段在合并期间发生变化，已保留所有原文件")
            }
        }
        progress(0.99, "合并检查通过，正在保存完整文件…")
        try checkCancellation()
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        // The same-volume move publishes the complete file without ever replacing another recording.
        try FileManager.default.moveItem(at: output, to: target)
        progress(1, "完整录制已保存")
        return MergedRecording(url: target, sourceFiles: sources, duration: totalSeconds,
                               videoFrameCount: actualFrames, identities: identities,
                               outputIdentity: try SourceIdentity.read(target))
    }

    private func uniqueOutput(beside first: URL) -> URL {
        let base = first.deletingPathExtension().lastPathComponent + "（完整）"
        let parent = first.deletingLastPathComponent()
        var url = parent.appendingPathComponent(base + ".mp4")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = parent.appendingPathComponent("\(base) \(n).mp4"); n += 1
        }
        return url
    }

    /// Hash compressed frames in order; passthrough must retain every frame byte and frame count.
    private func hashVideo(asset: AVAsset, track: AVAssetTrack, into hash: inout SHA256) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw MergeError(message: "无法读取分段画面") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MergeError(message: "无法读取分段画面") }
        defer { reader.cancelReading() }
        var frames = 0
        while let sample = output.copyNextSampleBuffer() {
            try checkCancellation()
            // AVAssetReader may end the stream with an empty control marker, not a video frame.
            if Self.isEmptyControlMarker(sample) { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else {
                let attachments = CMCopyDictionaryOfAttachments(allocator: nil, target: sample, attachmentMode: kCMAttachmentMode_ShouldPropagate)
                throw MergeError(message: "分段画面数据不完整（采样数 \(CMSampleBufferGetNumSamples(sample))，字节 \(CMSampleBufferGetTotalSampleSize(sample))，附件 \(String(describing: attachments))）")
            }
            let length = CMBlockBufferGetDataLength(block)
            guard length > 0 else { throw MergeError(message: "分段包含空画面") }
            var bytes = Data(count: length)
            let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw MergeError(message: "读取分段画面失败") }
            hash.update(data: bytes)
            frames += CMSampleBufferGetNumSamples(sample)
        }
        guard reader.status == .completed, frames > 0 else {
            throw reader.error ?? MergeError(message: "分段画面未能完整读取")
        }
        return frames
    }

    static func isEmptyControlMarker(_ sample: CMSampleBuffer) -> Bool {
        // Edit boundaries, decoder drain/reset, trim and end-of-stream messages are zero-sample
        // control buffers. Recognize their lack of media, not a version-specific attachment list.
        // A buffer with even one sample, payload byte or image must pass the complete media checks.
        guard CMSampleBufferGetNumSamples(sample) == 0, CMSampleBufferGetTotalSampleSize(sample) == 0,
              CMSampleBufferGetImageBuffer(sample) == nil else { return false }
        if let data = CMSampleBufferGetDataBuffer(sample), CMBlockBufferGetDataLength(data) > 0 { return false }
        return true
    }

    private func validateAudio(asset: AVAsset, track: AVAssetTrack, duration: Double, tolerance: Double) throws {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        guard reader.canAdd(output) else { throw MergeError(message: "无法核对合并声音") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? MergeError(message: "无法读取合并声音") }
        defer { reader.cancelReading() }
        var samples = 0
        var previousEnd: Double?
        while let buffer = output.copyNextSampleBuffer() {
            try checkCancellation()
            if Self.isEmptyControlMarker(buffer) { continue }
            let count = CMSampleBufferGetNumSamples(buffer)
            let start = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buffer))
            guard count > 0, start.isFinite, let block = CMSampleBufferGetDataBuffer(buffer),
                  CMBlockBufferGetDataLength(block) >= count * MemoryLayout<Float>.size else {
                throw MergeError(message: "合并声音数据不完整")
            }
            if let previousEnd, abs(start - previousEnd) > tolerance {
                throw MergeError(message: "合并声音时间轴不连续，已保留原分段")
            }
            previousEnd = start + Double(count) / 48_000
            samples += count
        }
        guard reader.status == .completed, samples > 0,
              abs(Double(samples) / 48_000 - duration) <= tolerance else {
            throw reader.error ?? MergeError(message: "合并声音长度核对失败，已保留原分段")
        }
    }
}
