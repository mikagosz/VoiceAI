import AppKit

/// Types text into whatever app has focus: puts it on the clipboard, presses ⌘V, then puts
/// the user's previous clipboard back. Pressing keys needs the Accessibility permission;
/// without it the text simply stays on the clipboard.
enum Paster {
    static var trusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Settings → Privacy → Accessibility.
    static func askForPermission() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Where the last dictation went — the fallback for apps that do not tell what is before
    /// the caret: a dictation into the same app shortly after continues the text.
    private static var lastPaste: (app: String?, at: Date)?
    private static let continuationWindow: TimeInterval = 120

    /// Returns false when the text was only copied, not pasted.
    @discardableResult
    static func paste(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let before: Character?? = characterBeforeCaret()
        let continues: Bool
        if let before {
            continues = before != nil
        } else if let lastPaste {
            continues = lastPaste.app == app && Date().timeIntervalSince(lastPaste.at) < continuationWindow
        } else {
            continues = false
        }
        let text = needsSpace(after: before ?? (continues ? "." : nil), text: text) ? " " + text : text
        lastPaste = (app, Date())

        guard trusted else {
            board.clearContents()
            board.setString(text, forType: .string)
            return false
        }
        let saved = board.pasteboardItems?.map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        } ?? []
        board.clearContents()
        board.setString(text, forType: .string)
        let ours = board.changeCount

        let source = CGEventSource(stateID: .combinedSessionState)
        let v: CGKeyCode = 9
        for keyDown in [true, false] {
            let event = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: keyDown)
            event?.flags = .maskCommand
            event?.post(tap: .cghidEventTap)
        }

        // The target app reads the clipboard asynchronously; give it time before restoring.
        // 0.5 s was a guess — a busy Mac or an Electron app reading later would have pasted
        // the previous clipboard instead of the dictation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            // Something else copied in the meantime — leave it alone.
            guard board.changeCount == ours, !saved.isEmpty else { return }
            board.clearContents()
            board.writeObjects(saved.map { pairs in
                let item = NSPasteboardItem()
                pairs.forEach { item.setData($0.1, forType: $0.0) }
                return item
            })
        }
        return true
    }

    /// Where a dictation would go right now, for the level bar to show.
    struct Destination: Equatable {
        var name: String
        var title: String?
        var icon: NSImage?
    }

    static var destination: Destination {
        if certainlyNoTextField {
            return Destination(name: String(localized: "Dziennik VoiceAI"), title: nil,
                               icon: NSImage(systemSymbolName: "book.closed", accessibilityDescription: nil))
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return Destination(name: "—") }
        return Destination(name: app.localizedName ?? app.bundleIdentifier ?? "?", title: windowTitle(of: app), icon: app.icon)
    }

    /// The focused window's title — the app's name alone does not tell two windows apart.
    private static func windowTitle(of app: NSRunningApplication) -> String? {
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                            kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window else { return nil }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window as! AXUIElement, kAXTitleAttribute as CFString, &title)
        guard let text = title as? String, !text.isEmpty, text != app.localizedName else { return nil }
        return text
    }

    /// True only when it is certain nothing can take typed text: the desktop, a Finder window,
    /// a native control that is not a text field, an app with no windows. ⌘V there does
    /// nothing useful — in Finder it even drops a text clipping file on the desktop.
    /// Apps that say nothing about their focus (Electron: Claude, Obsidian) count as a text
    /// field, so a dictation meant for them never goes astray.
    static var certainlyNoTextField: Bool { focus().noTextField }

    /// The same decision with what it rested on — the app, the focused element's role, the
    /// Accessibility answers — for the diagnostics record. A dictation into Claude went to the
    /// journal on 2026-10-04 and nothing said why.
    static func focus() -> (noTextField: Bool, app: String?, why: String) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return (true, nil, "no frontmost app") }
        let id = app.bundleIdentifier
        let finder = id == "com.apple.finder"
        let element = AXUIElementCreateApplication(app.processIdentifier)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused else {
            if finder { return (true, id, "Finder, no focused element (\(result.rawValue))") }
            var windows: CFTypeRef?
            let listed = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &windows)
            let count = (windows as? [AXUIElement])?.count
            return (listed == .success && count == 0, id,
                    "no focused element (\(result.rawValue)), windows \(count.map(String.init) ?? "?") (\(listed.rawValue))")
        }
        let field = focused as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(field, kAXRoleAttribute as CFString, &role)
        let name = role as? String ?? ""
        if ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(name) { return (false, id, "role \(name)") }
        // The desktop (AXGroup/AXDesktop) answers the selected-text question too (measured
        // 2026-09-29), so in Finder only a real text field — renaming, search — counts.
        if finder { return (true, id, "Finder, role \(name)") }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, &range) == .success {
            return (false, id, "role \(name), has a text selection")
        }
        // Web content may hide an editor inside a generic element — count it as a field.
        if ["AXWebArea", "AXGroup", "AXUnknown", ""].contains(name) { return (false, id, "role \(name), web content") }
        return (true, id, "role \(name), no text selection")
    }

    /// A new sentence glued to the previous one ("…klawisz.Testy") needs a space: add one
    /// unless the caret is at the start, after whitespace or an opening bracket or quote, or
    /// the text itself starts with punctuation.
    static func needsSpace(after previous: Character?, text: String) -> Bool {
        guard let previous, let first = text.first else { return false }
        if previous.isWhitespace || "([{„\"'«".contains(previous) { return false }
        return !".,;:!?…)]}".contains(first)
    }

    /// The character right before the caret in the focused text field, read through
    /// Accessibility. `.some(nil)` means the caret is at the very start; `nil` means the app
    /// does not say (many web and Electron fields).
    private static func characterBeforeCaret() -> Character?? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success, let focused else { return nil }
        let element = focused as! AXUIElement
        var selection: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &selection) == .success,
              let selection, CFGetTypeID(selection) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(selection as! AXValue, .cfRange, &range) else { return nil }
        if range.location == 0 { return .some(nil) }
        var previous = CFRange(location: range.location - 1, length: 1)
        guard let request = AXValueCreate(.cfRange, &previous) else { return nil }
        var value: CFTypeRef?
        guard AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString,
                                                         request, &value) == .success,
              let string = value as? String, let character = string.last else { return nil }
        return .some(character)
    }
}
