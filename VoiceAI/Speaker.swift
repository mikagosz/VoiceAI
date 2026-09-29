import AVFoundation

/// Reads text aloud with a system voice of the speech language — the one picked in the menu,
/// otherwise the best installed. Voices downloaded in System Settings (Accessibility → Spoken Content →
/// System Voice → Manage Voices) show up in the menu without restarting the app.
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()

    var speaking: Bool { synthesizer.isSpeaking }

    /// Installed voices for a language ("pl", "en"), best quality first.
    static func voices(for language: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language == language || $0.language.hasPrefix(language + "-") }
            .sorted { ($0.quality.rawValue, $1.name) > ($1.quality.rawValue, $0.name) }
    }

    /// The picked voice while it is still installed, otherwise the best one.
    func voice(for language: String) -> AVSpeechSynthesisVoice? {
        let voices = Self.voices(for: language)
        let picked = UserDefaults.standard.string(forKey: Setting.voice)
        return voices.first { $0.identifier == picked } ?? voices.first
    }

    func pick(_ identifier: String) {
        UserDefaults.standard.set(identifier, forKey: Setting.voice)
    }

    func speak(_ text: String, language: String) {
        stop()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = voice(for: language) ?? AVSpeechSynthesisVoice(language: language)
        utterance.rate = SpeechTuning.rate
        utterance.pitchMultiplier = SpeechTuning.pitch
        utterance.volume = SpeechTuning.volume
        log.info("Speaking with voice \(utterance.voice?.identifier ?? "nil", privacy: .public), \(text.count) characters")
        synthesizer.speak(utterance)
    }

    /// A short sentence in the picked voice and settings, so a change is heard right away.
    func sample(language: String) {
        speak(language == "pl" ? "Cześć, tak brzmi mój głos." : "Hi, this is how my voice sounds.", language: language)
    }

    func stop() {
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
    }
}
