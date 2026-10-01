import AppKit
import ServiceManagement

/// Everything VoiceAI keeps on disk, and removing it. macOS tells an app nothing when it is
/// dragged to the Trash, so there are two ways in: "Odinstaluj VoiceAI…" in Settings, and a
/// watch that notices the running app was moved to the Trash and asks then.
/// Everything goes to the Trash, not away for good — a wrong tick can be put back.
enum Uninstaller {
    struct Item {
        var title: String
        var detail: String
        var urls: [URL]
        var removesSettings = false
        var checked = true

        var bytes: Int64 { urls.reduce(0) { $0 + Uninstaller.size(of: $1) } }
    }

    private static let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
    private static let bundleID = Bundle.main.bundleIdentifier ?? "com.mikagosz.VoiceAI"

    /// The app's data folder: models, word list, journal.
    static let data = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "VoiceAI")

    static func items() -> [Item] {
        let models = data.appending(path: "Modele")
        return [
            Item(title: String(localized: "Modele"), detail: String(localized: "rozpoznawanie mowy i modele językowe"), urls: [models]),
            Item(title: String(localized: "Słownik i reguły aplikacji"), detail: "slownik.json", urls: [data.appending(path: "slownik.json")]),
            Item(title: String(localized: "Dziennik"), detail: "dziennik.json", urls: [data.appending(path: "dziennik.json")]),
            Item(title: String(localized: "Ustawienia, licznik słów i pamięć podręczna"), detail: bundleID,
                 urls: [library.appending(path: "Caches/\(bundleID)"), library.appending(path: "HTTPStorages/\(bundleID)"),
                        ClaudeHook.replyFile,
                        // ErrorUpdate's report store (reporting is off, the folder is still created).
                        library.appending(path: "Application Support/\(bundleID)")],
                 removesSettings: true),
        ].filter { item in item.removesSettings || item.urls.contains { FileManager.default.fileExists(atPath: $0.path) } }
    }

    /// A file's own size, or everything inside a folder. The enumerator exists for a plain file
    /// too but lists nothing — the journal and the word list showed "zero KB" (0.1.28).
    static func size(of url: URL) -> Int64 {
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder) else { return 0 }
        guard isFolder.boolValue,
              let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey]) else {
            return Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        var total: Int64 = 0
        for case let file as URL in walker {
            total += Int64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    static func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// The Stop hook for Claude Code lives in the user's own settings, which the app does not
    /// rewrite — the uninstall only points at it.
    static var claudeHookInstalled: Bool {
        let settings = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json")
        return (try? String(contentsOf: settings, encoding: .utf8))?.contains(ClaudeHook.argument) ?? false
    }

    // MARK: - Asking

    /// Asks what to remove, removes it, and quits. `alreadyInTrash`: the app itself was
    /// dragged there, so only the data is left to ask about.
    @MainActor
    static func ask(alreadyInTrash: Bool) {
        var items = items()
        let alert = NSAlert()
        alert.messageText = alreadyInTrash
            ? String(localized: "VoiceAI jest w Koszu. Usunąć też jego dane?")
            : String(localized: "Odinstalować VoiceAI?")
        var info = String(localized: "Zaznaczone pliki trafią do Kosza — do czasu jego opróżnienia da się je przywrócić.")
        if claudeHookInstalled {
            info += "\n\n" + String(localized: "Hook czytania odpowiedzi zostaje w ~/.claude/settings.json — usuń wpis z „--claude-hook” ręcznie.")
        }
        alert.informativeText = info
        let boxes = items.map { item -> NSButton in
            let box = NSButton(checkboxWithTitle: "\(item.title) — \(formatted(item.bytes))", target: nil, action: nil)
            box.state = item.checked ? .on : .off
            box.toolTip = item.detail
            return box
        }
        let stack = NSStackView(views: boxes)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.frame = NSRect(x: 0, y: 0, width: 360, height: CGFloat(boxes.count) * 24)
        alert.accessoryView = stack
        alert.addButton(withTitle: alreadyInTrash ? String(localized: "Usuń zaznaczone") : String(localized: "Odinstaluj"))
        alert.addButton(withTitle: alreadyInTrash ? String(localized: "Zostaw dane") : String(localized: "Anuluj"))
        NSApp.activate()
        let answer = alert.runModal()
        guard answer == .alertFirstButtonReturn else {
            if alreadyInTrash { NSApp.terminate(nil) }
            return
        }
        for (index, box) in boxes.enumerated() { items[index].checked = box.state == .on }
        remove(items, app: alreadyInTrash ? nil : Bundle.main.bundleURL)
        NSApp.terminate(nil)
    }

    @MainActor
    private static func remove(_ items: [Item], app: URL?) {
        try? SMAppService.mainApp.unregister()
        for item in items where item.checked {
            for url in item.urls where FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
            }
            if item.removesSettings { UserDefaults.standard.removePersistentDomain(forName: bundleID) }
        }
        // The data folder itself, once nothing is left in it.
        if (try? FileManager.default.contentsOfDirectory(atPath: data.path))?.isEmpty == true {
            try? FileManager.default.trashItem(at: data, resultingItemURL: nil)
        }
        if let app { try? FileManager.default.trashItem(at: app, resultingItemURL: nil) }
    }

    // MARK: - Dragged to the Trash

    private static var watch: Timer?

    /// The running app still knows where it was launched from; once that path is gone and
    /// the bundle sits in the Trash, it was thrown away while running.
    @MainActor
    static func watchForTrash() {
        let path = Bundle.main.bundlePath
        let trash = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first
        watch = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { timer in
            guard !FileManager.default.fileExists(atPath: path), let trash else { return }
            let name = (path as NSString).lastPathComponent
            guard FileManager.default.fileExists(atPath: trash.appending(path: name).path) else { return }
            timer.invalidate()
            MainActor.assumeIsolated { ask(alreadyInTrash: true) }
        }
    }
}
