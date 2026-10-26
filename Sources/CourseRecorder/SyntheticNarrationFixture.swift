import Foundation
import AVFoundation
import CoreVideo

/// Small synthetic media for lifecycle self-tests; never discovers or reads existing media.
enum SyntheticNarrationFixture {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Writes four seconds of generated color markers and a 440 Hz tone to a fresh test URL.
    static func write(to url: URL) async throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure(message: "合成口播目标已存在，不覆盖文件")
        }
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 240, AVVideoHeightKey: 160,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000, AVVideoMaxKeyFrameIntervalKey: 30]])
        video.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 240, kCVPixelBufferHeightKey as String: 160])
        guard writer.canAdd(video) else { throw Failure(message: "系统不支持合成口播画面写入") }
        writer.add(video)
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(audio) else { throw Failure(message: "系统不支持合成口播声音写入") }
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "合成口播无法开始") }
        defer { if writer.status == .writing { writer.cancelWriting() } }
        writer.startSession(atSourceTime: .zero)
        let pixels = try markerPixels()
        let frameCount = 120, sampleCount = 192_000
        var frame = 0, sample = 0
        var videoDone = false, audioDone = false
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !videoDone || !audioDone {
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                throw writer.error ?? Failure(message: "合成口播写入超时")
            }
            var moved = false
            // Feed both tracks as they become ready so neither input starves the writer.
            if !videoDone, video.isReadyForMoreMediaData {
                guard adaptor.append(pixels, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    throw writer.error ?? Failure(message: "合成口播画面写入失败")
                }
                frame += 1
                moved = true
                if frame == frameCount { video.markAsFinished(); videoDone = true }
            }
            if !audioDone, audio.isReadyForMoreMediaData {
                let count = min(1024, sampleCount - sample)
                guard audio.append(try toneBuffer(start: sample, count: count)) else {
                    throw writer.error ?? Failure(message: "合成口播声音写入失败")
                }
                sample += count
                moved = true
                if sample == sampleCount { audio.markAsFinished(); audioDone = true }
            }
            if !moved { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "合成口播收尾失败") }
    }

    private static func markerPixels() throws -> CVPixelBuffer {
        var result: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 240, 160, kCVPixelFormatType_32BGRA, nil, &result) == kCVReturnSuccess,
              let buffer = result else { throw Failure(message: "无法创建合成口播像素") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure(message: "无法访问合成口播像素") }
        let bytes = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
        let colors: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        for y in 0..<160 {
            for x in 0..<240 {
                let color = colors[(y < 80 ? 0 : 2) + (x < 120 ? 0 : 1)]
                let border = x < 4 || x >= 236 || y < 4 || y >= 156
                let offset = y * stride + x * 4
                bytes[offset] = border ? 255 : color.2
                bytes[offset + 1] = border ? 255 : color.1
                bytes[offset + 2] = border ? 255 : color.0
                bytes[offset + 3] = 255
            }
        }
        return buffer
    }

    private static func toneBuffer(start: Int, count: Int) throws -> CMSampleBuffer {
        var values = [Float](repeating: 0, count: count)
        for index in values.indices {
            let phase = 2.0 * Double.pi * 440.0 * Double(start + index) / 48_000.0
            values[index] = Float(sin(phase) * 0.25)
        }
        let byteCount = count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount, blockAllocator: nil,
                                                customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
                                                blockBufferOut: &block) == noErr,
              let block else { throw Failure(message: "无法创建合成口播声音块") }
        let copied = values.withUnsafeMutableBytes {
            CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                         offsetIntoDestination: 0, dataLength: byteCount)
        }
        guard copied == noErr else { throw Failure(message: "合成口播声音复制失败") }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                              mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                              mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
                                              mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
                                             magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
              let format else { throw Failure(message: "合成口播声音格式失败") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000),
                                       decodeTimeStamp: .invalid)
        var size = MemoryLayout<Float>.size
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr,
              let sample else { throw Failure(message: "合成口播声音采样失败") }
        return sample
    }
}
