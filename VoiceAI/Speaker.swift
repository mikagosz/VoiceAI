import AVFoundation

/// Reads text aloud with a system voice of the speech language — the one picked in the menu,
/// otherwise the best installed. Voices downloaded in System Settings (Accessibility → Spoken Content →
/// System Voice → Manage Voices) show up in the menu without restarting the app.
/// "Inny głos (polecenie)" hands the reading to a program instead (`VoiceCommand`); the system
/// voice steps in whenever that program fails.
final class Speaker {
    private let synthesizer = AVSpeechSynthesizer()
    let external = ExternalVoice()

    var speaking: Bool { synthesizer.isSpeaking || external.speaking }

    init() {
        warmUp()
    }

    /// The program picked as the voice, if it is there to run.
    private var command: String? {
        UserDefaults.standard.string(forKey: Setting.voice) == VoiceCommand.tag ? VoiceCommand.path() : nil
    }

    /// Starts the voice program now, so the first reply doesn't wait for its model.
    func warmUp() {
        if let command { external.warmUp(command) }
    }

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
        warmUp()
    }

    func speak(_ text: String, language: String) {
        stop()
        if let command {
            log.info("Speaking with the voice command, \(text.count) characters")
            external.speak(text, language: language, command: command) { [weak self] rest in
                self?.speakWithSystem(rest, language: language)
            }
        } else {
            speakWithSystem(text, language: language)
        }
    }

    private func speakWithSystem(_ text: String, language: String) {
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
        external.stop()
    }
}
