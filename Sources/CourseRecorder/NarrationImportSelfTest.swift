import Foundation
import AVFoundation
import CoreGraphics
import CoreImage
import Metal

/// Synthetic-only import checks. `run` uses the system media exporter; `runGeometry` is CPU-only.
enum NarrationImportSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Intended entry point: --narration-import-test <output directory>.
    /// A fresh child directory keeps pre-existing files in the requested directory untouched.
    static func run(_ outputDirectory: URL) async throws -> Int {
        var checks = try runGeometry()
        let folder = outputDirectory.appendingPathComponent("narration-import-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let projectFolder = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: false)
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(message: "导入口播自测失败：\(name)") }
            checks += 1
        }
        let landscape = folder.appendingPathComponent("synthetic-landscape.mov")
        let rotated = folder.appendingPathComponent("synthetic-rotated.mov")
        let silent = folder.appendingPathComponent("synthetic-no-audio.mov")
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 0)
        try await makeVideo(at: landscape, transform: .identity, withAudio: true)
        try await makeVideo(at: rotated, transform: rotation, withAudio: true)
        try await makeVideo(at: silent, transform: .identity, withAudio: false)
        let sourceBytes = try [landscape, rotated, silent].map { try Data(contentsOf: $0) }
        let existing = projectFolder.appendingPathComponent(CourseProject.narrationFileName)
        try sourceBytes[0].write(to: existing)
        let canvas = CGSize(width: 320, height: 180)

        // Reject missing audio before preparing a replacement or touching the existing narration.
        do {
            let unexpected = try await NarrationImporter().importVideo(from: silent, projectFolder: projectFolder,
                                                                      canvasSize: canvas, progress: { _, _ in })
            unexpected.discard()
            throw Failure(message: "无音轨视频未被拒绝")
        } catch let failure as NarrationImporter.ImportError {
            try check(failure.message.contains("音轨"), "无音轨错误提示")
        }
        try check(try Data(contentsOf: existing) == sourceBytes[0], "拒绝导入保留已有口播")

        for (source, preferred, label) in [(landscape, CGAffineTransform.identity, "landscape"), (rotated, rotation, "rotated")] {
            let prepared = try await NarrationImporter().importVideo(from: source, projectFolder: projectFolder,
                                                                    canvasSize: canvas, progress: { _, _ in })
            defer { prepared.discard() }
            try check(prepared.url != existing && prepared.temporaryDirectory.deletingLastPathComponent() == projectFolder,
                      "\(label) 只写项目临时副本")
            try check(abs(prepared.duration - 2) < 0.1 && prepared.size == canvas, "\(label) 导入结果时长尺寸")
            let asset = AVURLAsset(url: prepared.url)
            let videoTracks = try await asset.loadTracks(withMediaType: .video)
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            try check(videoTracks.count == 1 && audioTracks.count == 1, "\(label) 音画轨道完整")
            guard let video = videoTracks.first, let audio = audioTracks.first else { throw Failure(message: "导入结果缺少轨道") }
            let size = try await video.load(.naturalSize)
            let transform = try await video.load(.preferredTransform)
            let videoDuration = CMTimeGetSeconds(try await video.load(.timeRange).duration)
            let audioDuration = CMTimeGetSeconds(try await audio.load(.timeRange).duration)
            try check(size == canvas && transform.isIdentity, "\(label) 旋转写入像素、输出无旋转元数据")
            try check(abs(videoDuration - 2) < 0.1 && abs(audioDuration - videoDuration) < 0.1, "\(label) 声音覆盖视频")
            try check(try audioRMS(asset) > 0.05, "\(label) 音轨包含实际声音")
            let frame = try firstFrame(asset)
            let fit = try NarrationImporter.fittedTransform(naturalSize: CGSize(width: 240, height: 160),
                                                            preferredTransform: preferred, canvasSize: canvas)
            try check(try preservesMarkers(frame, transform: fit), "\(label) 四角颜色完整且方向正确")
            try check(try hasExpectedBounds(frame, transform: fit), "\(label) 等比完整画幅及黑边")
            try check(try Data(contentsOf: existing) == sourceBytes[0], "\(label) 准备成功尚未覆盖原口播")
            // Keep inspectable synthetic artifacts without retaining the importer's temporary directory.
            try FileManager.default.copyItem(at: prepared.url, to: folder.appendingPathComponent("imported-\(label).mp4"))
            prepared.discard()
            try check(!FileManager.default.fileExists(atPath: prepared.temporaryDirectory.path), "\(label) 临时目录清理")
        }

        // Cancel after the exporter has written a complete temporary movie, just before it can be returned.
        let cancelled = NarrationImporter()
        do {
            let unexpected = try await cancelled.importVideo(from: rotated, projectFolder: projectFolder, canvasSize: canvas) { value, _ in
                if value >= 0.96 { cancelled.cancel() }
            }
            unexpected.discard()
            throw Failure(message: "结果检查阶段取消未生效")
        } catch is CancellationError { checks += 1 }
        try check(try Data(contentsOf: existing) == sourceBytes[0], "取消不覆盖已有文件")
        let leftovers = try FileManager.default.contentsOfDirectory(at: projectFolder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".narration-import-") }
        try check(leftovers.isEmpty, "取消与失败清理临时目录")
        for (index, source) in [landscape, rotated, silent].enumerated() {
            try check(try Data(contentsOf: source) == sourceBytes[index], "源文件逐字节未变：\(source.lastPathComponent)")
        }
        // Exercise the real final exporter with camera settings that would visibly crop this imported video.
        checks += try await checkFinalExport(folder: folder, rotation: rotation)
        let report = "Narration import: \(checks) checks passed\nSynthetic audio/video only.\n"
        try report.write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("Narration import artifacts: \(folder.path)")
        return checks
    }

    private static func checkFinalExport(folder: URL, rotation: CGAffineTransform) async throws -> Int {
        guard let device = MTLCreateSystemDefaultDevice() else { throw Failure(message: "最终导出测试需要可用的系统图形设备") }
        let context = CIContext(mtlDevice: device, options: [.cacheIntermediates: false])
        let assets = AssetFactory(context: context)
        var settings = AppSettings()
        settings.recording.resolution = .p1080
        settings.recording.fps = 30
        settings.recording.quality = .standard
        settings.camera.fullZoom = 1.5
        settings.camera.fullOffsetX = 0.2
        settings.camera.fullOffsetY = -0.15
        settings.camera.faceTracking = false
        settings.background.mode = .off
        settings.beauty.enabled = false
        settings.overlay.watermarkEnabled = false
        var project = CourseProject(name: "合成导入口播最终出镜")
        project.narrationFile = "imported-rotated.mp4"
        project.narrationDuration = 2
        project.narrationIsImported = true
        project.includeBGM = false
        project.cues = [Cue(time: 0, action: .scene(.camera))]
        let exporter = ProjectExporter(project: project, folder: folder, settings: settings, assets: assets, context: context)
        let output: URL = try await withCheckedThrowingContinuation { continuation in
            exporter.run(progress: { _ in }) { continuation.resume(with: $0) }
        }
        let asset = AVURLAsset(url: output)
        guard let video = try await asset.loadTracks(withMediaType: .video).first,
              let audio = try await asset.loadTracks(withMediaType: .audio).first else {
            throw Failure(message: "最终导出缺少音画轨道")
        }
        let videoDuration = CMTimeGetSeconds(try await video.load(.timeRange).duration)
        let audioDuration = CMTimeGetSeconds(try await audio.load(.timeRange).duration)
        guard abs(videoDuration - 2) < 0.05 && abs(audioDuration - 2) < 0.05 else {
            throw Failure(message: "最终导出音画时长不等于 2 秒")
        }
        let size = try await video.load(.naturalSize)
        guard size == settings.recording.resolution.size else { throw Failure(message: "最终导出尺寸错误") }
        let frame = try firstFrame(asset)
        let transform = try NarrationImporter.fittedTransform(naturalSize: CGSize(width: 240, height: 160),
                                                              preferredTransform: rotation, canvasSize: size)
        guard try preservesMarkers(frame, transform: transform) else { throw Failure(message: "导入口播在最终出镜导出中裁切或旋转错误") }
        guard try hasExpectedBounds(frame, transform: transform) else { throw Failure(message: "最终出镜未保留导入视频的完整边缘与黑边") }
        guard try audioRMS(asset) > 0.05 else { throw Failure(message: "最终导出声音为空") }
        guard settings.camera.fullZoom == 1.5 && settings.camera.fullOffsetX == 0.2 && settings.camera.fullOffsetY == -0.15 else {
            throw Failure(message: "导出改动了原摄像头设置")
        }
        print("Imported narration final export: 2 s, full framing and audio passed")
        return 7
    }

    /// Geometry and project layout semantics require no graphics device or media encode/decode.
    static func runGeometry() throws -> Int {
        var checks = 0
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw Failure(message: "导入口播几何自测失败：\(name)") }
            checks += 1
        }
        let natural = CGSize(width: 240, height: 160)
        let transforms: [CGAffineTransform] = [.identity,
            CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 0),
            CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: 240, ty: 160),
            CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 240),
            CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: 240, ty: 0),
            CGAffineTransform(translationX: -83, y: 41)]
        let corners = [CGPoint.zero, CGPoint(x: 240, y: 0), CGPoint(x: 0, y: 160), CGPoint(x: 240, y: 160)]
        for canvas in [CGSize(width: 320, height: 180), CGSize(width: 180, height: 320)] {
            for preferred in transforms {
                let fit = try NarrationImporter.fittedTransform(naturalSize: natural, preferredTransform: preferred, canvasSize: canvas)
                let result = corners.map { $0.applying(fit) }
                try check(result.allSatisfy { $0.x >= -0.00001 && $0.y >= -0.00001 && $0.x <= canvas.width + 0.00001 && $0.y <= canvas.height + 0.00001 }, "四角不裁切")
                let bounds = CGRect(origin: .zero, size: natural).applying(fit)
                let scaleX = hypot(fit.a, fit.b), scaleY = hypot(fit.c, fit.d)
                try check(abs(scaleX - scaleY) < 0.00001 && (abs(bounds.width - canvas.width) < 0.00001 || abs(bounds.height - canvas.height) < 0.00001), "等比且至少一边填满")
                try check(abs(bounds.midX - canvas.width / 2) < 0.00001 && abs(bounds.midY - canvas.height / 2) < 0.00001, "画面居中")
            }
        }
        do {
            _ = try NarrationImporter.fittedTransform(naturalSize: .zero, preferredTransform: .identity, canvasSize: CGSize(width: 320, height: 180))
            throw Failure(message: "零尺寸未拒绝")
        } catch is NarrationImporter.ImportError { checks += 1 }
        do {
            _ = try NarrationImporter.fittedTransform(naturalSize: natural, preferredTransform: CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0), canvasSize: CGSize(width: 320, height: 180))
            throw Failure(message: "退化矩阵未拒绝")
        } catch is NarrationImporter.ImportError { checks += 1 }
        var settings = AppSettings()
        settings.camera.fullZoom = 1.7
        settings.camera.fullOffsetX = 0.2
        settings.camera.fullOffsetY = -0.1
        var project = CourseProject(name: "合成导入布局")
        project.narrationIsImported = true
        let imported = settings.layoutConfig(for: project)
        try check(imported.camera.fullZoom == 1 && imported.camera.fullOffsetX == 0 && imported.camera.fullOffsetY == 0, "导入全屏不再套用摄像头裁切")
        try check(settings.camera.fullZoom == 1.7 && settings.camera.fullOffsetX == 0.2 && settings.camera.fullOffsetY == -0.1, "原摄像头设置未变")
        try check(settings.layoutConfig(for: nil).camera.fullZoom == 1.7, "实时录制保留摄像头缩放")
        project.narrationIsImported = false
        try check(settings.layoutConfig(for: project).camera.fullZoom == 1.7, "重录项目恢复摄像头缩放")
        project.narrationIsImported = nil
        let encoded = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(CourseProject.self, from: encoded)
        try check(decoded.narrationIsImported == nil && settings.layoutConfig(for: decoded).camera.fullZoom == 1.7, "旧项目兼容")
        return checks
    }

    private static func makeVideo(at url: URL, transform: CGAffineTransform, withAudio: Bool) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 240, AVVideoHeightKey: 160,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000, AVVideoMaxKeyFrameIntervalKey: 30]])
        video.expectsMediaDataInRealTime = false
        video.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 240, kCVPixelBufferHeightKey as String: 160])
        guard writer.canAdd(video) else { throw Failure(message: "系统不支持合成视频写入") }
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        audio.expectsMediaDataInRealTime = false
        if withAudio {
            guard writer.canAdd(audio) else { throw Failure(message: "系统不支持合成声音写入") }
            writer.add(audio)
        }
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "合成视频无法开始") }
        writer.startSession(atSourceTime: .zero)
        let pixels = try markerPixels()
        var frame = 0, sample = 0
        var videoDone = false, audioDone = !withAudio
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !videoDone || !audioDone {
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                writer.cancelWriting()
                throw writer.error ?? Failure(message: "合成媒体写入超时")
            }
            var moved = false
            if !videoDone, video.isReadyForMoreMediaData {
                guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    writer.cancelWriting(); throw writer.error ?? Failure(message: "合成帧写入失败")
                }
                frame += 1
                moved = true
                if frame == 60 { video.markAsFinished(); videoDone = true }
            }
            if !audioDone, audio.isReadyForMoreMediaData {
                let count = min(1024, 96_000 - sample)
                guard audio.append(try toneBuffer(start: sample, count: count)) else {
                    writer.cancelWriting(); throw writer.error ?? Failure(message: "合成声音写入失败")
                }
                sample += count
                moved = true
                if sample == 96_000 { audio.markAsFinished(); audioDone = true }
            }
            if !moved { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        writer.endSession(atSourceTime: CMTime(value: 2, timescale: 1))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "合成媒体收尾失败") }
    }

    private static func markerPixels() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 240, 160, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess, let buffer = result else {
            throw Failure(message: "无法创建合成像素")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message: "无法访问合成像素") }
        let bytes = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        for y in 0..<160 {
            for x in 0..<240 {
                let color = colors[(y < 80 ? 0 : 2) + (x < 120 ? 0 : 1)]
                let border = x < 4 || x >= 236 || y < 4 || y >= 156
                let p = y * stride + x * 4
                bytes[p] = border ? 255 : color.2
                bytes[p + 1] = border ? 255 : color.1
                bytes[p + 2] = border ? 255 : color.0
                bytes[p + 3] = 255
            }
        }
        return buffer
    }

    private static func toneBuffer(start: Int, count: Int) throws -> CMSampleBuffer {
        var values = (0..<count).map { Float(sin(2 * Double.pi * 440 * Double(start + $0) / 48_000) * 0.25) }
        let byteCount = count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                                customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0, blockBufferOut: &block) == noErr,
              let block else { throw Failure(message: "无法创建合成声音块") }
        let copied = values.withUnsafeMutableBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        guard copied == noErr else { throw Failure(message: "合成声音复制失败") }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { throw Failure(message: "合成声音格式失败") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else {
            throw Failure(message: "合成声音采样失败")
        }
        return sample
    }

    private static func firstFrame(_ asset: AVAsset) throws -> CVPixelBuffer {
        guard let track = asset.tracks(withMediaType: .video).first else { throw Failure(message: "缺少画面") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "导入画面无法解码") }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let pixels = CMSampleBufferGetImageBuffer(sample) else {
            throw Failure(message: "导入视频没有可读帧")
        }
        return pixels
    }

    private static func audioRMS(_ asset: AVAsset) throws -> Double {
        guard let track = asset.tracks(withMediaType: .audio).first else { throw Failure(message: "缺少声音") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "导入声音无法解码") }
        defer { reader.cancelReading() }
        var square = 0.0, count = 0
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure(message: "缺少声音数据块") }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            let result = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard result == noErr else { throw Failure(message: "读取声音数据失败") }
            for value in values { square += Double(value) * Double(value) }
            count += values.count
        }
        guard reader.status == .completed, count > 0 else { throw Failure(message: "声音读取不完整") }
        return sqrt(square / Double(count))
    }

    private static func preservesMarkers(_ frame: CVPixelBuffer, transform: CGAffineTransform) throws -> Bool {
        let locations = [CGPoint(x: 48, y: 32), CGPoint(x: 192, y: 32), CGPoint(x: 48, y: 128), CGPoint(x: 192, y: 128)]
        return try withPixels(frame) { bytes, stride, width, height in
            for (index, point) in locations.enumerated() {
                let p = point.applying(transform)
                let x = Int(p.x.rounded()), y = Int(p.y.rounded())
                guard x >= 0, y >= 0, x < width, y < height else { return false }
                let offset = y * stride + x * 4
                let b = Int(bytes[offset]), g = Int(bytes[offset + 1]), r = Int(bytes[offset + 2])
                let matches: Bool
                switch index {
                case 0: matches = r > 160 && g < 100 && b < 100
                case 1: matches = g > 150 && r < 100 && b < 100
                case 2: matches = b > 150 && r < 100 && g < 100
                default: matches = r > 150 && g > 150 && b < 100
                }
                if !matches { return false }
            }
            return true
        }
    }

    private static func hasExpectedBounds(_ frame: CVPixelBuffer, transform: CGAffineTransform) throws -> Bool {
        let expected = CGRect(x: 0, y: 0, width: 240, height: 160).applying(transform)
        return try withPixels(frame) { bytes, stride, width, height in
            var left = width, top = height, right = -1, bottom = -1
            for y in 0..<height {
                for x in 0..<width {
                    let p = y * stride + x * 4
                    if max(bytes[p], max(bytes[p + 1], bytes[p + 2])) > 80 {
                        left = min(left, x); top = min(top, y); right = max(right, x); bottom = max(bottom, y)
                    }
                }
            }
            return abs(Double(left) - expected.minX) <= 3 && abs(Double(top) - expected.minY) <= 3
                && abs(Double(right + 1) - expected.maxX) <= 3 && abs(Double(bottom + 1) - expected.maxY) <= 3
        }
    }

    private static func withPixels(_ frame: CVPixelBuffer, body: (UnsafePointer<UInt8>, Int, Int, Int) -> Bool) throws -> Bool {
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(frame) else { throw Failure(message: "无法读取画面像素") }
        return body(UnsafePointer(base.assumingMemoryBound(to: UInt8.self)), CVPixelBufferGetBytesPerRow(frame), CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame))
    }
}
