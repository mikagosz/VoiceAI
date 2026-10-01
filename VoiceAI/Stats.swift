import Foundation

/// Words dictated per day and the time that saved against typing them. Kept in
/// UserDefaults as `yyyy-MM-dd → [words, seconds spoken]`.
struct Stats {
    /// An average typist; the saving is typing time minus the time spent speaking.
    static let typingWordsPerMinute = 40.0
    private static let key = "stats"

    struct Day: Equatable {
        var words = 0
        var seconds = 0.0

        /// Minutes saved against typing, never below zero.
        var savedMinutes: Double { max(0, Double(words) / Stats.typingWordsPerMinute - seconds / 60) }

        static func + (a: Day, b: Day) -> Day { Day(words: a.words + b.words, seconds: a.seconds + b.seconds) }
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static let dayKey: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private var stored: [String: [Double]] {
        defaults.dictionary(forKey: Self.key) as? [String: [Double]] ?? [:]
    }

    func record(_ text: String, seconds: Double, at date: Date = Date()) {
        var all = stored
        let key = Self.dayKey.string(from: date)
        let old = Self.pair(all[key])
        all[key] = [old[0] + Double(Self.words(in: text)), old[1] + seconds]
        defaults.set(all, forKey: Self.key)
    }

    func day(_ date: Date = Date()) -> Day {
        let value = Self.pair(stored[Self.dayKey.string(from: date)])
        return Day(words: Int(value[0]), seconds: value[1])
    }

    /// Monday to today, the Polish week.
    func week(_ date: Date = Date()) -> Day {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        guard let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start else { return day(date) }
        var total = Day()
        var current = start
        while current <= date {
            total = total + day(current)
            current = calendar.date(byAdding: .day, value: 1, to: current)!
        }
        return total
    }

    /// `[words, seconds]`; a day edited by hand into something shorter counts as empty
    /// instead of crashing the app on the next dictation.
    static func pair(_ value: [Double]?) -> [Double] {
        guard let value, value.count >= 2 else { return [0, 0] }
        return value
    }

    static func words(in text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).filter { $0.contains(where: \.isLetter) }.count
    }

    /// "1 słowo", "3 słowa", "12 słów", "22 słowa" — or "1 word", "12 words". Worked out here
    /// rather than in the string catalog, so the headless check can test both languages.
    static func wordsLabel(_ count: Int, polish: Bool = Language.interfaceIsPolish) -> String {
        guard polish else { return count == 1 ? "1 word" : "\(count) words" }
        let ones = count % 10, tens = count % 100
        let form = count == 1 ? "słowo" : (2...4).contains(ones) && !(12...14).contains(tens) ? "słowa" : "słów"
        return "\(count) \(form)"
    }

    /// "12 słów · ~3 min zaoszczędzone"; under a minute saved shows no saving.
    static func summary(_ day: Day, polish: Bool = Language.interfaceIsPolish) -> String {
        let minutes = Int(day.savedMinutes.rounded())
        guard minutes >= 1 else { return wordsLabel(day.words, polish: polish) }
        let time = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "\(wordsLabel(day.words, polish: polish)) · ~\(time) " + (polish ? "zaoszczędzone" : "saved")
    }
}
