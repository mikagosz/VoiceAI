import Foundation

/// VoiceAI's own journal: dictations made with no text field to type into land here, and
/// can be copied or exported as Markdown to Obsidian or anywhere else. Stored as JSON in
/// Application Support; a file that cannot be read is never overwritten.
struct JournalEntry: Codable, Identifiable, Equatable {
    var id = UUID()
    var date: Date
    var text: String
}

final class Journal: ObservableObject {
    @Published private(set) var entries: [JournalEntry] = []
    /// Set when the file exists but cannot be read — writing is then refused.
    @Published private(set) var unreadable = false
    let file: URL

    init(directory: URL) {
        file = directory.appending(path: "dziennik.json")
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: file) else {
            unreadable = FileManager.default.fileExists(atPath: file.path)
            return
        }
        do {
            entries = try Self.decoder.decode([JournalEntry].self, from: data)
            unreadable = false
        } catch {
            unreadable = true
        }
    }

    /// Every change starts from the file as it is now, so an edit made outside the app is not
    /// written over with what was in memory, and a file that cannot be read is never replaced.
    func add(_ text: String, at date: Date = Date()) throws {
        load()
        guard !unreadable else { throw JournalError.unreadable }
        entries.append(JournalEntry(date: date, text: text))
        try save()
    }

    func remove(_ ids: Set<JournalEntry.ID>) throws {
        load()
        guard !unreadable else { throw JournalError.unreadable }
        entries.removeAll { ids.contains($0.id) }
        try save()
    }

    private func save() throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Self.encoder.encode(entries).write(to: file, options: .atomic)
    }

    /// Days, newest first; entries inside a day oldest first, like a diary reads.
    var days: [(day: Date, entries: [JournalEntry])] {
        let calendar = Calendar.current
        return Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
            .map { ($0.key, $0.value.sorted { $0.date < $1.date }) }
            .sorted { $0.0 > $1.0 }
    }

    /// Markdown for Obsidian: a heading per day, `- **HH:mm** text` per entry.
    static func markdown(_ entries: [JournalEntry], locale: Locale = Language.interfaceLocale) -> String {
        let calendar = Calendar.current
        let byDay = Dictionary(grouping: entries) { calendar.startOfDay(for: $0.date) }
        return byDay.keys.sorted().map { day in
            let lines = byDay[day]!.sorted { $0.date < $1.date }.map { "- **\(time($0.date, locale: locale))** \($0.text)" }
            return "## \(dayTitle(day, locale: locale))\n\n" + lines.joined(separator: "\n")
        }.joined(separator: "\n\n") + "\n"
    }

    /// Chosen entries as plain text for the clipboard: oldest first, a blank line between them.
    static func plainText(_ entries: [JournalEntry]) -> String {
        entries.sorted { $0.date < $1.date }.map(\.text).joined(separator: "\n\n")
    }

    static func time(_ date: Date, locale: Locale = Language.interfaceLocale) -> String {
        formatter(locale, template: "Hmm").string(from: date)
    }

    /// "wtorek, 29 września 2026" / "Tuesday, September 29, 2026".
    static func dayTitle(_ date: Date, locale: Locale = Language.interfaceLocale) -> String {
        formatter(locale, template: "EEEEdMMMMy").string(from: date)
    }

    private static func formatter(_ locale: Locale, template: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.setLocalizedDateFormatFromTemplate(template)
        return formatter
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

enum JournalError: LocalizedError {
    case unreadable
    var errorDescription: String? { String(localized: "Plik dziennika jest uszkodzony — nie zapisuję, żeby go nie nadpisać.") }
}
