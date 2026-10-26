import Foundation
import AVFoundation
import CoreGraphics

/// Synthetic fixtures only. CPU checks are separate from media checks so recording is never disturbed.
enum NarrationEditMediaSelfTest {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    static func runCPU() throws -> Int {
        var checks = 0
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "口播剪辑自测失败：\(name)") }
            checks += 1
        }
        func rejects(_ name: String, _ operation: () throws -> Void) throws {
            do { try operation() }
            catch is NarrationEditor.Failure { checks += 1; return }
            throw Failure(message: "口播剪辑自测未拒绝：\(name)")
        }
        let cuts = [cut(6, 8), cut(1, 3)]
        let map = try NarrationEditor.timeline(duration: 10, cuts: cuts)
        try check(map.duration == 6 && map.retainedRanges.count == 3, "无序剪辑范围保留原顺序")
        try check(map.retainedRanges.map(\.outputStart) == [0, 1, 4], "连续输出时间线")
        try check(map.outputTime(for: 0.5) == 0.5 && map.outputTime(for: 5) == 3 && map.outputTime(for: 9) == 5, "各片段时间映射")
        try check(map.outputTime(for: 2) == nil && map.outputTime(for: 6) == nil, "删除时刻没有输出位置")
        try check(map.outputTime(for: 3) == 1 && map.outputTime(for: 10) == 6, "切口及尾端位置")
        try check(map.outputTime(for: -.infinity) == nil && map.outputTime(for: .nan) == nil, "非法定位")
        try check(try NarrationEditor.timeline(duration: 10, cuts: []).duration == 10, "零建议保持原时间线")
        try check(try NarrationEditor.timeline(duration: 10, cuts: [cut(0, 2), cut(2, 4), cut(8, 10)]).duration == 4, "相邻与首尾剪辑")
        try rejects("无效时长") { _ = try NarrationEditor.timeline(duration: .nan, cuts: []) }
        try rejects("无限时长") { _ = try NarrationEditor.timeline(duration: .infinity, cuts: []) }
        try rejects("范围相交") { _ = try NarrationEditor.timeline(duration: 10, cuts: [cut(1, 3), cut(2, 4)]) }
        try rejects("负数") { _ = try NarrationEditor.timeline(duration: 10, cuts: [cut(-1, 3)]) }
        try rejects("超界") { _ = try NarrationEditor.timeline(duration: 10, cuts: [cut(5, 11)]) }
        try rejects("NaN") { _ = try NarrationEditor.timeline(duration: 10, cuts: [cut(.nan, 3)]) }
        try rejects("倒序") { _ = try NarrationEditor.timeline(duration: 10, cuts: [cut(3, 1)]) }
        try rejects("空范围") { _ = try NarrationEditor.timeline(duration: 10, cuts: [cut(3, 3)]) }
        try rejects("全部移除") { _ = try NarrationEditor.timeline(duration: 10, cuts: [cut(0, 10)]) }
        let words = [NarrationSegment(time: 0.1, duration: 0.4, text: "今天"),
                     NarrationSegment(time: 0.6, duration: 0.3, text: "讲解。"),
                     NarrationSegment(time: 1.2, duration: 0.7, text: "口误重来"),
                     NarrationSegment(time: 3.1, duration: 0.5, text: "正确内容，"),
                     NarrationSegment(time: 4.0, duration: 0.5, text: "保持完整。")]
        let transcript = NarrationTranscript(duration: 6, segments: words, words: words)
        let subtitle = try NarrationSubtitles.prepare(transcript: transcript, cuts: [cut(1, 3)])
        try check(subtitle.transcript.duration == 4 && subtitle.transcript.words?.count == 4, "删词与字幕时长一致")
        try check(subtitle.transcript.words?.map(\.text) == ["今天", "讲解。", "正确内容，", "保持完整。"], "保留文字不改写")
        try check(abs(subtitle.transcript.words![2].time - 1.1) < 0.000001, "逐词时间平移")
        try check(subtitle.srt.contains("00:00:01,100 --> 00:00:01,600") && !subtitle.srt.contains("口误"), "SRT剪后时间与删词")
        try check(try validSRT(subtitle.srt, duration: 4) > 0, "SRT单调无重叠且有内容")
        try check(transcript.words == words && transcript.duration == 6, "原文字稿不变")
        try rejects("切进词") { _ = try NarrationSubtitles.prepare(transcript: transcript, cuts: [cut(1.5, 3)]) }
        let legacy = NarrationTranscript(duration: 6, segments: words)
        try check(try NarrationSubtitles.prepare(transcript: legacy, cuts: [cut(1, 3)]).transcript.words == nil, "旧文字稿完整句安全剪辑")
        try rejects("旧稿半句") { _ = try NarrationSubtitles.prepare(transcript: legacy, cuts: [cut(1.5, 3)]) }
        let repeated = [NarrationSegment(time: 0.1, duration: 0.03, text: "很"),
                        NarrationSegment(time: 0.15, duration: 0.03, text: "很"),
                        NarrationSegment(time: 0.2, duration: 0.3, text: "重要。")]
        let emphasis = try NarrationSubtitles.prepare(transcript: NarrationTranscript(duration: 1, segments: repeated, words: repeated), cuts: [])
        try check(emphasis.transcript.words?.count == 3 && emphasis.srt.contains("很很重要。"), "有意强调不去重")
        let longText = String(repeating: "知识", count: 22)
        let longWords = [NarrationSegment(time: 0, duration: 3, text: longText)]
        let long = try NarrationSubtitles.prepare(transcript: NarrationTranscript(duration: 3, segments: longWords, words: longWords), cuts: [])
        let lines = long.srt.components(separatedBy: "\n").filter { $0.contains("知识") }
        try check(lines.allSatisfy { $0.count <= 20 } && lines.joined() == longText, "长词换行但不伪造子词时间")
        let mixed = [NarrationSegment(time: 0.1, duration: 0.3, text: "Hello"), NarrationSegment(time: 0.5, duration: 0.4, text: "world。")]
        let english = try NarrationSubtitles.prepare(transcript: NarrationTranscript(duration: 1, segments: mixed, words: mixed), cuts: [])
        try check(english.srt.contains("Hello world。"), "英文词间空格")
        let hour = try NarrationSubtitles.srt(segments: [NarrationSegment(time: 3661.125, duration: 0.5, text: "长课")], duration: 3662)
        try check(hour.contains("01:01:01,125 --> 01:01:01,625"), "小时与毫秒格式")
        let sourceSize = CGSize(width: 240, height: 160)
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 0)
        try check(NarrationEditor.preservesDisplayGeometry(sourceSize: sourceSize, sourceTransform: rotation,
            outputSize: CGSize(width: 160, height: 240), outputTransform: .identity), "允许方向正确烘焙进像素")
        try check(NarrationEditor.preservesDisplayGeometry(sourceSize: sourceSize, sourceTransform: rotation,
            outputSize: sourceSize, outputTransform: rotation), "允许完整保留方向元数据")
        try check(!NarrationEditor.preservesDisplayGeometry(sourceSize: sourceSize, sourceTransform: rotation,
            outputSize: sourceSize, outputTransform: .identity), "拒绝旋转丢失")
        try check(!NarrationEditor.preservesDisplayGeometry(sourceSize: sourceSize, sourceTransform: rotation,
            outputSize: CGSize(width: 160, height: 238), outputTransform: .identity), "拒绝裁剪")
        try check(!NarrationEditor.preservesDisplayGeometry(sourceSize: sourceSize, sourceTransform: rotation,
            outputSize: CGSize(width: 80, height: 120), outputTransform: .identity), "拒绝缩小画幅")
        try check(!NarrationEditor.preservesDisplayGeometry(sourceSize: sourceSize, sourceTransform: rotation,
            outputSize: sourceSize, outputTransform: CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: 240)), "拒绝反向旋转元数据")
        return checks
    }

    /// Requires the user to finish trying/recording in the app before it may be run.
    static func runMedia(_ outputDirectory: URL) async throws -> Int {
        var checks = try runCPU()
        let folder = outputDirectory.appendingPathComponent("narration-edit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let project = folder.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
        let existing = project.appendingPathComponent("已有成片.mp4")
        let oldBytes = Data("synthetic previous movie sentinel".utf8)
        try oldBytes.write(to: existing)
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw Failure(message: "口播剪辑媒体自测失败：\(name)") }
            checks += 1
        }
        let cuts = [cut(1, 2), cut(3, 3.5)]
        let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 160, ty: 0)
        for (label, transform) in [("landscape", CGAffineTransform.identity), ("rotated", rotation)] {
            let source = folder.appendingPathComponent("source-\(label).mov")
            try await makeVideo(at: source, transform: transform)
            let sourceBytes = try Data(contentsOf: source)
            let prepared = try await NarrationEditor().edit(source: source, projectFolder: project, duration: 4, cuts: cuts)
            defer { prepared.discard() }
            let asset = AVURLAsset(url: prepared.url)
            guard let video = try await asset.loadTracks(withMediaType: .video).first,
                  let audio = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure(message: "剪后缺少音画轨道") }
            let videoRange = try await video.load(.timeRange)
            let audioRange = try await audio.load(.timeRange)
            let size = try await video.load(.naturalSize)
            let outputTransform = try await video.load(.preferredTransform)
            try check(prepared.duration == 2.5, "\(label) 精确语义时长")
            try check(abs(CMTimeGetSeconds(videoRange.duration) - 2.5) < 0.04 && abs(CMTimeGetSeconds(audioRange.duration) - 2.5) < 0.04, "\(label) 音画时长一致")
            try check(NarrationEditor.preservesDisplayGeometry(sourceSize: CGSize(width: 240, height: 160), sourceTransform: transform,
                outputSize: size, outputTransform: outputTransform), "\(label) 方向与画幅完整")
            try check(try cornerMarkers(asset, sourceTransform: transform, outputTransform: outputTransform), "\(label) 四个非对称角标在正确方向且没有裁边")
            let colors = try videoColors(asset)
            try check(colors.count == 75, "\(label) 75帧无缺帧")
            try check(colors[15] == 0 && colors[45] == 2 && colors[67] == 3, "\(label) 实际删对画面并连续拼接")
            let samples = try audioSamples(asset)
            try check(abs(Double(samples.count) / 48_000 - 2.5) < 0.04, "\(label) 音频采样长度")
            for (start, frequency) in [(0.2, 220.0), (1.2, 660.0), (2.15, 880.0)] {
                let actual = measuredFrequency(samples, start: start, duration: 0.2)
                try check(abs(actual - frequency) < 12, "\(label) 剪后\(start)秒声音对应正确片段")
            }
            try check(try Data(contentsOf: source) == sourceBytes && Data(contentsOf: existing) == oldBytes, "\(label) 源文件与旧成片逐字节不变")
            try FileManager.default.copyItem(at: prepared.url, to: folder.appendingPathComponent("edited-\(label).mp4"))
            prepared.discard()
            try check(!FileManager.default.fileExists(atPath: prepared.temporaryDirectory.path), "\(label) 可清理临时结果")
            for threshold in [0.0, 0.02, 0.96] {
                let cancelled = NarrationEditor()
                if threshold == 0 { cancelled.cancel() }
                do {
                    let unexpected = try await cancelled.edit(source: source, projectFolder: project, duration: 4, cuts: cuts) { value, _ in
                        if threshold > 0 && value >= threshold { cancelled.cancel() }
                    }
                    unexpected.discard()
                    throw Failure(message: "取消未生效：\(threshold)")
                } catch is CancellationError { checks += 1 }
                try check(try Data(contentsOf: source) == sourceBytes && Data(contentsOf: existing) == oldBytes, "\(label) 取消保护原始文件")
                let leftovers = try FileManager.default.contentsOfDirectory(at: project, includingPropertiesForKeys: nil)
                    .filter { $0.lastPathComponent.hasPrefix(".narration-edit-") }
                try check(leftovers.isEmpty, "\(label) 取消后没有未完成临时目录")
            }
        }
        try "Narration edit: \(checks) checks passed\nSynthetic audio/video only.\n".write(to: folder.appendingPathComponent("result.txt"), atomically: true, encoding: .utf8)
        print("Narration edit artifacts: \(folder.path)")
        return checks
    }

    private static func cut(_ start: Double, _ end: Double) -> NarrationCut {
        NarrationCut(start: start, end: end, text: "合成删除片段", reason: "合成测试")
    }

    private static func validSRT(_ srt: String, duration: Double) throws -> Int {
        let pattern = #"(\d+):(\d{2}):(\d{2}),(\d{3}) --> (\d+):(\d{2}):(\d{2}),(\d{3})"#
        let regex = try NSRegularExpression(pattern: pattern)
        let text = srt as NSString
        let matches = regex.matches(in: srt, range: NSRange(location: 0, length: text.length))
        var previous = 0.0
        for match in matches {
            func value(_ offset: Int) -> Double {
                let n = (0..<4).map { Double(text.substring(with: match.range(at: offset + $0)))! }
                return n[0] * 3600 + n[1] * 60 + n[2] + n[3] / 1000
            }
            let start = value(1), end = value(5)
            guard start >= previous, end > start, end <= duration else { throw Failure(message: "SRT时间非法") }
            previous = end
        }
        return matches.count
    }

    private static func makeVideo(at url: URL, transform: CGAffineTransform) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let video = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 240, AVVideoHeightKey: 160,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 1_000_000, AVVideoMaxKeyFrameIntervalKey: 30]])
        video.expectsMediaDataInRealTime = false
        video.transform = transform
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 240, kCVPixelBufferHeightKey as String: 160])
        let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
        audio.expectsMediaDataInRealTime = false
        guard writer.canAdd(video), writer.canAdd(audio) else { throw Failure(message: "无法创建合成音画轨道") }
        writer.add(video)
        writer.add(audio)
        guard writer.startWriting() else { throw writer.error ?? Failure(message: "合成写入失败") }
        writer.startSession(atSourceTime: .zero)
        let buffers = try (0..<4).map { try pixels(color: $0) }
        var frame = 0, sample = 0
        var videoDone = false, audioDone = false
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while !videoDone || !audioDone {
            guard writer.status == .writing, ProcessInfo.processInfo.systemUptime < deadline else {
                writer.cancelWriting()
                throw writer.error ?? Failure(message: "合成媒体写入超时")
            }
            var moved = false
            if !videoDone && video.isReadyForMoreMediaData {
                guard adaptor.append(buffers[frame / 30], withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                    writer.cancelWriting(); throw writer.error ?? Failure(message: "合成帧写入失败")
                }
                frame += 1
                moved = true
                if frame == 120 { video.markAsFinished(); videoDone = true }
            }
            if !audioDone && audio.isReadyForMoreMediaData {
                let count = min(1024, 192_000 - sample)
                guard audio.append(try toneBuffer(start: sample, count: count)) else {
                    writer.cancelWriting(); throw writer.error ?? Failure(message: "合成声音写入失败")
                }
                sample += count
                moved = true
                if sample == 192_000 { audio.markAsFinished(); audioDone = true }
            }
            if !moved { try await Task.sleep(nanoseconds: 1_000_000) }
        }
        writer.endSession(atSourceTime: CMTime(value: 4, timescale: 1))
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in writer.finishWriting { c.resume() } }
        guard writer.status == .completed else { throw writer.error ?? Failure(message: "合成媒体收尾失败") }
    }

    private static func pixels(color: Int) throws -> CVPixelBuffer {
        var value: CVPixelBuffer?
        guard CVPixelBufferCreate(nil, 240, 160, kCVPixelFormatType_32BGRA, nil, &value) == kCVReturnSuccess,
              let buffer = value else { throw Failure(message: "合成像素分配失败") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let rgb: [(UInt8, UInt8, UInt8)] = [(255, 0, 0), (0, 255, 0), (0, 0, 255), (255, 255, 0)]
        for y in 0..<160 { for x in 0..<240 {
            let index = y * stride + x * 4
            let edge = x < 3 || x >= 237 || y < 3 || y >= 157
            bytes[index] = edge ? 255 : rgb[color].2
            bytes[index + 1] = edge ? 255 : rgb[color].1
            bytes[index + 2] = edge ? 255 : rgb[color].0
            bytes[index + 3] = 255
            // Distinct markers make an incorrect rotation/mirror observable even on solid-color frames.
            for (marker, center) in markerCenters.enumerated() where abs(x - Int(center.x)) < 8 && abs(y - Int(center.y)) < 8 {
                bytes[index] = markerColors[marker].2
                bytes[index + 1] = markerColors[marker].1
                bytes[index + 2] = markerColors[marker].0
            }
        } }
        return buffer
    }

    private static func toneBuffer(start: Int, count: Int) throws -> CMSampleBuffer {
        var values = (0..<count).map { offset -> Float in
            let sample = start + offset
            let frequency = Double(220 * (sample / 48_000 + 1))
            return Float(sin(2 * Double.pi * frequency * Double(sample) / 48_000) * 0.25)
        }
        let byteCount = count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: byteCount,
            blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: byteCount, flags: 0,
            blockBufferOut: &block) == noErr, let block else { throw Failure(message: "合成音频内存分配失败") }
        let copied = values.withUnsafeMutableBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: byteCount) }
        guard copied == noErr else { throw Failure(message: "合成音频复制失败") }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
            mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0,
            magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr, let format else { throw Failure(message: "合成声音格式失败") }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: CMTime(value: Int64(start), timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 4
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { throw Failure(message: "合成声音采样失败") }
        return sample
    }

    private static func videoColors(_ asset: AVAsset) throws -> [Int] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .video)[0], outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "剪后画面不可读") }
        defer { reader.cancelReading() }
        var result: [Int] = []
        while let sample = output.copyNextSampleBuffer(), let frame = CMSampleBufferGetImageBuffer(sample) {
            CVPixelBufferLockBaseAddress(frame, .readOnly)
            let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
            let offset = CVPixelBufferGetBytesPerRow(frame) * (CVPixelBufferGetHeight(frame) / 2)
                + (CVPixelBufferGetWidth(frame) / 2) * 4
            let b = bytes[offset], g = bytes[offset + 1], r = bytes[offset + 2]
            let edge = bytes[4]
            CVPixelBufferUnlockBaseAddress(frame, .readOnly)
            guard edge > 170 else { throw Failure(message: "原画面边缘被裁切") }
            if r > 150 && g > 150 && b < 100 { result.append(3) }
            else if r > 150 && g < 100 && b < 100 { result.append(0) }
            else if g > 150 && r < 100 && b < 100 { result.append(1) }
            else if b > 150 && r < 100 && g < 100 { result.append(2) }
            else { throw Failure(message: "合成颜色无法辨认") }
        }
        guard reader.status == .completed else { throw Failure(message: "剪后画面读取不完整") }
        return result
    }

    private static let markerCenters = [CGPoint(x: 24, y: 24), CGPoint(x: 216, y: 24), CGPoint(x: 24, y: 136), CGPoint(x: 216, y: 136)]
    private static let markerColors: [(UInt8, UInt8, UInt8)] = [(0, 255, 255), (255, 0, 255), (255, 255, 255), (255, 128, 0)]

    private static func cornerMarkers(_ asset: AVAsset, sourceTransform: CGAffineTransform,
                                      outputTransform: CGAffineTransform) throws -> Bool {
        let track = asset.tracks(withMediaType: .video)[0]
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        guard reader.startReading(), let sample = output.copyNextSampleBuffer(), let frame = CMSampleBufferGetImageBuffer(sample) else {
            throw Failure(message: "角标画面不可读")
        }
        defer { reader.cancelReading() }
        let sourceBounds = CGRect(x: 0, y: 0, width: 240, height: 160).applying(sourceTransform).standardized
        let outputBounds = CGRect(origin: .zero, size: track.naturalSize).applying(outputTransform).standardized
        CVPixelBufferLockBaseAddress(frame, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(frame, .readOnly) }
        let bytes = CVPixelBufferGetBaseAddress(frame)!.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(frame)
        let width = CVPixelBufferGetWidth(frame), height = CVPixelBufferGetHeight(frame)
        for (index, sourcePoint) in markerCenters.enumerated() {
            let oriented = sourcePoint.applying(sourceTransform)
            let displayed = CGPoint(x: oriented.x - sourceBounds.minX + outputBounds.minX,
                                    y: oriented.y - sourceBounds.minY + outputBounds.minY)
            let point = displayed.applying(outputTransform.inverted())
            let x = Int(point.x.rounded()), y = Int(point.y.rounded())
            guard x >= 0, x < width, y >= 0, y < height else { return false }
            let offset = y * stride + x * 4
            let expected = markerColors[index]
            guard abs(Int(bytes[offset]) - Int(expected.2)) < 45,
                  abs(Int(bytes[offset + 1]) - Int(expected.1)) < 45,
                  abs(Int(bytes[offset + 2]) - Int(expected.0)) < 45 else { return false }
        }
        for point in [CGPoint(x: 1, y: height / 2), CGPoint(x: width - 2, y: height / 2),
                      CGPoint(x: width / 2, y: 1), CGPoint(x: width / 2, y: height - 2)] {
            let offset = Int(point.y) * stride + Int(point.x) * 4
            guard bytes[offset] > 150, bytes[offset + 1] > 150, bytes[offset + 2] > 150 else { return false }
        }
        return true
    }

    private static func audioSamples(_ asset: AVAsset) throws -> [Float] {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: asset.tracks(withMediaType: .audio)[0], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        reader.add(output)
        guard reader.startReading() else { throw Failure(message: "剪后音频不可读") }
        defer { reader.cancelReading() }
        var result: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { throw Failure(message: "剪后缺少声音数据") }
            let length = CMBlockBufferGetDataLength(block)
            var values = [Float](repeating: 0, count: length / 4)
            let status = values.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            guard status == noErr else { throw Failure(message: "读取声音数据失败") }
            result.append(contentsOf: values)
        }
        guard reader.status == .completed else { throw Failure(message: "剪后音频读取不完整") }
        return result
    }

    private static func measuredFrequency(_ samples: [Float], start: Double, duration: Double) -> Double {
        let first = Int(start * 48_000), count = Int(duration * 48_000)
        guard first > 0, first + count <= samples.count else { return 0 }
        var crossings = 0, power = 0.0
        for index in first..<(first + count) {
            if samples[index - 1] <= 0 && samples[index] > 0 { crossings += 1 }
            power += Double(samples[index] * samples[index])
        }
        guard sqrt(power / Double(count)) > 0.08 else { return 0 }
        return Double(crossings) / duration
    }
}
