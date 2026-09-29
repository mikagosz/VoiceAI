import Foundation

/// Claude Code's Stop hook runs `VoiceAI --claude-hook` after every reply. That short-lived
/// process reads the reply's first paragraph from the session transcript, leaves it in a file
/// only this user can read and rings the running app with a distributed notification; the app
/// takes the file and decides whether to speak it. The text itself never rides the
/// notification, which any process in the session can listen to.
/// The hook always exits 0 and prints nothing, so it can never stall or disturb Claude Code.
enum ClaudeHook {
    static let argument = "--claude-hook"
    static let notification = Notification.Name("com.mikagosz.VoiceAI.speak")

    static func run() -> Never {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        if let object = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
           let path = object["transcript_path"] as? String,
           let transcript = try? String(contentsOfFile: path, encoding: .utf8) {
            let text = spokenParagraph(from: lastReply(in: transcript), rest: restOnScreen(for: speechLanguage))
            if !text.isEmpty, (try? handOver(text)) != nil {
                DistributedNotificationCenter.default().postNotificationName(
                    notification, object: nil, userInfo: nil, deliverImmediately: true)
            }
        }
        exit(0)
    }

    /// The text of the last reply: assistant text blocks after the last user entry (a user
    /// entry is either the prompt or a tool result, so tool chatter before it is skipped).
    static func lastReply(in transcript: String) -> String {
        var parts: [String] = []
        for line in transcript.split(separator: "\n").reversed() {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = entry["type"] as? String else { continue }
            if type == "user" { break }
            guard type == "assistant",
                  let message = entry["message"] as? [String: Any],
                  let content = message["content"] as? [[String: Any]] else { continue }
            let texts = content.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }
            parts.insert(contentsOf: texts, at: 0)
        }
        return parts.joined(separator: "\n\n")
    }

    /// The first paragraph with actual words in it, stripped of Markdown so the voice does not
    /// read out asterisks and link addresses. Code blocks are skipped whole.
    static func spokenParagraph(from reply: String, rest: String = restOnScreen) -> String {
        var paragraphs: [String] = []
        var current: [String] = []
        var inCode = false
        for line in reply.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                continue
            }
            if inCode { continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }
                current = []
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { paragraphs.append(current.joined(separator: " ")) }

        guard let first = paragraphs.firstIndex(where: { plain($0).contains(where: \.isLetter) }) else { return "" }
        let sentences = sentences(in: plain(paragraphs[first]))
        var spoken = sentences.prefix(maxSentences).joined(separator: " ")
        if spoken.count > maxCharacters {
            spoken = String(spoken.prefix(maxCharacters))
            if let space = spoken.lastIndex(of: " ") { spoken = String(spoken[..<space]) + "…" }
        }
        let more = sentences.count > maxSentences || spoken.hasSuffix("…") || first < paragraphs.count - 1
        return more ? spoken + " " + rest : spoken
    }

    /// Only the gist is read — a plan or a long explanation stays on the screen.
    static let maxSentences = 2
    static let maxCharacters = 300
    static let restOnScreen = "Resztę masz na ekranie."

    /// Spoken by the voice of the speech language, so it follows that language, not the
    /// interface: Polish for Polish, English for everything else.
    static func restOnScreen(for language: String) -> String {
        language == "pl" ? restOnScreen : "The rest is on screen."
    }

    /// Where the reply waits for the app: next to the word list, readable by this user only.
    static var replyFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VoiceAI/odpowiedz.txt")
    }

    private static func handOver(_ text: String) throws {
        try FileManager.default.createDirectory(at: replyFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: replyFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: replyFile.path)
    }

    /// The waiting reply, taken once — the file is gone afterwards.
    static func takeReply() -> String? {
        defer { try? FileManager.default.removeItem(at: replyFile) }
        return try? String(contentsOf: replyFile, encoding: .utf8)
    }

    /// Read from the word list without the app's store — the store would write a default
    /// file, and this short-lived process should leave nothing but the reply behind.
    private static var speechLanguage: String {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "VoiceAI/slownik.json")
        guard let data = try? Data(contentsOf: file),
              let vocabulary = try? JSONDecoder().decode(Vocabulary.self, from: data) else { return Language.systemSpeech }
        return vocabulary.jezyk
    }

    /// Sentence ends: . ! ? … followed by a space and a capital letter, so "0.1.8" and
    /// "np. tak" stay whole.
    private static func sentences(in text: String) -> [String] {
        var result: [String] = []
        var start = text.startIndex
        let pattern = try! NSRegularExpression(pattern: #"[.!?…]\s+(?=\p{Lu})"#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            result.append(String(text[start..<range.lowerBound]) + String(text[range.lowerBound]))
            start = range.upperBound
        }
        let tail = text[start...].trimmingCharacters(in: .whitespaces)
        if !tail.isEmpty { result.append(tail) }
        return result
    }

    private static func plain(_ markdown: String) -> String {
        var text = markdown
        let rules: [(String, String)] = [
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),          // [text](link) → text
            (#"https?://\S+"#, ""),                      // bare addresses
            (#"(?m)^\s*(#{1,6}|>|[-*+]|\d+\.)\s+"#, ""), // headings, quotes, list markers
            (#"[*_`~]"#, ""),                            // emphasis and code marks
            (#"\s{2,}"#, " "),
        ]
        for (pattern, template) in rules {
            text = text.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
