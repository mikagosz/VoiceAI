import Foundation

/// A recognised audio or video file: plain text and SubRip subtitles, written next to the
/// source without touching anything that is already there. Foundation only, so the
/// headless check covers it.
struct FileTranscript {
    struct Line: Equatable {
        var start: Double
        var end: Double
        var text: String
    }

    var lines: [Line]

    /// A word with its own timing, as Whisper gives it with `wordTimestamps` (text keeps its
    /// leading space).
    struct Word {
        var text: String
        var start: Double
        var end: Double
    }

    // Subtitle norms: two lines of up to 42 characters, on screen for at most 6 s and at
    // least 0.8 s; a pause or the end of a sentence starts a new subtitle.
    static let maxLine = 42
    static let maxDuration = 6.0
    static let minDuration = 0.8
    static let pause = 0.7

    /// Words grouped into readable subtitles. Measured on a film (2026-09-29): whole segments
    /// were ~0.6 s off and one held 20 words for 7 s. `finish` gets each subtitle's plain text
    /// (the word list's swaps) before it is wrapped.
    static func cues(from words: [Word], finish: (String) -> String = { $0 }) -> [Line] {
        var groups: [[Word]] = []
        var current: [Word] = []
        func joined(_ words: [Word]) -> String {
            clean(words.map(\.text).joined()).replacingOccurrences(of: "  ", with: " ")
        }
        for word in words where !clean(word.text).isEmpty {
            if let first = current.first, let last = current.last,
               word.start - last.end > pause
                || breakPoint(joined(current + [word])) == nil
                || word.end - first.start > maxDuration {
                groups.append(current)
                current = []
            }
            current.append(word)
            let text = joined(current)
            if let end = text.last, ".?!…".contains(end), text.count >= 15 {
                groups.append(current)
                current = []
            }
        }
        if !current.isEmpty { groups.append(current) }

        var lines = groups.compactMap { group -> Line? in
            let text = finish(joined(group))
            guard !text.isEmpty else { return nil }
            return Line(start: group.first!.start, end: group.last!.end, text: wrapped(text))
        }
        // Too short to read: stretch into the gap before the next one.
        for i in lines.indices where lines[i].end - lines[i].start < minDuration {
            let limit = i + 1 < lines.count ? lines[i + 1].start : .infinity
            lines[i].end = min(lines[i].start + minDuration, max(lines[i].end, limit))
        }
        return lines
    }

    /// Longer than one line: broken at the space nearest the middle that keeps both lines
    /// within the limit. A word list swap can lengthen a subtitle past two lines; then it
    /// breaks at the middle anyway rather than drop words.
    static func wrapped(_ text: String) -> String {
        guard text.count > maxLine else { return text }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        guard let best = breakPoint(text) ?? text.indices.filter({ text[$0] == " " })
            .min(by: { text.distance(from: middle, to: $0).magnitude < text.distance(from: middle, to: $1).magnitude })
        else { return text }
        return text[..<best] + "\n" + text[text.index(after: best)...]
    }

    /// Where a text splits into two lines of at most `maxLine`: the space nearest the middle
    /// among those that fit. nil when it does not fit in two lines. The start index for text
    /// that fits on one line.
    static func breakPoint(_ text: String) -> String.Index? {
        if text.count <= maxLine { return text.startIndex }
        let length = text.count
        let fitting = text.indices.filter { index in
            guard text[index] == " " else { return false }
            let left = text.distance(from: text.startIndex, to: index)
            return left <= maxLine && length - left - 1 <= maxLine
        }
        return fitting.min { abs(text.distance(from: text.startIndex, to: $0) - length / 2) < abs(text.distance(from: text.startIndex, to: $1) - length / 2) }
    }

    /// Where to end a piece of a long recording: the start of the quietest `window` among the
    /// last `searchLast` samples, so the cut falls in a pause rather than inside a word.
    static func quietestCut(in samples: [Float], searchLast: Int, window: Int) -> Int {
        let from = max(0, samples.count - searchLast)
        guard window > 0, samples.count - from > window else { return samples.count }
        var best = samples.count, lowest = Float.infinity
        var start = from
        while start + window <= samples.count {
            var energy: Float = 0
            for i in start..<(start + window) { energy += samples[i] * samples[i] }
            if energy < lowest { lowest = energy; best = start }
            start += window / 2
        }
        return max(best, 1)
    }

    /// Whisper's special tokens that can survive in a segment's text.
    private static let tokens = try! NSRegularExpression(pattern: "<\\|[^|]*\\|>")

    static func clean(_ text: String) -> String {
        tokens.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var text: String {
        lines.map { $0.text.replacingOccurrences(of: "\n", with: " ") }.joined(separator: " ")
    }

    var srt: String {
        lines.enumerated().map { index, line in
            "\(index + 1)\n\(Self.timestamp(line.start)) --> \(Self.timestamp(max(line.end, line.start)))\n\(line.text)\n"
        }.joined(separator: "\n")
    }

    /// 00:01:02,345 — SubRip wants a comma before the milliseconds.
    static func timestamp(_ seconds: Double) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d,%03d", total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
    }

    /// `Wywiad` next to `Wywiad.mp4`, or `Wywiad 2`, `Wywiad 3`… — the first name free for every
    /// extension, so the text and its subtitles always come as a pair.
    static func freeName(for source: URL, extensions: [String], fileManager: FileManager = .default) -> URL {
        let folder = source.deletingLastPathComponent()
        let name = source.deletingPathExtension().lastPathComponent
        var candidate = folder.appending(path: name)
        var number = 2
        while extensions.contains(where: { fileManager.fileExists(atPath: candidate.appendingPathExtension($0).path) }) {
            candidate = folder.appending(path: "\(name) \(number)")
            number += 1
        }
        return candidate
    }

    /// Writes both files and returns the text file's address.
    @discardableResult
    func write(nextTo source: URL) throws -> URL {
        let base = Self.freeName(for: source, extensions: ["txt", "srt"])
        let txt = base.appendingPathExtension("txt")
        try (text + "\n").write(to: txt, atomically: true, encoding: .utf8)
        try srt.write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
        return txt
    }
}
