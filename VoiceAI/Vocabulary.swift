import Foundation

/// The user's word list: `slowa` go to Whisper as a hint for spelling, `zamiany` fix what
/// it still gets wrong. Lives in a JSON file the user edits by hand, re-read before every
/// dictation. A broken file never gets overwritten — the last good version stays in use.
struct Vocabulary: Codable, Equatable {
    var jezyk: String
    var slowa: [String]
    var zamiany: [String: String]
    /// Per-app rules by bundle ID. Missing in files from before 0.1.17 — then the built-in
    /// `AppRule.defaults` apply until the first change in Options writes the section.
    var aplikacje: [String: AppRule]?

    var appRules: [String: AppRule] { aplikacje ?? AppRule.defaults }

    static let defaults = Vocabulary(
        jezyk: Language.systemSpeech,
        slowa: ["Claude", "Claude Code", "Anthropic", "Obsidian", "Xcode", "Swift", "GitHub",
                "commit", "push", "repo", "Mac mini", "MacBook", "VoiceAI", "Whisper"],
        zamiany: ["Klaudia": "Claude", "Klaudii": "Claude", "Klaude": "Claude", "Klod": "Claude"],
        aplikacje: AppRule.defaults
    )

    /// Whisper reads the prompt as "text said before this one", so a plain list of words
    /// nudges it toward those spellings.
    var prompt: String { slowa.isEmpty ? "" : " " + slowa.joined(separator: ", ") + "." }

    /// Whole-word, case-insensitive replacements; longer phrases go first so "Klaudia Code"
    /// is not eaten by "Klaudia".
    func apply(to text: String) -> String {
        Self.replace(zamiany, in: text)
    }

    /// The text as it should land in the app with this bundle ID: global replacements, then
    /// the app's own, then its punctuation rules.
    func finish(_ text: String, for app: String?) -> String {
        let replaced = apply(to: text)
        guard let app, let rule = appRules[app] else { return replaced }
        return rule.finish(Self.replace(rule.zamiany, in: replaced))
    }

    static func replace(_ zamiany: [String: String], in text: String) -> String {
        var result = text
        for (from, to) in zamiany.sorted(by: { $0.key.count > $1.key.count }) where !from.isEmpty {
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: from) + "(?![\\p{L}\\p{N}])"
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { continue }
            result = regex.stringByReplacingMatches(in: result, range: NSRange(result.startIndex..., in: result),
                                                    withTemplate: NSRegularExpression.escapedTemplate(for: to))
        }
        return result
    }
}

/// How dictated text lands in one app. Keys stay Polish like the rest of the file.
struct AppRule: Codable, Equatable {
    var nazwa: String
    /// Keep the final full stop. Off for chats and terminals, where it only gets in the way.
    var kropka: Bool = true
    /// Force a capital first letter.
    var wielkaLitera: Bool = false
    /// End with a space, ready for the next sentence.
    var spacja: Bool = false
    var zamiany: [String: String] = [:]

    init(nazwa: String, kropka: Bool = true, wielkaLitera: Bool = false, spacja: Bool = false,
         zamiany: [String: String] = [:]) {
        self.nazwa = nazwa
        self.kropka = kropka
        self.wielkaLitera = wielkaLitera
        self.spacja = spacja
        self.zamiany = zamiany
    }

    /// Every key but the name may be left out when editing the file by hand.
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        nazwa = try values.decode(String.self, forKey: .nazwa)
        kropka = try values.decodeIfPresent(Bool.self, forKey: .kropka) ?? true
        wielkaLitera = try values.decodeIfPresent(Bool.self, forKey: .wielkaLitera) ?? false
        spacja = try values.decodeIfPresent(Bool.self, forKey: .spacja) ?? false
        zamiany = try values.decodeIfPresent([String: String].self, forKey: .zamiany) ?? [:]
    }

    static let defaults: [String: AppRule] = [
        "com.anthropic.claudefordesktop": AppRule(nazwa: "Claude", kropka: false),
        "com.apple.Terminal": AppRule(nazwa: "Terminal", kropka: false),
        "com.googlecode.iterm2": AppRule(nazwa: "iTerm", kropka: false),
        "com.mitchellh.ghostty": AppRule(nazwa: "Ghostty", kropka: false),
        "com.apple.mail": AppRule(nazwa: "Mail", wielkaLitera: true),
    ]

    func finish(_ text: String) -> String {
        var result = text
        // One trailing full stop only — "…", "?" and "!" carry meaning and stay.
        if !kropka, result.hasSuffix("."), !result.hasSuffix(".."), !result.hasSuffix("…") { result.removeLast() }
        if wielkaLitera, let first = result.first, first.isLowercase {
            result = first.uppercased() + result.dropFirst()
        }
        if spacja, let last = result.last, !last.isWhitespace { result += " " }
        return result
    }
}

final class VocabularyStore: ObservableObject {
    let file: URL
    @Published private(set) var current = Vocabulary.defaults
    /// Set when the file exists but cannot be read — shown in the menu.
    private(set) var problem: String?

    init(directory: URL) {
        file = directory.appending(path: "slownik.json")
    }

    func reload() {
        guard let data = try? Data(contentsOf: file) else {
            if !FileManager.default.fileExists(atPath: file.path) { writeDefaults() }
            return
        }
        do {
            current = try JSONDecoder().decode(Vocabulary.self, from: data)
            problem = nil
        } catch {
            problem = String(localized: "Słownik ma błąd — używam poprzedniej wersji.")
        }
    }

    /// Changes the list from the Settings window. Re-reads the file first, so edits made
    /// by hand in the meantime survive; a broken file is left alone.
    func update(_ change: (inout Vocabulary) -> Void) {
        reload()
        guard problem == nil else { return }
        var vocabulary = current
        change(&vocabulary)
        write(vocabulary)
    }

    func updateApps(_ change: (inout [String: AppRule]) -> Void) {
        update { vocabulary in
            var apps = vocabulary.appRules
            change(&apps)
            vocabulary.aplikacje = apps
        }
    }

    private func writeDefaults() {
        write(.defaults)
    }

    /// The change counts only once it is on disk; a failed write shows in the menu instead.
    private func write(_ vocabulary: Vocabulary) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(vocabulary)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
            current = vocabulary
            problem = nil
        } catch {
            problem = String(localized: "Nie udało się zapisać słownika: \(error.localizedDescription)")
        }
    }
}
