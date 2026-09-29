import Foundation

/// The two languages VoiceAI deals with. The interface follows macOS: Polish or English, and
/// English for everyone else (`CFBundleDevelopmentRegion` is `en`). The speech language is a
/// setting of its own — Whisper, the voices and the spoken endings follow it.
enum Language {
    static var interface: String { Bundle.main.preferredLocalizations.first ?? "en" }
    static var interfaceIsPolish: Bool { interface.hasPrefix("pl") }
    static var interfaceLocale: Locale { Locale(identifier: interfaceIsPolish ? "pl_PL" : interface) }

    /// The interface language picked in Settings: "pl", "en", or nil for the Mac's own
    /// language, checked at every launch. macOS reads it from the app's `AppleLanguages`,
    /// so a change applies from the next launch.
    static var chosenInterface: String? {
        get { (UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?["AppleLanguages"] as? [String])?.first }
        set {
            if let newValue { UserDefaults.standard.set([newValue], forKey: "AppleLanguages") }
            else { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        }
    }

    /// Codes Whisper recognises (WhisperKit `Constants.languages`).
    static let whisper: Set<String> = [
        "af", "am", "ar", "as", "az", "ba", "be", "bg", "bn", "bo", "br", "bs", "ca", "cs", "cy", "da", "de",
        "el", "en", "es", "et", "eu", "fa", "fi", "fo", "fr", "gl", "gu", "ha", "haw", "he", "hi", "hr", "ht",
        "hu", "hy", "id", "is", "it", "ja", "jw", "ka", "kk", "km", "kn", "ko", "la", "lb", "ln", "lo", "lt",
        "lv", "mg", "mi", "mk", "ml", "mn", "mr", "ms", "mt", "my", "ne", "nl", "nn", "no", "oc", "pa", "pl",
        "ps", "pt", "ro", "ru", "sa", "sd", "si", "sk", "sl", "sn", "so", "sq", "sr", "su", "sv", "sw", "ta",
        "te", "tg", "th", "tk", "tl", "tr", "tt", "uk", "ur", "uz", "vi", "yi", "yo", "yue", "zh",
    ]

    /// Whisper languages not written in Latin letters — for these any script is fine.
    static let nonLatin: Set<String> = [
        "am", "ar", "as", "ba", "be", "bg", "bn", "bo", "el", "fa", "gu", "he", "hi", "hy", "ja", "ka", "kk",
        "km", "kn", "ko", "lo", "mk", "ml", "mn", "mr", "my", "ne", "pa", "ps", "ru", "sa", "sd", "si", "sr",
        "ta", "te", "tg", "th", "tt", "uk", "ur", "yi", "yue", "zh",
    ]

    /// True when a Latin-script language came back with letters of another alphabet — Polish
    /// speech written out in Cyrillic ("По актуальней можно…", 2026-09-29) despite `pl` forced.
    static func wrongScript(_ text: String, language: String) -> Bool {
        guard !nonLatin.contains(language) else { return false }
        return text.unicodeScalars.contains { $0.properties.isAlphabetic && !isLatin($0) }
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0...0x24F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF, 0xAB30...0xAB6F, 0xFF21...0xFF5A: true
        default: false
        }
    }

    /// The speech language for a new word list: the Mac's first language when Whisper knows it.
    static var systemSpeech: String {
        let code = Locale.preferredLanguages.first.map { Locale(identifier: $0).language.languageCode?.identifier ?? "" } ?? ""
        return whisper.contains(code) ? code : "en"
    }

    /// "polski", "English", "Deutsch" — in the interface language.
    static func name(of code: String) -> String {
        let name = interfaceLocale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased() + name.dropFirst()
    }
}
