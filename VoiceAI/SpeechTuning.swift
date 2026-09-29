import Foundation

/// Speed, pitch and loudness of the voice reading Claude's replies — the three sliders in
/// Settings. Foundation only, so the headless check covers the ranges.
///
/// The values go straight into `AVSpeechUtterance`: `rate` 0…1 with 0.5 the system's normal pace
/// (`AVSpeechUtteranceDefaultSpeechRate`), `pitchMultiplier` 0.5…2, `volume` 0…1. The sliders
/// cover a narrower band around normal, meant to keep the voice sounding like speech. The bands
/// are a first guess, not tuned by ear yet — widen them if the ends turn out too timid.
enum SpeechTuning {
    static let rateKey = "speechRate"
    static let pitchKey = "speechPitch"
    static let volumeKey = "speechVolume"

    static let normalRate = 0.5
    static let normalPitch = 1.0
    static let normalVolume = 1.0

    static let rateRange = 0.3...0.7
    static let pitchRange = 0.75...1.5
    /// Not down to zero — a silent reader looks like a broken one.
    static let volumeRange = 0.1...1.0

    static var rate: Float { Float(stored(rateKey, normalRate, rateRange)) }
    static var pitch: Float { Float(stored(pitchKey, normalPitch, pitchRange)) }
    static var volume: Float { Float(stored(volumeKey, normalVolume, volumeRange)) }

    /// Nothing moved yet — "Przywróć domyślne" has nothing to do.
    static var isNormal: Bool {
        rate == Float(normalRate) && pitch == Float(normalPitch) && volume == Float(normalVolume)
    }

    static func reset() {
        for key in [rateKey, pitchKey, volumeKey] { UserDefaults.standard.removeObject(forKey: key) }
    }

    /// A value from Settings, kept inside its slider's range — a hand-edited preference can't
    /// make the reader crawl or fall silent.
    static func stored(_ key: String, _ normal: Double, _ range: ClosedRange<Double>,
                       in defaults: UserDefaults = .standard) -> Double {
        guard let value = defaults.object(forKey: key) as? Double, value.isFinite else { return normal }
        return min(max(value, range.lowerBound), range.upperBound)
    }

    /// The slider's position as a percentage of the normal value, e.g. "120 %".
    static func percent(_ value: Double, of normal: Double) -> String {
        "\(Int((value / normal * 100).rounded())) %"
    }
}
