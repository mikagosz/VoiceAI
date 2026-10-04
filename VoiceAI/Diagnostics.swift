import Foundation

/// One press of the dictation key, as it went: what the microphone gave, what Whisper read, what
/// the word list and the language model made of it, and what was pasted. Without it a wrong
/// sentence could not be traced — Whisper and the language model both change text, and 0.1.66
/// logged only errors, so a good-looking dictation left nothing behind (2026-10-03).
struct DictationRecord: Codable, Equatable {
    enum Outcome: String, Codable {
        /// Released before `minimumSeconds` — a tap, not speech.
        case tooShort
        /// Quieter than the silence threshold — never sent to Whisper.
        case silence
        /// Whisper (or the word list) gave nothing to paste.
        case empty
        case pasted
        /// Pasting did not go through (no Accessibility); the text stayed on the clipboard.
        case notPasted
        /// No text field — the text went to the journal.
        case journal
        case failed
    }

    var date: Date
    /// The default input when the key went down.
    var microphone: String?
    var whisperMode = false
    /// How long the key was held.
    var heldSeconds: Double
    /// How much sound actually came from the microphone — far less than `heldSeconds` means
    /// the engine got no buffers.
    var audioSeconds: Double
    /// Loudness of the whole recording (RMS) and of every half second.
    var rms: Float
    var loudness: [Float]
    /// The app in front at release and why it did or did not count as a text field.
    var app: String?
    var focus: String?
    var outcome: Outcome = .failed
    var whisperSeconds: Double?
    /// Whisper's text, before anything else touched it.
    var whisper: String?
    /// After the word list — only when it changed something.
    var vocabulary: String?
    /// The language model, when tidying or translating was on.
    var model: String?
    var tidied: String?
    var translated: String?
    var modelSeconds: Double?
    /// What was pasted or saved.
    var text: String?
    var error: String?
}

/// The last `limit` dictations in `diagnostyka.json`, next to the journal. Text stays in this
/// file only; the system log gets numbers.
final class Diagnostics {
    static let limit = 50
    static let fileName = "diagnostyka.json"
    let file: URL

    init(directory: URL) {
        file = directory.appending(path: Self.fileName)
    }

    func records() -> [DictationRecord] {
        guard let data = try? Data(contentsOf: file) else { return [] }
        return (try? Self.decoder.decode([DictationRecord].self, from: data)) ?? []
    }

    /// A file that cannot be read starts over — unlike the journal, nothing in it is the user's work.
    func add(_ record: DictationRecord) {
        let kept = (records() + [record]).suffix(Self.limit)
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Self.encoder.encode(Array(kept)).write(to: file, options: .atomic)
        } catch {
            log.error("Diagnostics not saved: \(error.localizedDescription, privacy: .public)")
        }
        let changed = record.model != nil && record.tidied != (record.vocabulary ?? record.whisper)
        log.info("""
            Dictation \(record.outcome.rawValue, privacy: .public): held \(record.heldSeconds, format: .fixed(precision: 2), privacy: .public) s, \
            audio \(record.audioSeconds, format: .fixed(precision: 2), privacy: .public) s, \
            rms \(record.rms, format: .fixed(precision: 4), privacy: .public), \
            whisper \(record.whisperSeconds ?? -1, format: .fixed(precision: 2), privacy: .public) s, \
            model \(record.modelSeconds ?? -1, format: .fixed(precision: 2), privacy: .public) s, \
            changed by model \(changed, privacy: .public)
            """)
    }

    /// RMS of every half second, rounded — enough to see where the sound stopped.
    static func loudness(_ samples: [Float], sampleRate: Double) -> [Float] {
        let step = max(1, Int(sampleRate / 2))
        return stride(from: 0, to: samples.count, by: step).map { start in
            let piece = samples[start..<min(samples.count, start + step)]
            let rms = (piece.reduce(0) { $0 + $1 * $1 } / Float(piece.count)).squareRoot()
            return (rms * 10_000).rounded() / 10_000
        }
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
