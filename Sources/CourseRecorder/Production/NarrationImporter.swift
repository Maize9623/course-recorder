import Foundation
import AVFoundation
import CoreGraphics

/// Normalizes external narration into project-owned media with its orientation baked into the pixels.
final class NarrationImporter {
    struct ImportError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    struct PreparedVideo {
        let url: URL
        let temporaryDirectory: URL
        let duration: Double
        let size: CGSize

        func discard() { try? FileManager.default.removeItem(at: temporaryDirectory) }
    }

    private let lock = NSLock()
    private var session: AVAssetExportSession?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let active = session
        lock.unlock()
        active?.cancelExport()
    }

    private func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }

    private func register(_ exporter: AVAssetExportSession?) {
        lock.lock()
        session = exporter
        let stopped = cancelled
        lock.unlock()
        if stopped { exporter?.cancelExport() }
    }

    /// Pure geometry helper: all four source corners remain within the output, including rotated sources.
    static func fittedTransform(naturalSize: CGSize, preferredTransform: CGAffineTransform, canvasSize: CGSize) throws -> CGAffineTransform {
        let values = [naturalSize.width, naturalSize.height, canvasSize.width, canvasSize.height,
                      preferredTransform.a, preferredTransform.b, preferredTransform.c,
                      preferredTransform.d, preferredTransform.tx, preferredTransform.ty]
        guard values.allSatisfy(\.isFinite), naturalSize.width > 0, naturalSize.height > 0,
              canvasSize.width >= 2, canvasSize.height >= 2,
              abs(preferredTransform.a * preferredTransform.d - preferredTransform.b * preferredTransform.c) > 0.000001 else {
            throw ImportError(message: "视频尺寸或旋转信息无效，无法导入")
        }
        let bounds = CGRect(origin: .zero, size: naturalSize).applying(preferredTransform).standardized
        guard bounds.width > 0, bounds.height > 0 else { throw ImportError(message: "视频画幅无效") }
        let scale = min(canvasSize.width / bounds.width, canvasSize.height / bounds.height)
        let x = (canvasSize.width - bounds.width * scale) / 2
        let y = (canvasSize.height - bounds.height * scale) / 2
        return CGAffineTransform(a: preferredTransform.a * scale, b: preferredTransform.b * scale,
                                 c: preferredTransform.c * scale, d: preferredTransform.d * scale,
                                 tx: (preferredTransform.tx - bounds.minX) * scale + x,
                                 ty: (preferredTransform.ty - bounds.minY) * scale + y)
    }

    /// The caller owns the returned temporary directory, and must discard it after committing or cancelling.
    func importVideo(from source: URL, projectFolder: URL, canvasSize: CGSize,
                     progress: @escaping (Double, String) -> Void) async throws -> PreparedVideo {
        try checkCancellation()
        let access = source.startAccessingSecurityScopedResource()
        defer { if access { source.stopAccessingSecurityScopedResource() } }
        guard source.isFileURL, FileManager.default.isReadableFile(atPath: source.path) else {
            throw ImportError(message: "无法读取所选视频，请检查文件是否已下载到本机")
        }
        progress(0, "正在检查视频和声音…")
        let asset = AVURLAsset(url: source)
        let assetDuration = try await asset.load(.duration)
        let seconds = CMTimeGetSeconds(assetDuration)
        guard seconds.isFinite, seconds > 0, try await asset.load(.isPlayable) else {
            throw ImportError(message: "视频无法播放，或时长无效")
        }
        guard let video = try await asset.loadTracks(withMediaType: .video).first else {
            throw ImportError(message: "所选文件没有视频画面")
        }
        guard let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ImportError(message: "所选视频没有音轨；请导入带口播声音的视频")
        }
        let videoRange = try await video.load(.timeRange)
        let audioRange = try await audio.load(.timeRange)
        let duration = CMTimeGetSeconds(videoRange.duration)
        let audioOverlap = CMTimeRangeGetIntersection(videoRange, otherRange: audioRange)
        guard duration.isFinite, duration > 0, videoRange.isValid, audioOverlap.isValid,
              CMTimeGetSeconds(audioOverlap.duration).isFinite, CMTimeGetSeconds(audioOverlap.duration) > 0 else {
            throw ImportError(message: "视频与音轨没有有效的共同时间范围")
        }
        let naturalSize = try await video.load(.naturalSize)
        let preferred = try await video.load(.preferredTransform)
        let nominalFPS = try await video.load(.nominalFrameRate)
        let canvas = CGSize(width: (canvasSize.width / 2).rounded() * 2, height: (canvasSize.height / 2).rounded() * 2)
        let transform = try Self.fittedTransform(naturalSize: naturalSize, preferredTransform: preferred, canvasSize: canvas)
        try checkCancellation()

        let composition = AVMutableComposition()
        guard let picture = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let sound = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw ImportError(message: "无法创建导入视频的音画轨道")
        }
        try picture.insertTimeRange(videoRange, of: video, at: .zero)
        picture.preferredTransform = .identity
        try sound.insertTimeRange(audioOverlap, of: audio, at: CMTimeSubtract(audioOverlap.start, videoRange.start))
        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: picture)
        layer.setTransform(transform, at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: videoRange.duration)
        instruction.backgroundColor = CGColor(gray: 0, alpha: 1)
        instruction.layerInstructions = [layer]
        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = canvas
        let fps = nominalFPS.isFinite && nominalFPS > 0 ? min(60, Double(nominalFPS)) : 30
        videoComposition.frameDuration = CMTime(seconds: 1 / fps, preferredTimescale: 60_000)
        videoComposition.instructions = [instruction]

        let temporary = projectFolder.appendingPathComponent(".narration-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        var returned = false
        defer {
            register(nil)
            if !returned { try? FileManager.default.removeItem(at: temporary) }
        }
        let output = temporary.appendingPathComponent("口播.mp4")
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality),
              exporter.supportedFileTypes.contains(.mp4) else {
            throw ImportError(message: "系统无法将这个视频转换为 MP4")
        }
        exporter.outputURL = output
        exporter.outputFileType = .mp4
        exporter.videoComposition = videoComposition
        exporter.timeRange = CMTimeRange(start: .zero, duration: videoRange.duration)
        exporter.shouldOptimizeForNetworkUse = false
        register(exporter)
        try checkCancellation()
        progress(0.02, "正在适配画幅并保存项目副本，完整保留画面…")
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now(), repeating: 0.25)
        timer.setEventHandler { progress(0.02 + Double(exporter.progress) * 0.93, "正在导入视频…") }
        timer.resume()
        defer { timer.cancel() }
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Serialize starting with cancel(), including cancellation just before export begins.
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
                    default: continuation.resume(throwing: exporter.error ?? ImportError(message: "视频转换未完成"))
                    }
                }
                self.lock.unlock()
            }
        }, onCancel: { self.cancel() })
        try checkCancellation()
        timer.cancel()
        progress(0.96, "正在检查导入结果…")
        let result = AVURLAsset(url: output)
        let resultDuration = CMTimeGetSeconds(try await result.load(.duration))
        guard let resultVideo = try await result.loadTracks(withMediaType: .video).first,
              !(try await result.loadTracks(withMediaType: .audio)).isEmpty,
              resultDuration.isFinite, resultDuration > 0,
              abs(resultDuration - duration) <= max(0.1, 2 / fps) else {
            throw ImportError(message: "导入结果的音画轨道或时长不完整，未替换现有口播")
        }
        let resultTransform = try await resultVideo.load(.preferredTransform)
        let outputSize = try await resultVideo.load(.naturalSize)
        guard resultTransform.isIdentity, abs(outputSize.width - canvas.width) < 1, abs(outputSize.height - canvas.height) < 1 else {
            throw ImportError(message: "视频方向或尺寸没有正确转换，未替换现有口播")
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        try checkCancellation()
        returned = true
        return PreparedVideo(url: output, temporaryDirectory: temporary, duration: resultDuration, size: outputSize)
    }
}
