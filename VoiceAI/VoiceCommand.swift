import Foundation

/// "Inny głos (polecenie)": replies read by a program of the user's choice instead of a system
/// voice — any text-to-speech engine, wrapped in a small script. VoiceAI ships no engine of its own.
///
/// The program is started once and kept running, so a slow engine loads its model only once.
/// For every sentence VoiceAI writes one line, `language<TAB>text`, to its standard input and
/// waits for one line on its standard output: the path to a WAV file (VoiceAI reads it, then
/// deletes it) or `BŁĄD: reason`. Anything else the program has to say goes to standard error.
/// Foundation only, so the headless check covers the protocol.
enum VoiceCommand {
    /// Stored under `Setting.voice` in place of a system voice identifier.
    static let tag = "voiceai.command"
    /// Path to the program.
    static let pathKey = "voiceCommand"

    /// The chosen program while it is still there and runnable.
    static func path(in defaults: UserDefaults = .standard) -> String? {
        guard let path = defaults.string(forKey: pathKey), !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// One request line. A tab or line break inside the text would break the protocol.
    static func request(language: String, text: String) -> String {
        let flat = text.components(separatedBy: .newlines).joined(separator: " ")
            .replacingOccurrences(of: "\t", with: " ")
        return "\(language)\t\(flat)\n"
    }

    enum Reply: Equatable {
        case audio(URL)
        case failure(String)
    }

    static func parse(_ line: String) -> Reply {
        let line = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if line.hasPrefix("BŁĄD:") {
            return .failure(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
        }
        guard line.hasPrefix("/") else { return .failure("not a file path: \(line.prefix(80))") }
        return .audio(URL(fileURLWithPath: line))
    }

    /// The text cut into sentences — the first one plays while the next is being made.
    static func sentences(_ text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { sentence, _, _, _ in
            if let sentence = sentence?.trimmingCharacters(in: .whitespacesAndNewlines), !sentence.isEmpty {
                result.append(sentence)
            }
        }
        let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty && !whole.isEmpty ? [whole] : result
    }
}
