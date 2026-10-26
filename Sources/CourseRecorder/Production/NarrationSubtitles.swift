import Foundation

/// Retimes recognized words; it never asks a model to rewrite or reconstruct speech.
enum NarrationSubtitles {
    /// Publish captions only after the corresponding movie was committed successfully.
    static func publish(for project: CourseProject, folder: URL, movie: URL) throws {
        let destination = movie.deletingPathExtension().appendingPathExtension("srt")
        if FileManager.default.fileExists(atPath: destination.path) {
            let backup = movie.deletingPathExtension().appendingPathExtension("旧字幕-\(UUID().uuidString).srt")
            try FileManager.default.moveItem(at: destination, to: backup)
        }
        guard let relative = project.subtitleFile else { return }
        let source = try NarrationEditStore.localFile(relative, in: folder)
        let data = try Data(contentsOf: source)
        guard !data.isEmpty else { throw NarrationEditor.Failure(message: "项目字幕为空") }
        try data.write(to: destination, options: .atomic)
    }

    struct Prepared {
        let transcript: NarrationTranscript
        let srt: String
    }

    private struct Token {
        var segment: NarrationSegment
        let retainedIndex: Int
    }

    static func prepare(transcript: NarrationTranscript, cuts: [NarrationCut]) throws -> Prepared {
        let timeline = try NarrationEditor.timeline(duration: transcript.duration, cuts: cuts)
        let precise = transcript.words != nil
        let input = transcript.words ?? transcript.segments
        guard !input.isEmpty else { throw NarrationEditor.Failure(message: "文字稿为空，无法生成字幕") }
        var mapped: [Token] = []
        var previousTime = -Double.infinity
        for word in input {
            let end = word.time + word.duration
            guard word.time.isFinite, word.duration.isFinite, word.time >= 0, word.duration > 0,
                  word.time >= previousTime, end <= transcript.duration + 0.001,
                  !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw NarrationEditor.Failure(message: "文字稿时间无效，请重新识别口播")
            }
            previousTime = word.time
            let boundedEnd = min(end, transcript.duration)
            // A word is either wholly removed or wholly retained. Never keep a clipped syllable.
            if cuts.contains(where: { word.time >= $0.start - 0.001 && boundedEnd <= $0.end + 0.001 }) { continue }
            guard let (index, range) = timeline.retainedRanges.enumerated().first(where: {
                word.time >= $0.element.start - 0.001 && boundedEnd <= $0.element.end + 0.001
            }) else {
                throw NarrationEditor.Failure(message: precise
                    ? "剪辑边界切入了一个词，为避免误删，请取消这条建议后重试"
                    : "这份旧文字稿没有逐词时间，无法安全剪到句子中间，请重新识别")
            }
            let start = max(word.time, range.start)
            let finish = min(boundedEnd, range.end)
            guard finish > start else { throw NarrationEditor.Failure(message: "剪辑边界与文字稿不一致，请重新分析") }
            mapped.append(Token(segment: NarrationSegment(time: range.outputStart + start - range.start,
                duration: finish - start, text: word.text), retainedIndex: index))
        }
        guard !mapped.isEmpty else { throw NarrationEditor.Failure(message: "剪辑会移除全部已识别内容，请保留更多片段") }
        let outputWords = mapped.map(\.segment)
        let entries = precise ? sentences(from: mapped) : outputWords
        // Preserve every accepted token, including intentional repetitions recognized close together.
        let retimed = NarrationTranscript(duration: timeline.duration, segments: entries, words: precise ? outputWords : nil)
        return Prepared(transcript: retimed, srt: try srt(segments: entries, duration: timeline.duration))
    }

    /// SRT entries are short, ordered, non-overlapping and bounded by the edited movie.
    static func srt(segments: [NarrationSegment], duration: Double) throws -> String {
        guard duration.isFinite, duration > 0 else { throw NarrationEditor.Failure(message: "字幕时长无效") }
        let limit = Int64((duration * 1_000).rounded(.down))
        var previousEnd: Int64 = 0
        var output: [String] = []
        for (index, segment) in segments.enumerated() {
            guard segment.time.isFinite, segment.duration.isFinite, segment.time >= 0,
                  segment.duration > 0, segment.time < duration,
                  segment.time + segment.duration <= duration + 0.001 else {
                throw NarrationEditor.Failure(message: "字幕时间无效，请重新识别")
            }
            let start = max(previousEnd, Int64((segment.time * 1_000).rounded()))
            var end = min(limit, Int64(((segment.time + segment.duration) * 1_000).rounded()))
            if index + 1 < segments.count {
                let next = segments[index + 1].time
                guard next.isFinite, next >= segment.time else { throw NarrationEditor.Failure(message: "字幕顺序无效") }
                end = min(end, Int64((next * 1_000).rounded()))
            }
            guard end > start else { throw NarrationEditor.Failure(message: "字幕时间过密，无法安全生成字幕，请重新识别") }
            let text = wrapped(segment.text)
            guard !text.isEmpty else { throw NarrationEditor.Failure(message: "字幕中存在空白内容") }
            output.append("\(output.count + 1)\n\(timestamp(start)) --> \(timestamp(end))\n\(text)\n")
            previousEnd = end
        }
        return output.joined(separator: "\n")
    }

    private static func sentences(from tokens: [Token]) -> [NarrationSegment] {
        var result: [NarrationSegment] = []
        var text = ""
        var start = 0.0, end = 0.0
        var previousRange = -1
        let punctuation = CharacterSet(charactersIn: "，。！？；：,.!?;:\n")
        func flush() {
            guard !text.isEmpty else { return }
            result.append(NarrationSegment(time: start, duration: max(0.001, end - start), text: text))
            text = ""
        }
        for token in tokens {
            let word = token.segment
            let value = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty && word.time > start + 0.001 &&
                (previousRange != token.retainedIndex || word.time - end > 0.65 ||
                 word.time - start > 5 || text.count + value.count > 20) { flush() }
            if text.isEmpty { start = word.time; end = word.time }
            if let left = text.unicodeScalars.last, let right = value.unicodeScalars.first,
               left.isASCII, right.isASCII, CharacterSet.alphanumerics.contains(left), CharacterSet.alphanumerics.contains(right) {
                text += " "
            }
            text += value
            end = max(end, word.time + word.duration)
            previousRange = token.retainedIndex
            if let last = value.unicodeScalars.last, punctuation.contains(last) { flush() }
        }
        flush()
        return result
    }

    /// A long recognizer token is line-wrapped, never assigned invented sub-word timestamps.
    private static func wrapped(_ text: String) -> String {
        let cleaned = text.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        var lines: [String] = [], line = ""
        for character in cleaned {
            line.append(character)
            if line.count >= 20 { lines.append(line); line = "" }
        }
        if !line.isEmpty { lines.append(line) }
        return lines.joined(separator: "\n")
    }

    private static func timestamp(_ milliseconds: Int64) -> String {
        let hours = milliseconds / 3_600_000
        let minutes = milliseconds / 60_000 % 60
        let seconds = milliseconds / 1_000 % 60
        let fraction = milliseconds % 1_000
        return String(format: "%02lld:%02lld:%02lld,%03lld", hours, minutes, seconds, fraction)
    }
}
