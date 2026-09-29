import AppKit

/// The key held for dictation, picked in Settings. Only modifier keys: held on their own they
/// type nothing, so holding one never leaves a stray letter in the text field.
enum DictationKey: Int, CaseIterable {
    case rightOption = 61, leftOption = 58, rightCommand = 54, rightControl = 62, rightShift = 60, fn = 63

    static let fallback = DictationKey.rightOption

    /// The saved choice, or right ⌥ — the key VoiceAI always used.
    static var current: DictationKey {
        DictationKey(rawValue: UserDefaults.standard.integer(forKey: Setting.dictationKey)) ?? fallback
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption, .leftOption: .option
        case .rightCommand: .command
        case .rightControl: .control
        case .rightShift: .shift
        case .fn: .function
        }
    }

    /// "prawy ⌥" — used inside sentences like "trzymaj prawy ⌥ i mów".
    var name: String {
        switch self {
        case .rightOption: String(localized: "prawy ⌥")
        case .leftOption: String(localized: "lewy ⌥")
        case .rightCommand: String(localized: "prawy ⌘")
        case .rightControl: String(localized: "prawy ⌃")
        case .rightShift: String(localized: "prawy ⇧")
        case .fn: String(localized: "fn")
        }
    }
}

/// Watches the dictation key held on its own. Pressing any other key while it is down
/// (⌥A for "ą" on the Polish keyboard) cancels, so typing never starts a dictation.
/// Global monitors need the Accessibility permission — without it no events arrive.
/// The key is read from Settings on every event, so a change applies at once.
final class HoldKey {
    var onPress: () -> Void = {}
    var onRelease: () -> Void = {}
    var onCancel: () -> Void = {}

    private var monitors: [Any] = []
    private var down = false

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] in self?.flagsChanged($0) }
        let key: (NSEvent) -> Void = { [weak self] _ in self?.otherKey() }
        monitors = [
            NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags),
            NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: key),
            NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { flags($0); return $0 },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { key($0); return $0 },
        ].compactMap { $0 }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        down = false
    }

    private func flagsChanged(_ event: NSEvent) {
        let dictation = DictationKey.current
        guard event.keyCode == UInt16(dictation.rawValue) else {
            // Another modifier joined in (⌥⇧, ⌘⌥…) — that is a shortcut, not dictation.
            if down { down = false; onCancel() }
            return
        }
        let pressed = event.modifierFlags.contains(dictation.flag)
        if pressed && !down {
            down = true
            onPress()
        } else if !pressed && down {
            down = false
            onRelease()
        }
    }

    private func otherKey() {
        guard down else { return }
        down = false
        onCancel()
    }
}
