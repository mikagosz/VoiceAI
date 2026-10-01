import CryptoKit
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

    /// The program inherits VoiceAI's permissions (Accessibility, microphone) — macOS credits a
    /// child process to the app that started it. The path sits in plain preferences that any
    /// process of this user can write, and the file itself can be rewritten, so the program runs
    /// only when the Keychain holds the user's approval for this very path and these very bytes
    /// (`VoiceCommandApproval`, written when the program is picked in Settings).
    struct Approval: Equatable {
        var path: String
        var fingerprint: String
    }

    enum Status: Equatable {
        /// Nothing picked, or the file is gone.
        case none
        case ready(String)
        /// Picked, but the path or the file is not what was approved — pick it again.
        case changed(String)
    }

    static func status(path: String?, approval: Approval?,
                       fingerprint: (String) -> String? = fingerprint(of:)) -> Status {
        guard let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) else { return .none }
        guard let approval, approval.path == path, let current = fingerprint(path),
              current == approval.fingerprint else { return .changed(path) }
        return .ready(path)
    }

    /// SHA-256 of the file's bytes.
    static func fingerprint(of path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
