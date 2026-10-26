import Foundation
import AVFoundation
import CoreGraphics

/// Builds a new narration movie. The caller alone commits project metadata and owns originals.
final class NarrationEditor: @unchecked Sendable {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct RetainedRange: Equatable {
        let start: Double
        let end: Double
        let outputStart: Double
        var duration: Double { end - start }
    }

    struct Timeline: Equatable {
        let sourceDuration: Double
        let duration: Double
        let retainedRanges: [RetainedRange]

        /// Deleted instants have no destination. The source end maps to the output end.
        func outputTime(for sourceTime: Double) -> Double? {
            guard sourceTime.isFinite, sourceTime >= 0, sourceTime <= sourceDuration else { return nil }
            if sourceTime == sourceDuration { return duration }
            for range in retainedRanges where sourceTime >= range.start && sourceTime < range.end {
                return range.outputStart + sourceTime - range.start
            }
            return nil
        }
    }

    struct PreparedVideo {
        let url: URL
        let temporaryDirectory: URL
        let duration: Double
        func discard() { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private let lock = NSLock()
    private var session: AVAssetExportSession?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let current = session
        lock.unlock()
        current?.cancelExport()
    }

    private func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }

    private func register(_ value: AVAssetExportSession?) {
        lock.lock()
        session = value
        let stopped = cancelled
        lock.unlock()
        if stopped { value?.cancelExport() }
    }

    /// Sorts disjoint cuts, retaining exact source order and forbidding complete deletion.
    static func timeline(duration: Double, cuts: [NarrationCut]) throws -> Timeline {
        guard duration.isFinite, duration > 0 else { throw Failure(message: "口播时长无效，无法剪辑") }
        for cut in cuts {
            guard cut.start.isFinite, cut.end.isFinite, cut.start >= 0, cut.end <= duration,
                  cut.end > cut.start else { throw Failure(message: "剪辑建议的时间范围无效，请重新分析") }
        }
        let sorted = cuts.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var cursor = 0.0, output = 0.0
        var ranges: [RetainedRange] = []
        for cut in sorted {
            guard cut.start >= cursor else { throw Failure(message: "剪辑建议的范围重叠，请重新分析") }
            if cut.start > cursor {
                ranges.append(RetainedRange(start: cursor, end: cut.start, outputStart: output))
                output += cut.start - cursor
            }
            cursor = cut.end
        }
        if cursor < duration {
            ranges.append(RetainedRange(start: cursor, end: duration, outputStart: output))
            output += duration - cursor
        }
        guard output >= 0.1, !ranges.isEmpty else { throw Failure(message: "剪辑后没有足够的口播内容，请保留更多片段") }
        return Timeline(sourceDuration: duration, duration: output, retainedRanges: ranges)
    }

    func edit(source: URL, projectFolder: URL, duration: Double, cuts: [NarrationCut],
              progress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> PreparedVideo {
        try await withTaskCancellationHandler(operation: {
            try await editOperation(source: source, projectFolder: projectFolder, duration: duration,
                                    cuts: cuts, progress: progress)
        }, onCancel: { self.cancel() })
    }

    private func editOperation(source: URL, projectFolder: URL, duration: Double, cuts: [NarrationCut],
                               progress: @escaping (Double, String) -> Void) async throws -> PreparedVideo {
        try checkCancellation()
        let timeline = try Self.timeline(duration: duration, cuts: cuts)
        guard source.isFileURL, FileManager.default.isReadableFile(atPath: source.path) else {
            throw Failure(message: "原口播文件无法读取，请重新打开项目")
        }
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        let identity = try FileManager.default.attributesOfItem(atPath: source.path)
        progress(0, "正在检查原口播，保留原文件…")
        let asset = AVURLAsset(url: source)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(message: "原口播缺少画面或声音，无法剪辑")
        }
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        let originalSize = try await video.load(.naturalSize)
        let originalTransform = try await video.load(.preferredTransform)
        let nominalFPS = try await video.load(.nominalFrameRate)
        let fps = nominalFPS.isFinite && nominalFPS > 0 ? Double(nominalFPS) : 30
        let tolerance = max(0.05, 2 / fps)
        guard originalSize.width > 0, originalSize.height > 0,
              videoRange.isValid, audioRange.isValid,
              CMTimeGetSeconds(videoRange.start) <= tolerance,
              abs(CMTimeGetSeconds(videoRange.end) - duration) <= tolerance,
              CMTimeGetSeconds(audioRange.duration) > 0 else {
            throw Failure(message: "原口播时长或音画轨道与项目不一致，请重新打开项目")
        }
        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure(message: "系统无法创建剪辑轨道")
        }
        picture.preferredTransform = originalTransform
        let audioParameters = AVMutableAudioMixInputParameters(track: sound)
        for (index, range) in timeline.retainedRanges.enumerated() {
            try checkCancellation()
            let sourceRange = CMTimeRange(start: Self.time(range.start), end: Self.time(range.end))
            let picturePart = CMTimeRangeGetIntersection(sourceRange, otherRange: videoRange)
            guard picturePart.isValid, CMTimeGetSeconds(picturePart.duration) > 0,
                  abs(CMTimeGetSeconds(picturePart.duration) - range.duration) <= tolerance else {
                throw Failure(message: "保留片段超出原口播画面范围，未替换原文件")
            }
            let pictureStart = range.outputStart + CMTimeGetSeconds(picturePart.start) - range.start
            try picture.insertTimeRange(picturePart, of: video, at: Self.time(pictureStart))
            let audioPart = CMTimeRangeGetIntersection(sourceRange, otherRange: audioRange)
            if audioPart.isValid, CMTimeGetSeconds(audioPart.duration) > 0 {
                let soundStart = range.outputStart + CMTimeGetSeconds(audioPart.start) - range.start
                try sound.insertTimeRange(audioPart, of: audio, at: Self.time(soundStart))
            }
            // Keep every syllable's timing; tiny ramps suppress discontinuities without overlapping clips.
            let fade = min(0.005, range.duration / 4)
            let outputEnd = range.outputStart + range.duration
            audioParameters.setVolume(1, at: Self.time(range.outputStart))
            if index > 0 || range.start > 0 {
                audioParameters.setVolumeRamp(fromStartVolume: 0, toEndVolume: 1,
                    timeRange: CMTimeRange(start: Self.time(range.outputStart), duration: Self.time(fade)))
            }
            if index < timeline.retainedRanges.count - 1 || range.end < duration {
                audioParameters.setVolumeRamp(fromStartVolume: 1, toEndVolume: 0,
                    timeRange: CMTimeRange(start: Self.time(outputEnd - fade), duration: Self.time(fade)))
            }
        }
        let mix = AVMutableAudioMix()
        mix.inputParameters = [audioParameters]
        let temporary = projectFolder.appendingPathComponent(".narration-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        var returned = false
        defer {
            register(nil)
            if !returned { try? FileManager.default.removeItem(at: temporary) }
        }
        let output = temporary.appendingPathComponent("口播-剪辑.mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              exporter.supportedFileTypes.contains(.mp4) else { throw Failure(message: "系统无法导出口播剪辑") }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.audioMix = mix
        exporter.timeRange = CMTimeRange(start: .zero, duration: Self.time(timeline.duration))
        exporter.shouldOptimizeForNetworkUse = false
        register(exporter)
        try checkCancellation()
        progress(0.02, "正在生成剪辑副本，原口播保持不变…")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { progress(0.02 + Double(exporter.progress) * 0.93, "正在生成剪辑副本…") }
        timer.resume()
        defer { timer.cancel() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.lock.lock()
            if self.cancelled {
                self.lock.unlock()
                continuation.resume(throwing: CancellationError())
                return
            }
            exporter.exportAsynchronously {
                switch exporter.status {
                case .completed: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                default: continuation.resume(throwing: exporter.error ?? Failure(message: "口播剪辑未完成"))
                }
            }
            self.lock.unlock()
        }
        timer.cancel()
        try checkCancellation()
        progress(0.96, "正在检查剪辑后的声音、画面和时长…")
        let result = AVURLAsset(url: output)
        let actualDuration = CMTimeGetSeconds(try await result.load(.duration))
        guard let resultVideo = try await result.loadTracks(withMediaType: .video).first,
              let resultAudio = try await result.loadTracks(withMediaType: .audio).first,
              actualDuration.isFinite, abs(actualDuration - timeline.duration) <= tolerance else {
            throw Failure(message: "剪辑结果音画不完整或时长不符，原口播保持不变")
        }
        let resultSize = try await resultVideo.load(.naturalSize)
        let resultTransform = try await resultVideo.load(.preferredTransform)
        let resultVideoRange = try await resultVideo.load(.timeRange)
        let resultAudioRange = try await resultAudio.load(.timeRange)
        guard Self.preservesDisplayGeometry(sourceSize: originalSize, sourceTransform: originalTransform,
                                             outputSize: resultSize, outputTransform: resultTransform),
              abs(CMTimeGetSeconds(resultVideoRange.duration) - timeline.duration) <= tolerance,
              abs(CMTimeGetSeconds(resultAudioRange.duration) - timeline.duration) <= max(0.15, tolerance) else {
            throw Failure(message: "剪辑结果的画幅、方向或音画时长不符，原口播保持不变")
        }
        let after = try FileManager.default.attributesOfItem(atPath: source.path)
        guard identity[.size] as? NSNumber == after[.size] as? NSNumber,
              identity[.modificationDate] as? Date == after[.modificationDate] as? Date else {
            throw Failure(message: "原口播在剪辑期间发生变化，请重新分析")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try checkCancellation()
        returned = true
        // The semantic timeline, not an MP4 packet's rounded tail, drives subtitles and cues.
        return PreparedVideo(url: output, temporaryDirectory: temporary, duration: timeline.duration)
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60_000) }

    /// AVAssetExportSession may bake rotation/mirroring into pixels and clear the metadata matrix.
    /// Accept only unchanged metadata or this exact normalized geometry, never a crop or rescale.
    static func preservesDisplayGeometry(sourceSize: CGSize, sourceTransform: CGAffineTransform,
                                         outputSize: CGSize, outputTransform: CGAffineTransform) -> Bool {
        let components = [sourceSize.width, sourceSize.height, outputSize.width, outputSize.height,
                          sourceTransform.a, sourceTransform.b, sourceTransform.c, sourceTransform.d,
                          sourceTransform.tx, sourceTransform.ty,
                          outputTransform.a, outputTransform.b, outputTransform.c, outputTransform.d,
                          outputTransform.tx, outputTransform.ty]
        guard components.allSatisfy(\.isFinite), sourceSize.width > 0, sourceSize.height > 0,
              outputSize.width > 0, outputSize.height > 0,
              abs(sourceTransform.a * sourceTransform.d - sourceTransform.b * sourceTransform.c) > 0.000001 else { return false }
        if sourceSize == outputSize && sameTransform(sourceTransform, outputTransform) { return true }
        let bounds = CGRect(origin: .zero, size: sourceSize).applying(sourceTransform).standardized
        return sameTransform(outputTransform, .identity)
            && abs(outputSize.width - bounds.width) < 0.001
            && abs(outputSize.height - bounds.height) < 0.001
    }

    private static func sameTransform(_ lhs: CGAffineTransform, _ rhs: CGAffineTransform) -> Bool {
        zip([lhs.a, lhs.b, lhs.c, lhs.d, lhs.tx, lhs.ty], [rhs.a, rhs.b, rhs.c, rhs.d, rhs.tx, rhs.ty])
            .allSatisfy { abs($0 - $1) < 0.0001 }
    }
}
