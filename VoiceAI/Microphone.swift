import AppKit
import CoreAudio

/// The microphone dictation records from — the system's default input, the same one
/// `AVAudioEngine.inputNode` takes. Shown in Settings (0.1.42): until then nothing said which
/// microphone was in use. Follows changes made in System Settings or by plugging a device in.
@MainActor
final class Microphone: ObservableObject {
    static let shared = Microphone()

    @Published private(set) var name: String?

    private init() {
        name = Self.defaultInputName()
        var address = Self.defaultInputAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, .main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.name = Self.defaultInputName() }
        }
    }

    private static var defaultInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultInputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    static func defaultInputName() -> String? {
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = defaultInputAddress
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfName: Unmanaged<CFString>?
        size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &nameAddress, 0, nil, &size, &cfName) == noErr,
              let value = cfName?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// System Settings → Sound, where the input is chosen.
    static func openSoundSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension?input") {
            NSWorkspace.shared.open(url)
        }
    }
}
