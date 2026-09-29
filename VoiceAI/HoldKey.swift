import AppKit

/// Watches the right Option key held on its own. Pressing any other key while it is down
/// (⌥A for "ą" on the Polish keyboard) cancels, so typing never starts a dictation.
/// Global monitors need the Accessibility permission — without it no events arrive.
final class HoldKey {
    private static let rightOption: UInt16 = 61

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
        guard event.keyCode == Self.rightOption else {
            // Another modifier joined in (⌥⇧, ⌘⌥…) — that is a shortcut, not dictation.
            if down { down = false; onCancel() }
            return
        }
        let pressed = event.modifierFlags.contains(.option)
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
