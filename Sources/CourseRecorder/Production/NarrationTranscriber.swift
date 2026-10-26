import Foundation
import AVFoundation
import Speech

/// Sentence timestamps use the narration video's timeline, including leading silence.
struct NarrationSegment: Codable, Equatable {
    var time: Double
    var duration: Double
    var text: String
}

struct NarrationTranscript: Codable, Equatable {
    var duration: Double
    var segments: [NarrationSegment]
    /// Exact Speech word timestamps; absent only in legacy transcripts.
    var words: [NarrationSegment]? = nil
}

/// One cancellable operation per instance. Audio never leaves the device.
final class NarrationTranscriber: @unchecked Sendable {
    static let cacheFileName = "口播文字稿.json"
    private static let cacheVersion = 2
    private static let sampleRate = 16_000.0
    private let lock = NSLock()
    private var cancelled = false
    private var activeCancellation: (() -> Void)?

    enum Failure: LocalizedError {
        case message(String)
        var errorDescription: String? {
            switch self { case .message(let value): return value }
        }
    }

    private struct SourceIdentity: Codable, Equatable {
        var version: Int
        var fileName: String
        var size: Int
        var modified: Date
        var duration: Double
        var locale: String
    }

    private struct Cache: Codable {
        var source: SourceIdentity
        var transcript: NarrationTranscript
    }

    private struct Word {
        var time: Double
        var duration: Double
        var text: String
    }

    private struct PreparedAudio {
        var url: URL
        var frames: AVAudioFramePosition
        var levels: [Float]
        var duration: Double { Double(frames) / NarrationTranscriber.sampleRate }
    }

    private struct Chunk {
        var coreStart: Double
        var coreEnd: Double
        var start: Double
        var end: Double
        var silent: Bool
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let action = activeCancellation
        activeCancellation = nil
        lock.unlock()
        action?()
    }

    /// Progress callbacks may arrive off the main thread. A valid cache needs no Speech permission.
    func transcribe(url: URL, projectFolder: URL, duration: Double,
                    progress: @escaping (Double, String) -> Void = { _, _ in }) async throws -> NarrationTranscript {
        do {
            return try await transcribeOperation(url: url, projectFolder: projectFolder, duration: duration, progress: progress)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as Failure {
            throw error
        } catch {
            throw Failure.message("本机口播识别失败：\(error.localizedDescription)")
        }
    }

    private func transcribeOperation(url: URL, projectFolder: URL, duration: Double,
                                     progress: @escaping (Double, String) -> Void) async throws -> NarrationTranscript {
        try await withTaskCancellationHandler(operation: {
            try checkCancellation()
            guard duration.isFinite, duration > 0 else { throw Failure.message("口播时长无效，请重新打开项目。") }
            let identity = try Self.sourceIdentity(url: url, duration: duration)
            let cacheURL = projectFolder.appendingPathComponent(Self.cacheFileName)
            if let data = try? Data(contentsOf: cacheURL),
               let cache = try? JSONDecoder().decode(Cache.self, from: data), cache.source == identity,
               cache.transcript.words?.isEmpty == false, Self.valid(cache.transcript, duration: duration) {
                progress(1, "已读取本项目的口播文字稿")
                return cache.transcript
            }
            progress(0, "正在检查设备端中文语音识别")
            try await authorize()
            try checkCancellation()
            guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-Hans")),
                  recognizer.supportsOnDeviceRecognition else {
                throw Failure.message("这台 Mac 尚未准备好设备端中文语音识别。请在系统设置 → 键盘 → 听写中启用中文普通话并完成语言下载，再重试。口播不会上传。")
            }
            // Availability can reflect server reachability; the on-device capability is the required gate.
            let temp = FileManager.default.temporaryDirectory
                .appendingPathComponent("CourseRecorderSpeech-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            defer { try? FileManager.default.removeItem(at: temp) }
            progress(0.01, "正在本机准备音频并查找停顿")
            let prepared = try prepare(url: url, folder: temp, duration: duration) { value in
                progress(0.01 + 0.14 * value, "正在本机准备音频并查找停顿")
            }
            let chunks = Self.chunks(for: prepared)
            var words: [Word] = []
            for (index, chunk) in chunks.enumerated() {
                try checkCancellation()
                progress(0.15 + 0.83 * Double(index) / Double(max(1, chunks.count)),
                         "设备端识别第 \(index + 1)/\(chunks.count) 段")
                if chunk.silent { continue }
                let chunkURL = temp.appendingPathComponent("chunk-\(index).caf")
                try writeChunk(chunk, from: prepared.url, to: chunkURL)
                let result = try await recognize(url: chunkURL, recognizer: recognizer, chunk: chunk, index: index)
                try? FileManager.default.removeItem(at: chunkURL)
                for word in result {
                    // The context overlap protects words at hard cuts; midpoint ownership avoids repeats.
                    let global = Word(time: word.time + chunk.start, duration: word.duration, text: word.text)
                    let middle = global.time + global.duration / 2
                    if middle >= chunk.coreStart && (middle < chunk.coreEnd || index == chunks.count - 1) {
                        words.append(global)
                    }
                }
            }
            try checkCancellation()
            let transcript = Self.sentences(from: words, duration: duration)
            guard !transcript.segments.isEmpty else {
                throw Failure.message("没有识别到清晰的中文口播，请先回放确认口播里有声音，再重试。")
            }
            // Never cache results for a narration replaced during recognition.
            guard try Self.sourceIdentity(url: url, duration: duration) == identity else {
                throw Failure.message("口播文件在识别期间发生了变化，请重新生成时间线。")
            }
            try Self.saveCache(transcript: transcript, url: url, projectFolder: projectFolder)
            progress(1, "口播文字稿已保存到项目")
            return transcript
        }, onCancel: { self.cancel() })
    }

    /// The media must already be fully written. This also lets edited narration reuse recognition.
    static func saveCache(transcript: NarrationTranscript, url: URL, projectFolder: URL) throws {
        guard transcript.words?.isEmpty == false, valid(transcript, duration: transcript.duration) else {
            throw Failure.message("文字稿时间无效，无法保存到项目。")
        }
        let identity = try sourceIdentity(url: url, duration: transcript.duration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(Cache(source: identity, transcript: transcript))
                .write(to: projectFolder.appendingPathComponent(cacheFileName), options: .atomic)
        } catch {
            throw Failure.message("口播文字稿无法保存到项目：\(error.localizedDescription)")
        }
    }

    /// Group the exact retained words on their new media timeline without another recognition pass.
    static func transcript(words: [NarrationSegment], duration: Double) -> NarrationTranscript {
        sentences(from: words.map { Word(time: $0.time, duration: $0.duration, text: $0.text) }, duration: duration)
    }

    private static func sourceIdentity(url: URL, duration: Double) throws -> SourceIdentity {
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0,
                  let modified = values.contentModificationDate else { throw Failure.message("口播文件不存在或尚未保存完成。") }
            return SourceIdentity(version: Self.cacheVersion, fileName: url.lastPathComponent, size: size,
                                  modified: modified, duration: duration, locale: "zh-Hans")
        } catch let error as Failure { throw error }
        catch { throw Failure.message("无法读取口播文件：\(error.localizedDescription)") }
    }

    private static func valid(_ transcript: NarrationTranscript, duration: Double) -> Bool {
        guard transcript.duration == duration, !transcript.segments.isEmpty else { return false }
        var previous = -Double.infinity
        for segment in transcript.segments {
            guard segment.time.isFinite, segment.duration.isFinite, segment.time >= 0,
                  segment.time >= previous, segment.duration > 0, segment.time + segment.duration <= duration + 0.001,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
            previous = segment.time
        }
        if let words = transcript.words {
            guard !words.isEmpty else { return false }
            previous = -Double.infinity
            for word in words {
                guard word.time.isFinite, word.duration.isFinite, word.time >= 0, word.time >= previous,
                      word.duration > 0, word.time + word.duration <= duration + 0.001,
                      !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
                previous = word.time
            }
        }
        return true
    }

    private func checkCancellation() throws {
        lock.lock()
        let stopped = cancelled
        lock.unlock()
        if stopped || Task.isCancelled { throw CancellationError() }
    }

    private func setCancellation(_ action: (() -> Void)?) {
        lock.lock()
        let stopped = cancelled
        activeCancellation = stopped ? nil : action
        lock.unlock()
        if stopped { action?() }
    }

    private func authorize() async throws {
        var status = SFSpeechRecognizer.authorizationStatus()
        if status == .notDetermined {
            guard Bundle.main.object(forInfoDictionaryKey: "NSSpeechRecognitionUsageDescription") != nil else {
                throw Failure.message("请从打包后的“课程录制工具.app”启动语音识别，以便 macOS 显示授权提示。")
            }
            status = try await withCheckedThrowingContinuation { continuation in
                let operation = SpeechCompletion<SFSpeechRecognizerAuthorizationStatus>(continuation)
                setCancellation { operation.finish(.failure(CancellationError())) }
                SFSpeechRecognizer.requestAuthorization { operation.finish(.success($0)) }
            }
            setCancellation(nil)
        }
        switch status {
        case .authorized: return
        case .denied: throw Failure.message("尚未允许语音识别。请到系统设置 → 隐私与安全性 → 语音识别，允许“课程录制工具”，然后重试。")
        case .restricted: throw Failure.message("这台 Mac 的语音识别受到系统限制，暂时无法生成口播文字稿。")
        default: throw Failure.message("语音识别尚未授权，请重试并在系统提示中允许。")
        }
    }

    /// Decode only audio, in bounded buffers. Silence and timestamps remain on the video timeline.
    private func prepare(url: URL, folder: URL, duration: Double, progress: (Double) -> Void) throws -> PreparedAudio {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .audio).first else { throw Failure.message("口播文件里没有音轨。") }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: Self.sampleRate, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        guard reader.canAdd(output) else { throw Failure.message("无法读取口播音轨。") }
        reader.add(output)
        setCancellation { reader.cancelReading() }
        defer { setCancellation(nil); reader.cancelReading() }
        guard reader.startReading() else { throw Failure.message("口播音轨无法解码：\(reader.error?.localizedDescription ?? "未知错误")") }
        let target = folder.appendingPathComponent("narration.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: Self.sampleRate, channels: 1)!
        let file = try AVAudioFile(forWriting: target, settings: format.settings)
        var sampleReader = AudioSampleReader()
        var scratch: [Float] = []
        var frameCount: AVAudioFramePosition = 0
        var levels: [Float] = []
        var energy = 0.0
        var energyCount = 0
        let maxFrames = AVAudioFramePosition(ceil(duration * Self.sampleRate))
        let zero = [Float](repeating: 0, count: 16_000)
        func append(_ values: ArraySlice<Float>) throws {
            guard !values.isEmpty else { return }
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(values.count))!
            buffer.frameLength = AVAudioFrameCount(values.count)
            values.withUnsafeBufferPointer { source in
                buffer.floatChannelData![0].update(from: source.baseAddress!, count: source.count)
            }
            try file.write(from: buffer)
            for value in values {
                energy += Double(value) * Double(value)
                energyCount += 1
                if energyCount == 320 {
                    levels.append(Float(sqrt(energy / 320)))
                    energy = 0
                    energyCount = 0
                }
            }
            frameCount += AVAudioFramePosition(values.count)
        }
        var lastProgress = -1
        while let sample = output.copyNextSampleBuffer() {
            try checkCancellation()
            guard let info = sampleReader.read(sample, into: &scratch), info.channels == 1 else {
                throw Failure.message("读取口播音轨失败，无法得到设备端识别需要的单声道音频。")
            }
            let seconds = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sample))
            guard seconds.isFinite else { throw Failure.message("口播音轨的时间戳无效。") }
            let position = AVAudioFramePosition((seconds * Self.sampleRate).rounded())
            while frameCount < min(position, maxFrames) {
                try checkCancellation()
                try append(zero.prefix(Int(min(16_000, min(position, maxFrames) - frameCount))))
            }
            let skip = Int(max(0, frameCount - position))
            let count = min(info.frames - min(skip, info.frames), Int(max(0, maxFrames - frameCount)))
            if count > 0 { try append(scratch[skip..<(skip + count)]) }
            let percent = Int(100 * Double(frameCount) / max(1, Double(maxFrames)))
            if percent != lastProgress { progress(Double(percent) / 100); lastProgress = percent }
            if frameCount >= maxFrames { break }
        }
        try checkCancellation()
        if reader.status == .failed { throw Failure.message("口播音轨读取中断：\(reader.error?.localizedDescription ?? "未知错误")") }
        if energyCount > 0 { levels.append(Float(sqrt(energy / Double(energyCount)))) }
        guard frameCount > 0 else { throw Failure.message("口播音轨为空。") }
        return PreparedAudio(url: target, frames: frameCount, levels: levels)
    }

    private static func chunks(for audio: PreparedAudio) -> [Chunk] {
        var result: [Chunk] = []
        var start = 0.0
        while start < audio.duration - 0.001 {
            var end = min(start + 56, audio.duration)
            if end < audio.duration {
                // Prefer a quiet run near 53 s; never exceed one minute, including overlap.
                let lower = max(0, Int((start + 42) / 0.02))
                let upper = min(audio.levels.count, Int(end / 0.02))
                var runStart: Int?
                var bestDistance = Double.infinity
                for i in lower...upper {
                    if i < upper && audio.levels[i] < 0.012 {
                        if runStart == nil { runStart = i }
                    } else if let first = runStart {
                        if i - first >= 15 {
                            let middle = Double(first + i) * 0.01
                            let distance = abs(middle - (start + 53))
                            if distance < bestDistance { end = middle; bestDistance = distance }
                        }
                        runStart = nil
                    }
                }
            }
            let contextStart = max(0, start - 0.7)
            let contextEnd = min(audio.duration, end + 0.7)
            let first = max(0, Int(contextStart / 0.02))
            let last = min(audio.levels.count, Int(ceil(contextEnd / 0.02)))
            let silent = first >= last || audio.levels[first..<last].allSatisfy { $0 < 0.0001 }
            result.append(Chunk(coreStart: start, coreEnd: end, start: contextStart, end: contextEnd, silent: silent))
            start = end
        }
        return result
    }

    private func writeChunk(_ chunk: Chunk, from source: URL, to target: URL) throws {
        let input = try AVAudioFile(forReading: source)
        let output = try AVAudioFile(forWriting: target, settings: input.processingFormat.settings)
        input.framePosition = AVAudioFramePosition((chunk.start * Self.sampleRate).rounded())
        let end = min(input.length, AVAudioFramePosition((chunk.end * Self.sampleRate).rounded()))
        let buffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 16_000)!
        while input.framePosition < end {
            try checkCancellation()
            try input.read(into: buffer, frameCount: AVAudioFrameCount(min(16_000, end - input.framePosition)))
            guard buffer.frameLength > 0 else { throw Failure.message("口播分段音频读取不完整，请重试。") }
            try output.write(from: buffer)
        }
    }

    private func recognize(url: URL, recognizer: SFSpeechRecognizer, chunk: Chunk, index: Int) async throws -> [Word] {
        try checkCancellation()
        defer { setCancellation(nil) }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = SpeechCompletion<[Word]>(continuation)
            setCancellation { operation.finish(.failure(CancellationError())) }
            let request = SFSpeechURLRecognitionRequest(url: url)
            request.requiresOnDeviceRecognition = true
            request.shouldReportPartialResults = false
            request.taskHint = .dictation
            request.addsPunctuation = true
            let timeout = DispatchWorkItem {
                operation.finish(.failure(Failure.message("第 \(index + 1) 段设备端中文识别超时。请确认中文听写语言已下载，关闭占用较高的应用后重试。")))
            }
            operation.setTimeout(timeout)
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(90, (chunk.end - chunk.start) * 2), execute: timeout)
            let task = recognizer.recognitionTask(with: request) { result, error in
                if let result = result, result.isFinal {
                    let words = result.bestTranscription.segments.map {
                        Word(time: $0.timestamp, duration: $0.duration, text: $0.substring)
                    }
                    operation.finish(.success(words))
                } else if let error = error {
                    let nsError = error as NSError
                    // Speech reports this when a chunk contains silence or background sound only.
                    if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1110 {
                        operation.finish(.success([]))
                    } else {
                        operation.finish(.failure(Failure.message("第 \(index + 1) 段设备端中文识别失败：\(error.localizedDescription)。请确认系统中文听写语言可用后重试，音频不会上传。")))
                    }
                }
            }
            operation.setTask(task)
        }
    }

    private static func sentences(from input: [Word], duration: Double) -> NarrationTranscript {
        let sorted = input.filter { $0.time.isFinite && $0.duration.isFinite && $0.duration >= 0 }
            .sorted { $0.time < $1.time }
        var segments: [NarrationSegment] = []
        var exactWords: [NarrationSegment] = []
        var text = ""
        var start = 0.0
        var end = 0.0
        var previous: Word?
        let punctuation = CharacterSet(charactersIn: "。！？!?；;\n")
        func flush() {
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let boundedEnd = min(duration, max(start + 0.05, end))
            if !clean.isEmpty && start < boundedEnd {
                segments.append(NarrationSegment(time: start, duration: boundedEnd - start, text: clean))
            }
            text = ""
        }
        for word in sorted {
            let value = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, word.time >= 0, word.time < duration, word.duration > 0 else { continue }
            if let prior = previous, prior.text == word.text,
               abs(prior.time - word.time) < min(0.3, max(0.05, prior.duration * 0.5)),
               min(prior.time + prior.duration, word.time + word.duration) - max(prior.time, word.time)
                   > min(prior.duration, word.duration) * 0.75 { continue }
            exactWords.append(NarrationSegment(time: word.time, duration: min(word.duration, duration - word.time), text: value))
            if !text.isEmpty && (word.time - end > 0.7 || word.time - start > 12 || text.count >= 70) { flush() }
            if text.isEmpty { start = max(0, word.time) }
            if let left = text.unicodeScalars.last, let right = value.unicodeScalars.first,
               left.isASCII, right.isASCII, CharacterSet.alphanumerics.contains(left), CharacterSet.alphanumerics.contains(right) {
                text += " "
            }
            text += value
            end = min(duration, max(end, word.time + word.duration))
            previous = word
            if let last = value.unicodeScalars.last, punctuation.contains(last) { flush() }
        }
        flush()
        return NarrationTranscript(duration: duration, segments: segments, words: exactWords)
    }
}

/// Exactly-once resolution across recognition, timeout, and cancellation callbacks.
private final class SpeechCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    private var task: SFSpeechRecognitionTask?
    private var timeout: DispatchWorkItem?

    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }

    func setTask(_ value: SFSpeechRecognitionTask) {
        lock.lock()
        let finished = continuation == nil
        if !finished { task = value }
        lock.unlock()
        if finished { value.cancel() }
    }

    func setTimeout(_ value: DispatchWorkItem) {
        lock.lock()
        let finished = continuation == nil
        if !finished { timeout = value }
        lock.unlock()
        if finished { value.cancel() }
    }

    func finish(_ result: Result<Value, Error>) {
        lock.lock()
        let saved = continuation
        continuation = nil
        let oldTask = task
        task = nil
        let oldTimeout = timeout
        timeout = nil
        lock.unlock()
        guard let saved = saved else { return }
        oldTimeout?.cancel()
        if case .failure = result { oldTask?.cancel() }
        saved.resume(with: result)
    }
}
