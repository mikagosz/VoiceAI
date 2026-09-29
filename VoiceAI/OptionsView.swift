import AppKit
import AVFoundation
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// Settings shared by the options window and the menu — both read and write the same
/// UserDefaults keys, so a change in one shows in the other.
enum Setting {
    static let showLevelBar = "showLevelBar"
    static let iconStyle = "iconStyle"
    static let whisperMode = "whisperMode"
    static let readReplies = "readClaudeReplies"
    static let voice = "voice"
    static let desktopFile = "desktopFileWhenNoField"
    /// Language code the dictation is translated into; empty = no translation.
    static let translateTo = "translateTo"
    static let tidyText = "tidyText"
    /// Look for a newer VoiceAI once a month (`Updates`).
    static let checkUpdates = "checkUpdates"
}

/// The "Ustawienia…" window. Changes apply right away, there is no Save button.
struct OptionsView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @ObservedObject var textModel: TextModel
    @AppStorage(Setting.translateTo) private var translateTo = ""
    @AppStorage(Setting.tidyText) private var tidyText = false
    @AppStorage(Setting.showLevelBar) private var showLevelBar = true
    @AppStorage(Setting.iconStyle) private var iconStyle = IconStyle.fallback.rawValue
    @AppStorage(Setting.whisperMode) private var whisperMode = false
    @AppStorage(Setting.readReplies) private var readReplies = true
    @AppStorage(Setting.voice) private var voice = ""
    @AppStorage(Setting.desktopFile) private var desktopFile = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var interface = Language.chosenInterface ?? Self.automatic
    /// What the app runs in now — a different choice needs a restart.
    private let runningInterface = Language.chosenInterface ?? Self.automatic
    private static let automatic = "auto"
    @State private var sizes: [String: Int64] = [:]
    @ObservedObject private var updates = Updates.shared
    @AppStorage(Setting.checkUpdates) private var checkUpdates = true

    private var voices: [AVSpeechSynthesisVoice] { Speaker.voices(for: vocabulary.current.jezyk) }

    /// Whisper's languages by name, the current one kept even if the list ever loses it.
    private var languages: [String] {
        Language.whisper.union([vocabulary.current.jezyk]).sorted {
            Language.name(of: $0).localizedStandardCompare(Language.name(of: $1)) == .orderedAscending
        }
    }

    private var speechLanguage: Binding<String> {
        Binding(get: { vocabulary.current.jezyk }, set: { code in vocabulary.update { $0.jezyk = code } })
    }

    var body: some View {
        Form {
            Section {
                Picker("Język programu", selection: $interface) {
                    Text("Automatycznie — jak w systemie").tag(Self.automatic)
                    Text(verbatim: "Polski").tag("pl")
                    Text(verbatim: "English").tag("en")
                }
                .onChange(of: interface) { _, code in
                    Language.chosenInterface = code == Self.automatic ? nil : code
                }
                if interface != runningInterface {
                    HStack {
                        Text("Nowy język pojawi się po ponownym uruchomieniu.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Uruchom ponownie") { Self.relaunch() }
                    }
                }
            }
            Section("Dyktowanie") {
                Picker("Język mowy", selection: speechLanguage) {
                    ForEach(languages, id: \.self) { Text(Language.name(of: $0)).tag($0) }
                }
                Toggle("Pokazuj pasek z poziomem głosu na ekranie", isOn: $showLevelBar)
                Toggle("Tryb szeptu", isOn: $whisperMode)
            }
            Section {
                Toggle("Zapisuj też jako plik na biurku", isOn: $desktopFile)
            } header: {
                Text("Gdy nie ma pola tekstowego")
            } footer: {
                Text("Tekst zawsze trafia do dziennika VoiceAI. Plik na biurku robi Finder, tak jak przy zwykłym wklejeniu.")
                    .foregroundStyle(.secondary)
            }
            Section("Ikona w pasku menu") {
                Picker("Wygląd", selection: $iconStyle) {
                    ForEach(IconStyle.allCases, id: \.rawValue) { style in
                        Label {
                            Text(style.title)
                        } icon: {
                            Image(nsImage: StatusIcon.image(style: style, mode: .idle,
                                                            levels: style.restingLevels, whisper: false))
                        }
                        .tag(style.rawValue)
                    }
                }
                .onAppear { iconStyle = IconStyle.stored(iconStyle).rawValue }
            }
            Section("Odpowiedzi Claude'a") {
                Toggle("Czytaj odpowiedzi na głos", isOn: $readReplies)
                if voices.isEmpty {
                    Text("Brak zainstalowanych głosów w tym języku — pobierzesz je w menu Głos.")
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Głos", selection: $voice) {
                        // The system name already carries the quality: "Krzysztof (rozszerzony)".
                        ForEach(voices, id: \.identifier) { Text($0.name).tag($0.identifier) }
                    }
                    .disabled(!readReplies)
                }
            }
            Section {
                ForEach(vocabulary.current.appRules.sorted { $0.value.nazwa < $1.value.nazwa }, id: \.key) { id, rule in
                    HStack {
                        Text(rule.nazwa)
                        Spacer()
                        Toggle("Kropka na końcu", isOn: appBinding(id, \.kropka))
                        Toggle("Wielka litera", isOn: appBinding(id, \.wielkaLitera))
                        Toggle("Spacja na końcu", isOn: appBinding(id, \.spacja))
                        Button {
                            vocabulary.updateApps { $0[id] = nil }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Usuń regułę")
                    }
                    .toggleStyle(.checkbox)
                }
                Button("Dodaj aplikację…") { addApp() }
            } header: {
                Text("Aplikacje")
            } footer: {
                Text("Własne zamiany słów dla aplikacji dopiszesz w słowniku, w sekcji „aplikacje”.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(textModel.installed) { entry in
                    let chosen = entry.id == textModel.selected?.id
                    HStack {
                        Image(systemName: chosen ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(chosen ? Color.accentColor : Color.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: entry.name)
                            Text(chosen ? textModelStatus : entry.repo ?? String(localized: "z dysku"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { textModel.remove(entry) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                            .help("Usuń model")
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { textModel.selectedID = entry.id }
                }
                if !textModel.hasRecommended {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: TextModel.recommended.name)
                            Text("Zalecany — \(Uninstaller.formatted(TextModel.recommended.bytes)), nie pobrany")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Pobierz") { Task { await textModel.downloadRecommended() } }
                            .disabled(textModel.download != nil)
                    }
                }
                if let download = textModel.download {
                    HStack {
                        Text("Pobieram \(download.name)…")
                        Spacer()
                        if let fraction = download.fraction {
                            ProgressView(value: fraction).frame(width: 120)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
                if let error = textModel.downloadError {
                    Text(verbatim: error).font(.caption).foregroundStyle(.red)
                }
                Button("Dodaj własny model…") { textModel.addSheetShown = true }
                    .disabled(textModel.download != nil)
                Picker("Tłumacz dyktowanie na", selection: $translateTo) {
                    Text("Nie tłumacz").tag("")
                    ForEach(languages.filter { $0 != vocabulary.current.jezyk }, id: \.self) { Text(Language.name(of: $0)).tag($0) }
                }
                .disabled(!textModel.isDownloaded)
                Toggle("Porządkuj tekst — bez „yyy”, powtórzeń, z interpunkcją", isOn: $tidyText)
                    .disabled(!textModel.isDownloaded)
            } header: {
                Text("Model językowy")
            } footer: {
                Text("Działa na tym Macu, bez internetu. Pobiera się dopiero na żądanie i zwalnia pamięć po 10 minutach bez użycia. Porządkowanie czasem zmienia sens zdania, dlatego jest domyślnie wyłączone. Własny model: dowolny model MLX z Hugging Face (np. z mlx-community) albo folder z dysku — kliknij model, żeby go wybrać.")
                    .foregroundStyle(.secondary)
            }
            Section {
                ForEach(models, id: \.folder) { model in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: model.name)
                            Text(model.role).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(verbatim: sizes[model.folder].map(Uninstaller.formatted) ?? "—").foregroundStyle(.secondary)
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([Uninstaller.data.appending(path: model.folder)])
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Pokaż w Finderze")
                    }
                }
                HStack {
                    Text(verbatim: "~/Library/Application Support/VoiceAI").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Pokaż folder") { NSWorkspace.shared.open(Uninstaller.data) }
                }
            } header: {
                Text("Modele i pliki")
            } footer: {
                Text("Wszystko, co VoiceAI zapisuje, leży w tym jednym folderze. Whisper pobiera się tu przy pierwszym uruchomieniu, model językowy — dopiero na żądanie.")
                    .foregroundStyle(.secondary)
            }
            .task(id: textModel.installed.map(\.id)) { measureSizes() }
            Section {
                Toggle("Sprawdzaj aktualizacje raz w miesiącu", isOn: $checkUpdates)
                    .onChange(of: checkUpdates) { _, on in updates.enabled = on }
                HStack {
                    Text(lastCheckText).foregroundStyle(.secondary)
                    Spacer()
                    Button("Sprawdź teraz") { Task { await updates.check(manually: true) } }
                }
            } header: {
                Text("Aktualizacje")
            } footer: {
                Text("Program pyta stronę fractal8.eu o numer najnowszej wersji — nic więcej nie wysyła. Nowa wersja instaluje się dopiero, gdy klikniesz „Zainstaluj”.")
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("Uruchamiaj przy logowaniu", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do {
                            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Button("Odinstaluj VoiceAI…", role: .destructive) { Uninstaller.ask(alreadyInTrash: false) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 620)
        .frame(minHeight: 320)
        .sheet(isPresented: $textModel.addSheetShown) { AddModelView(textModel: textModel) }
        // No model left: the switches that need one go back off.
        .onChange(of: textModel.isDownloaded) { _, any in
            if !any { translateTo = ""; tidyText = false }
        }
        .onAppear(perform: showVoiceInUse)
        .onChange(of: vocabulary.current.jezyk) { showVoiceInUse() }
    }

    /// Models on disk: folder inside the data folder, shown name, what it does.
    private struct Model {
        var folder: String
        var name: String
        var role: LocalizedStringKey
    }

    private static let whisper = Model(folder: "Modele/models/argmaxinc/whisperkit-coreml/\(Transcriber.variant)",
                                       name: "Whisper large-v3-turbo", role: "Rozpoznawanie mowy · wymagany")

    /// The models on disk right now — the language model only once it is downloaded.
    private var models: [Model] {
        var list = [Self.whisper]
        for entry in textModel.installed {
            let folder = entry.folder.path.replacingOccurrences(of: Uninstaller.data.path + "/", with: "")
            list.append(Model(folder: folder, name: entry.name, role: "Tłumaczenie i porządkowanie tekstu · opcjonalny"))
        }
        return list
    }

    private var lastCheckText: String {
        guard let date = updates.lastCheck else { return String(localized: "Jeszcze nie sprawdzano") }
        return String(localized: "Ostatnio: \(date.formatted(date: .abbreviated, time: .shortened))")
    }

    private var textModelStatus: String {
        switch textModel.state {
        case .absent: String(localized: "Nie pobrany")
        case .downloaded: String(localized: "Pobrany — wczyta się przy pierwszym użyciu")
        case .loading: String(localized: "Wczytuję…")
        case .ready: String(localized: "Gotowy")
        case .failed(let message): message
        }
    }

    private func measureSizes() {
        let folders = models.map(\.folder)
        Task.detached {
            let measured = Dictionary(uniqueKeysWithValues: folders.map { ($0, Uninstaller.size(of: Uninstaller.data.appending(path: $0))) })
            await MainActor.run { sizes = measured }
        }
    }

    /// Starts a fresh copy once this one has quit — two copies would both listen for the key.
    private static func relaunch() {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", "while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done; open \"$0\"",
                          Bundle.main.bundlePath]
        try? task.run()
        NSApp.terminate(nil)
    }

    /// Show the voice actually in use when none of this language was picked yet.
    private func showVoiceInUse() {
        if !voices.contains(where: { $0.identifier == voice }), let best = voices.first { voice = best.identifier }
    }

    private func appBinding(_ id: String, _ key: WritableKeyPath<AppRule, Bool>) -> Binding<Bool> {
        Binding(
            get: { vocabulary.current.appRules[id]?[keyPath: key] ?? false },
            set: { value in vocabulary.updateApps { $0[id]?[keyPath: key] = value } }
        )
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.prompt = String(localized: "Dodaj")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url),
              let id = bundle.bundleIdentifier else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        vocabulary.updateApps { $0[id] = $0[id] ?? AppRule(nazwa: name) }
    }
}

/// One options window, reused; brought to the front since the app has no Dock icon.
@MainActor
final class OptionsWindow {
    private var window: NSWindow?
    private let vocabulary: VocabularyStore
    private let textModel: TextModel

    init(vocabulary: VocabularyStore, textModel: TextModel) {
        self.vocabulary = vocabulary
        self.textModel = textModel
    }

    func show() {
        vocabulary.reload()
        if window == nil {
            let host = NSHostingController(rootView: OptionsView(vocabulary: vocabulary, textModel: textModel))
            // The window must not grow to the form's full height — it went under the Dock.
            host.sizingOptions = [.minSize]
            let window = NSWindow(contentViewController: host)
            window.title = String(localized: "VoiceAI — Ustawienia")
            window.styleMask = [.titled, .closable, .resizable]
            window.isReleasedWhenClosed = false
            // Never taller than the screen above the Dock; the form scrolls inside.
            let room = (NSScreen.main?.visibleFrame.height ?? 800) - 60
            window.setContentSize(NSSize(width: 620, height: min(680, room)))
            window.center()
            self.window = window
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

/// "Dodaj własny model…": a Hugging Face name or link, checked before anything downloads,
/// or an MLX model folder already on disk.
struct AddModelView: View {
    @ObservedObject var textModel: TextModel
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var candidate: TextModel.Candidate?
    @State private var problem: String?
    @State private var checking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Dodaj własny model").font(.headline)
            Text("Model w formacie MLX z Hugging Face, np. z mlx-community. Wklej nazwę albo link — program sprawdzi go, zanim cokolwiek pobierze.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                TextField(text: $input, prompt: Text(verbatim: "mlx-community/Qwen3-4B-4bit")) { EmptyView() }
                    .onSubmit(check)
                Button("Sprawdź", action: check).disabled(input.isEmpty || checking)
            }
            if checking {
                ProgressView().controlSize(.small)
            }
            if let candidate {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: candidate.repo).bold()
                    Text("Typ \(candidate.modelType) · \(Uninstaller.formatted(candidate.bytes)) · obsługiwany")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if let problem {
                Text(verbatim: problem).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Button("Wybierz folder z dysku…", action: chooseFolder)
                Spacer()
                Button("Anuluj") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Pobierz", action: download).keyboardShortcut(.defaultAction).disabled(candidate == nil)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: input) { candidate = nil; problem = nil }
    }

    private func check() {
        checking = true
        problem = nil
        candidate = nil
        Task {
            do { candidate = try await textModel.check(input) } catch { problem = error.localizedDescription }
            checking = false
        }
    }

    private func download() {
        guard let candidate else { return }
        dismiss()
        Task { await textModel.install(candidate) }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = String(localized: "Dodaj")
        panel.message = String(localized: "Folder modelu MLX — z plikiem config.json i wagami .safetensors")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        dismiss()
        Task { await textModel.addFolder(url) }
    }
}
