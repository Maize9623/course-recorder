import Foundation
import AVFoundation

/// Synthetic media only. Run after the user has stopped using capture: --recording-merge-test <directory>.
enum RecordingMergeSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func run(_ outputDirectory: URL) async throws -> Int {
        let folder = outputDirectory.appendingPathComponent("recording-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "分段合并自测失败：\(name)") }
            checks += 1
        }
        let sources = (1...3).map { folder.appendingPathComponent("合成录制-\($0).mp4") }
        let frames = [21, 33, 18]
        let frequencies = [220.0, 440.0, 880.0]
        for i in sources.indices {
            try await makeSegment(sources[i], frames: frames[i], color: i, frequency: frequencies[i])
        }
        let originals = try sources.map { try Data(contentsOf: $0) }
        let merger = RecordingSegmentMerger()
        let merged = try await merger.merge(files: sources) { _, _ in }
        try check(merged.sourceFiles == sources.map(\.standardizedFileURL), "源段顺序保持 Recorder 的顺序")
        try check(merged.videoFrameCount == 72, "所有分段的 72 帧无损保留")
        try check(abs(merged.duration - 2.4) < 0.001, "按视频时长合并为 2.4 秒")
        try check(merged.url.deletingLastPathComponent() == folder.standardizedFileURL && !sources.map(\.standardizedFileURL).contains(merged.url), "独立成片保存在原目录")
        try merged.validateSourcesUnchanged(); checks += 1
        for i in sources.indices { try check(try Data(contentsOf: sources[i]) == originals[i], "原段逐字节未变 \(i)") }
        let asset = AVURLAsset(url: merged.url)
        try check(asset.tracks(withMediaType: .video).count == 1, "一个视频轨道")
        try check(asset.tracks(withMediaType: .audio).count == 1, "一个音频轨道")
        let decoded = try readColors(asset)
        try check(decoded.count == 72, "真实解码帧数")
        try check(decoded[0] == 0 && decoded[20] == 0 && decoded[21] == 1 && decoded[53] == 1 && decoded[54] == 2 && decoded[71] == 2,
                  "三段颜色在准确的帧边界按原顺序衔接")
        let samples = try readAudio(asset)
        try check(abs(Double(samples.count) / 48_000 - 2.4) < 0.05, "解码声音覆盖整段视频")
        let starts = [0.0, 0.7, 1.8]
        for i in sources.indices {
            let hz = frequency(samples, start: starts[i] + 0.15, seconds: 0.25)
            try check(abs(hz - frequencies[i]) < 12, "第 \(i + 1) 段声音顺序与画面对齐")
        }
        // The same source set can be merged again without overwriting a complete recording.
        let savedBytes = try Data(contentsOf: merged.url)
        let second = try await RecordingSegmentMerger().merge(files: sources) { _, _ in }
        try check(second.url != merged.url, "同名成片生成新名称")
        try check(try Data(contentsOf: merged.url) == savedBytes, "重合并不覆盖原成片")

        for files in [[sources[0]], [sources[0], sources[0]], [sources[0], folder.appendingPathComponent("不存在.mp4")]] {
            do {
                _ = try await RecordingSegmentMerger().merge(files: files) { _, _ in }
                throw Failure(message: "无效分段集合未被拒绝")
            } catch is RecordingSegmentMerger.MergeError { checks += 1 }
              catch let error as NSError where error.domain == NSCocoaErrorDomain { checks += 1 }
        }
        let link = folder.appendingPathComponent("符号链接.mp4")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sources[1])
        do {
            _ = try await RecordingSegmentMerger().merge(files: [sources[0], link]) { _, _ in }
            throw Failure(message: "符号链接未被拒绝")
        } catch is RecordingSegmentMerger.MergeError { checks += 1 }
        let noAudio = folder.appendingPathComponent("无音轨.mp4")
        try await makeSegment(noAudio, frames: 15, color: 0, frequency: 440, withAudio: false)
        do {
            _ = try await RecordingSegmentMerger().merge(files: [sources[0], noAudio]) { _, _ in }
            throw Failure(message: "无音轨分段未被拒绝")
        } catch is RecordingSegmentMerger.MergeError { checks += 1 }

        let beforeCancel = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
        let preCancelled = RecordingSegmentMerger()
        preCancelled.cancel()
        do {
            _ = try await preCancelled.merge(files: sources) { _, _ in }
            throw Failure(message: "开始前取消无效")
        } catch is CancellationError { checks += 1 }
        let cancelled = RecordingSegmentMerger()
        do {
            _ = try await cancelled.merge(files: sources) { value, _ in if value >= 0.99 { cancelled.cancel() } }
            throw Failure(message: "提交前取消无效")
        } catch is CancellationError { checks += 1 }
        try check(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == beforeCancel, "取消清理临时输出且不发布成片")
        for i in sources.indices { try check(try Data(contentsOf: sources[i]) == originals[i], "失败与取消不修改原段 \(i)") }

        // A source or published output changed after validation must never be eligible for source cleanup.
        let attributes = try FileManager.default.attributesOfItem(atPath: sources[1].path)
        let modified = attributes[.modificationDate] as! Date
        try FileManager.default.setAttributes([.modificationDate: modified.addingTimeInterval(5)], ofItemAtPath: sources[1].path)
        do {
            try merged.validateSourcesUnchanged()
            throw Failure(message: "源文件变化未阻止后续清理")
        } catch is RecordingSegmentMerger.MergeError { checks += 1 }
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: sources[1].path)
        let parked = folder.appendingPathComponent("暂存成片.mp4")
        try FileManager.default.moveItem(at: second.url, to: parked)
        do {
            try second.validateSourcesUnchanged()
            throw Failure(message: "成片消失未阻止后续清理")
        } catch is RecordingSegmentMerger.MergeError { checks += 1 }
          catch let error as NSError where error.domain == NSCocoaErrorDomain { checks += 1 }
        try FileManager.default.moveItem(at: parked, to: second.url)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasPrefix(".recording-merge-") }
        try check(leftovers.isEmpty, "无残留合并临时目录")
        try "Recording merge: \(checks) checks passed\nSynthetic inputs only. Sources remain untouched.\n"
            .write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("Recording merge artifacts: \(folder.path)")
        return checks
    }

    private static func makeSegment(_ url: URL, frames: Int, color: Int, frequency: Double, withAudio: Bool = true) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160, AVVideoHeightKey: 90,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 500_000, AVVideoExpectedSourceFrameRateKey: 30,
                                             AVVideoMaxKeyFrameIntervalKey: 30]])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        guard writer.canAdd(video) else { throw Failure(message: "无法创建测试视频轨") }
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
        audio.expectsMediaDataInRealTime = false
        if withAudio {
            guard writer.canAdd(audio) else { throw Failure(message: "无法创建测试音轨") }
            writer.add(audio)
        }
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "无法开始合成分段") }
        writer.startSession(atSourceTime: .zero)
        var pixels: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pixels) == kCVReturnSuccess,
              let pixels else { throw Failure(message: "无法分配测试画面") }
        CVPixelBufferLockBaseAddress(pixels, [])
        let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<90 { for x in 0..<160 {
            let offset = y * CVPixelBufferGetBytesPerRow(pixels) + x * 4
            bytes[offset] = color == 2 ? 240 : 16
            bytes[offset + 1] = color == 1 ? 240 : 16
            bytes[offset + 2] = color == 0 ? 240 : 16
            bytes[offset + 3] = 255
        } }
        CVPixelBufferUnlockBaseAddress(pixels, [])
        var frame = 0, sample = 0
        var pictureDone = false, audioDone = !withAudio
        let sampleCount = frames * 1600
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !pictureDone || !audioDone {
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                writer.cancelWriting(); throw writer.error ?? Failure(message: "合成分段写入超时")
            }
            var moved = false
            if !pictureDone, video.isReadyForMoreMediaData {
                guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    writer.cancelWriting(); throw writer.error ?? Failure(message: "合成画面写入失败")
                }
                frame += 1; moved = true
                if frame == frames { video.markAsFinished(); pictureDone = true }
            }
            if !audioDone, audio.isReadyForMoreMediaData {
                let count = min(1024, sampleCount - sample)
                guard audio.append(try tone(start: sample, count: count, frequency: frequency)) else {
                    writer.cancelWriting(); throw writer.error ?? Failure(message: "合成声音写入失败")
                }
                sample += count; moved = true
                if sample == sampleCount { audio.markAsFinished(); audioDone = true }
            }
            if !moved { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        writer.endSession(atSourceTime: CMTime(value: Int64(frames), timescale: 30))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in writer.finishWriting { continuation.resume() } }
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "合成分段收尾失败") }
    }

    private static func tone(start: Int, count: Int, frequency: Double) throws -> CMSampleBuffer {
        let values = (0..<count).map { Float(sin(2 * Double.pi * frequency * Double(start + $0) / 48_000) * 0.4) }
        let size = count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
            customBlockSource: nil, offsetToData: 0, dataLength: size, flags: 0, blockBufferOut: &block) == noErr, let block else {
            throw Failure(message: "无法创建测试声音")
        }
        let status = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: size) }
        guard status == noErr else { throw Failure(message: "无法复制测试声音") }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw Failure(message: "测试声音格式错误") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000), decodeTimeStamp: .invalid)
        var sampleSize = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize, sampleBufferOut: &sample) == noErr, let sample else { throw Failure(message: "测试声音采样错误") }
        return sample
    }

    private static func readColors(_ asset: AVAsset) throws -> [Int] {
        guard let video = asset.tracks(withMediaType: .video).first else { throw Failure(message: "合成成片无画面") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "无法解码合成成片") }
        defer { reader.cancelReading() }
        var colors: [Int] = []
        while let sample = output.copyNextSampleBuffer() {
            if RecordingSegmentMerger.isEmptyControlMarker(sample) { continue }
            guard let pixels = CMSampleBufferGetImageBuffer(sample) else { throw Failure(message: "成片帧为空") }
            CVPixelBufferLockBaseAddress(pixels, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(pixels)!.assumingMemoryBound(to: UInt8.self)
            let p = 45 * CVPixelBufferGetBytesPerRow(pixels) + 80 * 4
            colors.append(bytes[p + 2] > bytes[p + 1] && bytes[p + 2] > bytes[p] ? 0 : (bytes[p + 1] > bytes[p] ? 1 : 2))
            CVPixelBufferUnlockBaseAddress(pixels, .readOnly)
        }
        guard reader.status == .completed else { throw reader.error ?? Failure(message: "成片解码不完整") }
        return colors
    }

    private static func readAudio(_ asset: AVAsset) throws -> [Float] {
        guard let audio = asset.tracks(withMediaType: .audio).first else { throw Failure(message: "成片无声音") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "无法读取成片声音") }
        defer { reader.cancelReading() }
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            if RecordingSegmentMerger.isEmptyControlMarker(sample) { continue }
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure(message: "声音数据为空") }
            let size = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: size / 4)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: $0.baseAddress!) }
            guard status == noErr else { throw Failure(message: "声音读取失败") }
            result.append(contentsOf: values)
        }
        guard reader.status == .completed else { throw reader.error ?? Failure(message: "声音读取不完整") }
        return result
    }

    private static func frequency(_ values: [Float], start: Double, seconds: Double) -> Double {
        let first = max(1, Int(start * 48_000)), last = min(values.count, Int((start + seconds) * 48_000))
        guard last > first else { return 0 }
        let crossings = (first..<last).filter { values[$0 - 1] <= 0 && values[$0] > 0 }.count
        return Double(crossings) * 48_000 / Double(last - first)
    }
}
