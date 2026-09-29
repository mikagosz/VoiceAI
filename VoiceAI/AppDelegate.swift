import AppKit
import AVFoundation
import ServiceManagement
import os

let log = Logger(subsystem: "com.mikagosz.VoiceAI", category: "app")

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private enum State: Equatable {
        case loading(Double?), ready, recording, working, failed(String)
        /// Recognising a whole audio or video file: its name and 0…1.
        case file(String, Double)
    }

    /// Shorter than this is a tap on ⌥, not speech.
    private static let minimumSeconds = 0.3
    /// Quieter than this (RMS) is silence — Whisper would invent text for it.
    private static let silence: Float = 0.003
    /// Whisper mode: a whisper can sit well under the normal threshold, and Whisper still
    /// reads speech at RMS 0.001 (test voice with noise added, 2026-09-29).
    private static let whisperSilence: Float = 0.0004
    /// Whisper mode: quiet recordings are lifted to this RMS before recognition — at RMS
    /// 0.0005 that turned a garbled whisper back into the sentence that was said.
    private static let whisperLoudness: Float = 0.05
    private static let historyLimit = 15

    private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "VoiceAI")
    private lazy var vocabulary = VocabularyStore(directory: directory)
    private lazy var transcriber = Transcriber(directory: directory)
    @MainActor lazy var textModel = TextModel(directory: directory)
    private let recorder = Recorder()
    private let key = HoldKey()
    private let live = LivePanel()
    private var meter: Timer?
    private let speaker = Speaker()
    @MainActor private lazy var options = OptionsWindow(vocabulary: vocabulary, textModel: textModel)
    private var whisperMode: Bool {
        get { UserDefaults.standard.bool(forKey: Setting.whisperMode) }
        set { UserDefaults.standard.set(newValue, forKey: Setting.whisperMode) }
    }
    private var readReplies: Bool {
        get { UserDefaults.standard.object(forKey: Setting.readReplies) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Setting.readReplies) }
    }
    private var showLevelBar: Bool {
        UserDefaults.standard.object(forKey: Setting.showLevelBar) as? Bool ?? true
    }

    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var state = State.loading(nil) { didSet { updateIcon() } }
    private var history: [String] = []
    /// Files waiting to be recognised, one after another — opened on the icon or from the menu.
    private var pendingFiles: [URL] = []
    private var recordingStarted = Date()
    private lazy var journal = Journal(directory: directory)
    private let stats = Stats()
    private lazy var journalWindow = JournalWindow(journal: journal)
    /// With no text field to type into: also let Finder drop the text as a file (the old
    /// behaviour), on top of the journal entry. On by default, off in Options.
    private var desktopFile: Bool {
        UserDefaults.standard.object(forKey: Setting.desktopFile) as? Bool ?? true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        vocabulary.reload()
        key.onPress = { [weak self] in
            // Pressing the key to answer cuts Claude's voice off.
            self?.speaker.stop()
            self?.startRecording()
        }
        key.onRelease = { [weak self] in self?.finishRecording() }
        key.onCancel = { [weak self] in self?.cancelRecording() }
        key.start()
        registerLoginItemOnce()
        // The options window and the menu write the same settings; the icon follows either.
        NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            // Delivered on the main queue, so on the main actor.
            MainActor.assumeIsolated { self?.updateIcon() }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(claudeReplied(_:)), name: ClaudeHook.notification,
            object: nil, suspensionBehavior: .deliverImmediately)

        Uninstaller.watchForTrash()

        AVCaptureDevice.requestAccess(for: .audio) { _ in }
        if !Paster.trusted {
            Paster.askForPermission()
            waitForAccessibility()
        }
        loadModel()
    }

    /// Key monitors added before the permission was granted stay deaf, so they are
    /// re-added once it arrives.
    private func waitForAccessibility() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard Paster.trusted else { return }
            timer.invalidate()
            // Scheduled on the main run loop, so on the main actor.
            MainActor.assumeIsolated { self?.key.start() }
        }
    }

    private func loadModel() {
        state = .loading(nil)
        Task { @MainActor in
            do {
                try await transcriber.load { fraction in
                    DispatchQueue.main.async { self.state = .loading(fraction) }
                }
                state = .ready
                nextFile()
            } catch {
                state = .failed(String(localized: "Nie udało się wczytać modelu: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Dictation

    private func startRecording() {
        if case .file = state {
            flash(String(localized: "Przepisuję plik — dyktowanie po zakończeniu"))
            return
        }
        guard state == .ready else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            // Without the permission the engine records silence and nothing would happen at all.
            flash(String(localized: "Brak dostępu do mikrofonu — włącz go w menu VoiceAI"))
            return
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in }
            return
        default:
            break
        }
        do {
            try recorder.start()
            recordingStarted = Date()
            state = .recording
            if showLevelBar {
                live.target(Paster.destination)
                live.listening()
            }
            var ticks = 0
            meter = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                ticks += 1
                let tick = ticks
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Follow a switch of window mid-sentence, a few times a second.
                    if tick % 8 == 0, self.showLevelBar { self.live.target(Paster.destination) }
                    // Whisper mode shows the wave 20 dB hotter, so a whisper still moves it.
                    self.live.level(self.recorder.level * (self.whisperMode ? 10 : 1))
                }
            }
        } catch {
            state = .failed(String(localized: "Mikrofon: \(error.localizedDescription)"))
        }
    }

    /// A short message in the level bar's place, with a sound — for a key press that cannot record.
    private func flash(_ text: String) {
        NSSound.beep()
        live.target(Paster.destination)
        live.working(text)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.state != .recording else { return }
            if case .working = self.state { return }
            self.live.hide()
        }
    }

    private func cancelRecording() {
        guard state == .recording else { return }
        _ = recorder.stop()
        stopMeter()
        live.hide()
        state = .ready
    }

    private func stopMeter() {
        meter?.invalidate()
        meter = nil
    }

    /// The pasted text always comes from one pass over the whole recording. Gluing pieces
    /// cut at pauses together (0.1.3) read worse on a real voice than on the test voice.
    private func finishRecording() {
        guard state == .recording else { return }
        var samples = recorder.stop()
        stopMeter()
        let seconds = Date().timeIntervalSince(recordingStarted)
        let threshold = whisperMode ? Self.whisperSilence : Self.silence
        guard seconds >= Self.minimumSeconds, rms(samples) >= threshold else {
            live.hide()
            state = .ready
            return
        }
        if whisperMode { samples = Recorder.boosted(samples, to: Self.whisperLoudness) }
        state = .working
        if showLevelBar { live.working() }
        vocabulary.reload()
        let words = vocabulary.current
        // The app the text is for — decided at release, before Whisper takes its second.
        let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let noTextField = Paster.certainlyNoTextField
        Task { @MainActor in
            var confirmation: String?
            defer {
                if let confirmation, showLevelBar {
                    live.working(confirmation)
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(1.2))
                        if state != .recording { live.hide() }
                    }
                } else {
                    live.hide()
                }
                state = .ready
            }
            do {
                let raw = try await transcriber.transcribe(samples, vocabulary: words)
                let processed = await refine(words.apply(to: raw), language: words.jezyk)
                let text = noTextField ? processed : words.finish(processed, for: app)
                guard !text.isEmpty else { return }
                remember(text)
                stats.record(text, seconds: seconds)
                // Nowhere to type: the text goes to VoiceAI's journal instead of being lost.
                if noTextField {
                    try journal.add(text)
                    confirmation = String(localized: "Zapisane w dzienniku")
                    if !showLevelBar { NSSound(named: "Pop")?.play() }
                    if desktopFile { Paster.paste(text) }
                } else if !Paster.paste(text) {
                    NSSound.beep()
                }
            } catch {
                log.error("Dictation failed: \(error.localizedDescription, privacy: .public)")
                NSSound.beep()
            }
        }
    }

    // MARK: - Files

    /// Audio or video dropped on the app's icon, or opened with it from Finder.
    func application(_ application: NSApplication, open urls: [URL]) {
        transcribe(files: urls)
    }

    private func transcribe(files: [URL]) {
        pendingFiles += files
        nextFile()
    }

    /// One file at a time, and only when dictation is idle — both use the same model.
    private func nextFile() {
        guard state == .ready, !pendingFiles.isEmpty else { return }
        let file = pendingFiles.removeFirst()
        let name = file.lastPathComponent
        state = .file(name, 0)
        vocabulary.reload()
        let words = vocabulary.current
        Task { @MainActor in
            do {
                let accessed = file.startAccessingSecurityScopedResource()
                defer { if accessed { file.stopAccessingSecurityScopedResource() } }
                let transcript = try await transcriber.transcribe(file: file, vocabulary: words) { fraction in
                    DispatchQueue.main.async {
                        if case .file(name, _) = self.state { self.state = .file(name, fraction) }
                    }
                }
                guard !transcript.lines.isEmpty else { throw Transcriber.FileError.noSpeech }
                let written = try transcript.write(nextTo: file)
                log.info("File transcribed: \(transcript.lines.count, privacy: .public) lines")
                NSSound(named: "Glass")?.play()
                NSWorkspace.shared.activateFileViewerSelecting([written])
            } catch {
                log.error("File failed: \(error.localizedDescription, privacy: .public)")
                let alert = NSAlert()
                alert.messageText = String(localized: "Nie udało się przepisać „\(name)”")
                alert.informativeText = error.localizedDescription
                NSApp.activate()
                alert.runModal()
            }
            state = .ready
            nextFile()
        }
    }

    @objc private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Przepisz plik audio lub wideo")
        panel.prompt = String(localized: "Przepisz")
        panel.allowedContentTypes = [.audiovisualContent]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        transcribe(files: panel.urls)
    }

    /// The language model's part, when turned on in Settings. A translation always tidies first:
    /// translated raw, fillers stayed in ("Eee, milk…"); translated in one pass with the tidy asked
    /// for, whole clauses went missing (measured 2026-09-29).
    /// Any failure keeps the text as Whisper gave it — a dictation is never lost to the model.
    @MainActor
    private func refine(_ text: String, language: String) async -> String {
        let defaults = UserDefaults.standard
        let target = defaults.string(forKey: Setting.translateTo) ?? ""
        let tidy = defaults.bool(forKey: Setting.tidyText)
        guard textModel.isDownloaded, !text.isEmpty, tidy || (!target.isEmpty && target != language) else { return text }
        var result = text
        do {
            if showLevelBar { live.working(String(localized: "Porządkuję…")) }
            result = try await textModel.tidy(text, language: language)
            if !target.isEmpty, target != language {
                if showLevelBar { live.working(String(localized: "Tłumaczę…")) }
                result = try await textModel.translate(result, to: target)
            }
        } catch {
            log.error("Language model failed: \(error.localizedDescription, privacy: .public)")
            return text
        }
        return result.isEmpty ? text : result
    }

    private func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        return (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
    }

    private func remember(_ text: String) {
        history.insert(text, at: 0)
        if history.count > Self.historyLimit { history.removeLast() }
    }

    // MARK: - Menu bar

    private var iconStyle: IconStyle {
        IconStyle.stored(UserDefaults.standard.string(forKey: Setting.iconStyle))
    }
    /// Recent loudness per crest while recording, newest on the right — the wave flows left.
    private var iconLevels: [CGFloat] = []
    private var iconPhase: CGFloat = 0
    private var iconTimer: Timer?

    /// Sets the icon for the current state and runs the animation only while it moves.
    private func updateIcon() {
        statusItem.length = iconStyle.isPill ? 40 : NSStatusItem.squareLength
        let moving: Bool
        switch state {
        case .recording, .working, .file: moving = true
        default: moving = false
        }
        if moving, iconTimer == nil {
            iconLevels = [CGFloat](repeating: 0, count: iconStyle.crestCount)
            iconTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.animateIcon() }
            }
        } else if !moving {
            iconTimer?.invalidate()
            iconTimer = nil
        }
        drawIcon()
    }

    private func animateIcon() {
        if state == .recording {
            // Same 20 dB lift as the level bar in whisper mode.
            iconLevels.removeFirst()
            iconLevels.append(max(0.15, Voice.level(recorder.level * (whisperMode ? 10 : 1))))
        } else {
            iconPhase += 0.22
        }
        drawIcon()
    }

    private func drawIcon() {
        guard let button = statusItem.button else { return }
        let style = iconStyle
        let mode: StatusIcon.Mode
        var levels = style.restingLevels
        switch state {
        case .loading: mode = .loading
        case .ready: mode = .idle
        case .recording:
            mode = .active
            levels = iconLevels
        case .working, .file:
            mode = .working
            // A wave running across the resting shape while Whisper works.
            levels = levels.enumerated().map { index, level in
                level * (0.45 + 0.55 * (0.5 + 0.5 * sin(iconPhase - CGFloat(index) * 0.9)))
            }
        case .failed: mode = .failed
        }
        button.image = StatusIcon.image(style: style, mode: mode, levels: levels, whisper: whisperMode)
    }

    private var statusText: String {
        switch state {
        case .loading(let fraction?): return String(localized: "Pobieram model Whisper… \(Int(fraction * 100))%")
        case .loading(nil): return String(localized: "Wczytuję model Whisper…")
        case .ready: return whisperMode ? String(localized: "Tryb szeptu — trzymaj prawy ⌥ i szepcz") : String(localized: "Gotowy — trzymaj prawy ⌥ i mów")
        case .recording: return String(localized: "Nagrywam…")
        case .working: return String(localized: "Rozpoznaję…")
        case .file(let name, let fraction): return String(localized: "Przepisuję „\(shortened(name))” — \(Int(fraction * 100))%")
        case .failed(let message): return message
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menu.addItem(disabled(statusText))
        if let problem = vocabulary.problem { menu.addItem(disabled(problem)) }
        if !Paster.trusted {
            menu.addItem(item(String(localized: "Włącz Dostępność (wklejanie i klawisz)…"), #selector(openAccessibility)))
        }
        if [.denied, .restricted].contains(AVCaptureDevice.authorizationStatus(for: .audio)) {
            menu.addItem(item(String(localized: "Włącz mikrofon…"), #selector(openMicrophone)))
        }
        if case .failed = state { menu.addItem(item(String(localized: "Spróbuj ponownie wczytać model"), #selector(retryModel))) }
        menu.addItem(disabled(String(localized: "Dziś: \(Stats.summary(stats.day()))"), symbol: "chart.bar"))
        menu.addItem(disabled(String(localized: "Ten tydzień: \(Stats.summary(stats.week()))")))

        menu.addItem(.separator())
        if history.isEmpty {
            menu.addItem(disabled(String(localized: "Historia jest pusta")))
        } else {
            menu.addItem(disabled(String(localized: "Ostatnie — kliknij, by skopiować")))
            for text in history {
                let entry = item(shortened(text), #selector(copyEntry(_:)))
                entry.representedObject = text
                entry.toolTip = text
                menu.addItem(entry)
            }
        }

        menu.addItem(.separator())
        if state == .ready {
            menu.addItem(item(String(localized: "Przepisz plik audio lub wideo…"), #selector(chooseFiles), symbol: "doc.text"))
        } else {
            menu.addItem(disabled(String(localized: "Przepisz plik audio lub wideo…"), symbol: "doc.text"))
        }
        if !pendingFiles.isEmpty { menu.addItem(disabled(String(localized: "W kolejce: \(pendingFiles.count)"))) }
        menu.addItem(item(String(localized: "Edytuj słownik…"), #selector(editVocabulary)))
        let whisper = item(String(localized: "Tryb szeptu"), #selector(toggleWhisperMode), symbol: "mouth")
        whisper.state = whisperMode ? .on : .off
        menu.addItem(whisper)
        let replies = item(String(localized: "Czytaj odpowiedzi Claude'a"), #selector(toggleReadReplies))
        Self.decorate(replies, with: Self.claudeMark)
        replies.state = readReplies ? .on : .off
        menu.addItem(replies)
        menu.addItem(voiceMenu())
        menu.addItem(item(String(localized: "Dziennik…"), #selector(openJournal), symbol: "book.closed"))
        menu.addItem(item(String(localized: "Ustawienia…"), #selector(openOptions), symbol: "gearshape"))
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        menu.addItem(disabled("VoiceAI \(version)"))
        menu.addItem(NSMenuItem(title: String(localized: "Zakończ VoiceAI"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Claude's orange on an asterisk — a nod to the mark, not a copy of Anthropic's logo.
    private static let claudeMark: NSImage? = {
        let orange = NSColor(srgbRed: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255, alpha: 1)
        let image = NSImage(systemSymbolName: "asterisk", accessibilityDescription: "Claude")?
            .withSymbolConfiguration(.init(paletteColors: [orange]))
        image?.isTemplate = false
        return image
    }()

    /// Puts the icon inside the title itself. `NSMenuItem.image` does not show in this menu
    /// on macOS 27 (screenshot from [U], 0.1.18); text with an attached image always does.
    private static func decorate(_ item: NSMenuItem, with image: NSImage?, enabled: Bool = true) {
        guard let image else { return }
        let font = NSFont.menuFont(ofSize: 0)
        // Every icon in a box of the same size, so the titles after them line up.
        let box = NSSize(width: 20, height: font.capHeight + 5)
        let color: NSColor = enabled ? .labelColor : .disabledControlTextColor
        let boxed = NSImage(size: box, flipped: false) { rect in
            let scale = min(rect.width / image.size.width, rect.height / image.size.height)
            let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
            let target = NSRect(x: (rect.width - size.width) / 2, y: (rect.height - size.height) / 2,
                                width: size.width, height: size.height)
            image.draw(in: target)
            // A system symbol drawn by hand comes out black — tint it like the title,
            // resolved at draw time so light and dark menus both get the right shade.
            if image.isTemplate {
                color.set()
                target.fill(using: .sourceAtop)
            }
            return true
        }
        let attachment = NSTextAttachment()
        attachment.image = boxed
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - box.height) / 2, width: box.width, height: box.height)
        let title = NSMutableAttributedString(attachment: attachment)
        title.append(NSAttributedString(string: "  " + item.title))
        title.addAttributes([.font: font, .foregroundColor: color], range: NSRange(location: 0, length: title.length))
        item.attributedTitle = title
    }

    private func item(_ title: String, _ action: Selector, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let symbol { Self.decorate(item, with: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)) }
        return item
    }

    private func disabled(_ title: String, symbol: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        if let symbol { Self.decorate(item, with: NSImage(systemSymbolName: symbol, accessibilityDescription: nil), enabled: false) }
        return item
    }

    private func shortened(_ text: String) -> String {
        let line = text.replacingOccurrences(of: "\n", with: " ")
        return line.count > 60 ? String(line.prefix(60)) + "…" : line
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func editVocabulary() {
        vocabulary.reload()
        NSWorkspace.shared.open([vocabulary.file], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }

    @objc private func openMicrophone() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
    }

    @objc private func openAccessibility() {
        Paster.askForPermission()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    /// Turned on by itself once, on the first launch; after that only the menu changes it,
    /// so switching it off (here or in System Settings) sticks.
    private func registerLoginItemOnce() {
        let key = "loginItemAdded"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        UserDefaults.standard.set(true, forKey: key)
    }

    /// A reply from Claude Code, sent by the Stop hook (see ClaudeHook). Not read while you
    /// are dictating or while your dictation is still being recognised.
    @objc private func claudeReplied(_ notification: Notification) {
        // Taken even when not read aloud, so no reply is left lying in the data folder.
        let text = ClaudeHook.takeReply()
        log.info("Claude reply received: readReplies=\(self.readReplies, privacy: .public) state=\(String(describing: self.state), privacy: .public) hasText=\(text != nil, privacy: .public)")
        guard readReplies, state == .ready, let text else { return }
        speaker.speak(text, language: vocabulary.current.jezyk)
    }

    @objc private func toggleWhisperMode() {
        whisperMode.toggle()
    }

    /// Installed Polish voices; picking one reads a short sample so you hear it right away.
    private func voiceMenu() -> NSMenuItem {
        let submenu = NSMenu()
        let language = vocabulary.current.jezyk
        let current = speaker.voice(for: language)?.identifier
        for voice in Speaker.voices(for: language) {
            // The system name already carries the quality: "Krzysztof (rozszerzony)".
            let entry = item(voice.name, #selector(pickVoice(_:)))
            entry.representedObject = voice.identifier
            entry.state = voice.identifier == current ? .on : .off
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        submenu.addItem(item(String(localized: "Pobierz więcej głosów…"), #selector(openSpokenContent)))
        let parent = NSMenuItem(title: String(localized: "Głos"), action: nil, keyEquivalent: "")
        Self.decorate(parent, with: NSImage(systemSymbolName: "waveform", accessibilityDescription: nil))
        parent.submenu = submenu
        return parent
    }

    @objc private func openJournal() {
        showJournal()
    }

    @objc private func openOptions() {
        showOptions()
    }

    func showJournal() {
        journalWindow.show()
    }

    func showOptions() {
        options.show()
    }

    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let identifier = sender.representedObject as? String else { return }
        speaker.pick(identifier)
        let language = vocabulary.current.jezyk
        speaker.speak(language == "pl" ? "Cześć, tak brzmi mój głos." : "Hi, this is how my voice sounds.", language: language)
    }

    @objc private func openSpokenContent() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent")!)
    }

    @objc private func toggleReadReplies() {
        readReplies.toggle()
        if !readReplies { speaker.stop() }
    }

    @objc private func retryModel() {
        loadModel()
    }
}

