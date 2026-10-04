import CryptoKit
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers

/// The language models that translate and tidy dictated text. One is recommended and offered
/// first (two Polish Bieliks follow it, for comparison) — Gemma 4 E2B, text-only, 4-bit MLX (2.7 GB, Apache 2.0), picked on 2026-09-29 after
/// measuring three Gemmas: the fastest (0.8 s a sentence), the least memory and the most
/// faithful to meaning. Anyone can add another MLX model from Hugging Face or from a folder;
/// it is checked before anything is downloaded.
///
/// Nothing downloads until the user asks for it in Settings — the app stays light for those
/// who only dictate. Every model lives in `Modele/llm/<name>/` next to Whisper, not in a
/// library's own cache, so everything VoiceAI keeps is in one folder and leaves with it.
@MainActor
final class TextModel: ObservableObject {
    /// A model on disk.
    struct Entry: Identifiable, Equatable {
        /// Its folder name — unique inside `Modele/llm/`.
        let id: String
        var name: String
        var repo: String?
        var folder: URL
    }

    /// A model checked on Hugging Face, ready to download.
    struct Candidate: Equatable {
        var repo: String
        var name: String
        var modelType: String
        var bytes: Int64
        var files: [String]
        /// SHA-256 that Hugging Face publishes for its large (LFS) files — weights, tokenizer.
        var hashes: [String: String] = [:]
    }

    /// The selected model. `downloaded`: on disk, not in memory — loaded on first use.
    enum State: Equatable {
        case absent, downloaded, loading, ready, failed(String)
    }

    struct Download: Equatable {
        var name: String
        /// nil while copying from a folder, where the size of what is left is not tracked.
        var fraction: Double?
    }

    /// A model offered with its own "Pobierz" button, no repository name to type.
    struct Suggestion: Identifiable {
        var repo: String
        var name: String
        var bytes: Int64
        var id: String { repo }
    }

    static let recommended = Suggestion(repo: "mlx-community/Gemma4-E2B-IT-Text-int4", name: "Gemma 4 E2B",
                                        bytes: 2_680_000_000)
    /// The recommended model first, then Polish ones to try against it (2026-10-04): Bielik v3 from
    /// SpeakLeash, trained on Polish. 4.5B in 4 bits weighs what Gemma does; 1.5B stays in 8 bits
    /// (the official SpeakLeash build), since 4 bits cost a model that small too much.
    static let suggested = [
        recommended,
        Suggestion(repo: "futurist-ai/Bielik-4.5B-v3.0-Instruct-MLX-4bit", name: "Bielik 4.5B", bytes: 2_680_000_000),
        Suggestion(repo: "speakleash/Bielik-1.5B-v3.0-Instruct-MLX-8bit", name: "Bielik 1.5B", bytes: 1_700_000_000),
    ]
    /// Unused this long, the model leaves memory (2.6 GB for Gemma); the next use loads it again in ~3 s.
    static let idleSeconds: TimeInterval = 600
    /// Written next to a model's files: its shown name and where it came from.
    private static let metadataFile = "voiceai-model.json"
    private static let selectedKey = "textModelID"

    let root: URL
    @Published private(set) var installed: [Entry] = []
    @Published private(set) var state = State.absent
    @Published private(set) var download: Download?
    @Published private(set) var downloadError: String?
    /// The "Dodaj własny model" sheet.
    @Published var addSheetShown = false
    @Published var selectedID: String {
        didSet {
            guard selectedID != oldValue else { return }
            UserDefaults.standard.set(selectedID, forKey: Self.selectedKey)
            unload()
        }
    }

    private var container: ModelContainer?
    private var loadedID: String?
    private var idle: Timer?

    init(directory: URL) {
        root = directory.appending(path: "Modele/llm")
        selectedID = UserDefaults.standard.string(forKey: Self.selectedKey) ?? Self.folderName(Self.recommended.repo)
        rescan()
    }

    var selected: Entry? { installed.first { $0.id == selectedID } ?? installed.first }
    /// Whether any model is ready to use — what Settings and the dictation path ask.
    var isDownloaded: Bool { selected != nil }
    /// Suggested models not on disk yet — each gets a "Pobierz" button in Settings.
    var notInstalled: [Suggestion] { Self.suggested.filter { s in !installed.contains { $0.repo == s.repo } } }

    private static func folderName(_ repo: String) -> String { String(repo.split(separator: "/").last ?? "model") }

    /// Folders with a config and all their weights; the recommended one keeps its name even
    /// without the metadata file (the 0.1.27 download wrote none).
    func rescan() {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        installed = folders.compactMap { folder -> Entry? in
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            guard files.contains("config.json"), Self.hasAllWeights(files, in: folder) else { return nil }
            let id = folder.lastPathComponent
            let meta = (try? Data(contentsOf: folder.appending(path: Self.metadataFile)))
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            let isRecommended = id == Self.folderName(Self.recommended.repo)
            // A download cut off leaves no metadata; only the recommended model predates it.
            guard !meta.isEmpty || isRecommended else { return nil }
            return Entry(id: id, name: meta["name"] ?? (isRecommended ? Self.recommended.name : id),
                         repo: meta["repo"] ?? (isRecommended ? Self.recommended.repo : nil), folder: folder)
        }
        .sorted { ($0.repo == Self.recommended.repo ? 0 : 1, $0.name) < ($1.repo == Self.recommended.repo ? 0 : 1, $1.name) }
        if container == nil { state = selected == nil ? .absent : .downloaded }
    }

    /// Weights split into shards list them in `model.safetensors.index.json`; every one must be
    /// there, or the model would be offered and then fail on every dictation.
    nonisolated static func hasAllWeights(_ files: [String], in folder: URL) -> Bool {
        guard files.contains(where: { $0.hasSuffix(".safetensors") }) else { return false }
        guard files.contains("model.safetensors.index.json") else { return true }
        guard let data = try? Data(contentsOf: folder.appending(path: "model.safetensors.index.json")),
              let map = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["weight_map"] as? [String: String]
        else { return false }
        return Set(map.values).isSubset(of: Set(files))
    }

    // MARK: - Checking

    enum CheckError: LocalizedError {
        case notFound, notMLX, unsupported(String), noConfig, damaged(String)

        var errorDescription: String? {
            switch self {
            case .notFound: String(localized: "Nie ma takiego modelu na Hugging Face (albo wymaga logowania).")
            case .notMLX: String(localized: "To nie jest model w formacie MLX — brak plików .safetensors. Szukaj w mlx-community.")
            case .unsupported(let type): String(localized: "Typ modelu „\(type)” nie jest obsługiwany przez MLX Swift.")
            case .noConfig: String(localized: "Model nie ma pliku config.json.")
            case .damaged(let file): String(localized: "Plik „\(file)” przyszedł uszkodzony — suma kontrolna się nie zgadza. Spróbuj pobrać jeszcze raz.")
            }
        }
    }

    /// Accepts "org/name" or a huggingface.co link.
    static func repo(from input: String) -> String {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://huggingface.co/", "http://huggingface.co/", "huggingface.co/"] where text.hasPrefix(prefix) {
            text.removeFirst(prefix.count)
        }
        return text.split(separator: "/").prefix(2).joined(separator: "/")
    }

    /// Looks the model up before downloading: it must exist, be MLX (safetensors) and be of a
    /// type MLX Swift can run — so nobody downloads gigabytes that will never load.
    func check(_ input: String) async throws -> Candidate {
        let repo = Self.repo(from: input)
        guard repo.split(separator: "/").count == 2,
              let info = URL(string: "https://huggingface.co/api/models/\(repo)?blobs=true") else { throw CheckError.notFound }
        let (data, response) = try await URLSession.shared.data(from: info)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else { throw CheckError.notFound }
        // Top-level files only; what a model needs to load (weights, configs, tokenizer, template).
        let wanted = [".safetensors", ".json", ".jinja", ".model", ".txt", ".tiktoken"]
        var hashes: [String: String] = [:]
        let files = siblings.compactMap { sibling -> (String, Int64)? in
            guard let name = sibling["rfilename"] as? String, !name.contains("/"),
                  wanted.contains(where: { name.hasSuffix($0) }) else { return nil }
            if let sha = (sibling["lfs"] as? [String: Any])?["sha256"] as? String { hashes[name] = sha }
            return (name, (sibling["size"] as? NSNumber)?.int64Value ?? 0)
        }
        guard files.contains(where: { $0.0.hasSuffix(".safetensors") }) else { throw CheckError.notMLX }
        guard files.contains(where: { $0.0 == "config.json" }),
              let configURL = URL(string: "https://huggingface.co/\(repo)/resolve/main/config.json") else { throw CheckError.noConfig }
        let (configData, _) = try await URLSession.shared.data(from: configURL)
        let type = (try JSONSerialization.jsonObject(with: configData) as? [String: Any])?["model_type"] as? String ?? "?"
        guard await LLMTypeRegistry.shared.contains(type) else { throw CheckError.unsupported(type) }
        return Candidate(repo: repo, name: Self.folderName(repo), modelType: type,
                         bytes: files.reduce(0) { $0 + $1.1 }, files: files.map(\.0), hashes: hashes)
    }

    // MARK: - Installing

    /// A suggested model: checked and downloaded like any other.
    func download(_ suggestion: Suggestion) async {
        do {
            await install(try await check(suggestion.repo), name: suggestion.name)
        } catch {
            downloadError = error.localizedDescription
        }
    }

    /// One file after another into a `.part` file, renamed when complete — a cut connection
    /// never leaves a half file that looks finished. The metadata goes last, and `rescan` lists
    /// no folder without it, so a download cut off halfway is never offered as a model.
    func install(_ candidate: Candidate, name: String? = nil) async {
        guard download == nil else { return }
        let shown = name ?? candidate.name
        let folder = root.appending(path: Self.folderName(candidate.repo))
        download = Download(name: shown, fraction: 0)
        downloadError = nil
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var done: Int64 = 0
            let total = max(candidate.bytes, 1)
            for file in candidate.files {
                let target = folder.appending(path: file)
                if FileManager.default.fileExists(atPath: target.path) {
                    done += Uninstaller.size(of: target)
                    continue
                }
                guard let source = URL(string: "https://huggingface.co/\(candidate.repo)/resolve/main/\(file)") else { continue }
                let base = done
                let temporary = try await Self.fetch(source) { [weak self] bytes in
                    Task { @MainActor in
                        self?.download?.fraction = min(0.99, Double(base + bytes) / Double(total))
                    }
                }
                // A file that came in damaged or was swapped on the way never becomes part of the model.
                if let expected = candidate.hashes[file] {
                    let actual = try await Task.detached { try Self.sha256(of: temporary) }.value
                    guard actual == expected else {
                        try? FileManager.default.removeItem(at: temporary)
                        throw CheckError.damaged(file)
                    }
                }
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: temporary, to: target)
                done += Uninstaller.size(of: target)
            }
            try writeMetadata(name: shown, repo: candidate.repo, in: folder)
            download = nil
            rescan()
            selectedID = folder.lastPathComponent
            await load()
        } catch {
            download = nil
            downloadError = String(localized: "Nie udało się pobrać modelu: \(error.localizedDescription)")
        }
    }

    /// A model already on disk (MLX format), copied in — so it leaves with VoiceAI's folder.
    func addFolder(_ source: URL) async {
        guard download == nil else { return }
        downloadError = nil
        do {
            let files = try FileManager.default.contentsOfDirectory(atPath: source.path)
            guard files.contains(where: { $0.hasSuffix(".safetensors") }) else { throw CheckError.notMLX }
            guard files.contains("config.json") else { throw CheckError.noConfig }
            let config = try Data(contentsOf: source.appending(path: "config.json"))
            let type = (try JSONSerialization.jsonObject(with: config) as? [String: Any])?["model_type"] as? String ?? "?"
            guard await LLMTypeRegistry.shared.contains(type) else { throw CheckError.unsupported(type) }
            var folder = root.appending(path: source.lastPathComponent)
            var number = 2
            while FileManager.default.fileExists(atPath: folder.path) {
                folder = root.appending(path: "\(source.lastPathComponent) \(number)")
                number += 1
            }
            download = Download(name: source.lastPathComponent, fraction: nil)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let target = folder
            try await Task.detached { try FileManager.default.copyItem(at: source, to: target) }.value
            try writeMetadata(name: source.lastPathComponent, repo: nil, in: folder)
            download = nil
            rescan()
            selectedID = folder.lastPathComponent
            await load()
        } catch {
            download = nil
            downloadError = error.localizedDescription
        }
    }

    private func writeMetadata(name: String, repo: String?, in folder: URL) throws {
        var meta = ["name": name]
        if let repo { meta["repo"] = repo }
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appending(path: Self.metadataFile))
    }

    /// A plain download task, its byte count read twice a second. Neither the async
    /// `download(from:delegate:)` delegate nor KVO on `task.progress` reported bytes while the
    /// 2.6 GB came in — the bar sat at 0% both times (measured 2026-09-29).
    private static func fetch(_ url: URL, progress: @escaping @Sendable (Int64) -> Void) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let task = URLSession.shared.downloadTask(with: url) { file, response, error in
                if let error { return continuation.resume(throwing: error) }
                guard let file, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    return continuation.resume(throwing: URLError(.badServerResponse))
                }
                // The system deletes its temporary file when this returns — move it out first.
                let part = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".part")
                do {
                    try FileManager.default.moveItem(at: file, to: part)
                    continuation.resume(returning: part)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            task.resume()
            Task.detached {
                while task.state == .running {
                    progress(task.countOfBytesReceived)
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        }
    }

    /// Read in 8 MB pieces — the weights are gigabytes.
    nonisolated static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let data = try handle.read(upToCount: 8 << 20), !data.isEmpty { hasher.update(data: data) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Loading

    func load() async {
        guard let entry = selected else { state = .absent; return }
        if container != nil, loadedID == entry.id { state = .ready; return }
        container = nil
        state = .loading
        // MLX keeps freed GPU buffers for reuse; left unlimited that cache grew past the model
        // itself. A small one costs no speed on sentence-sized jobs.
        Memory.cacheLimit = 32 * 1024 * 1024
        do {
            container = try await LLMModelFactory.shared.loadContainer(from: entry.folder, using: TransformersLoader())
            loadedID = entry.id
            state = .ready
        } catch {
            state = .failed(String(localized: "Nie udało się wczytać modelu: \(error.localizedDescription)"))
        }
    }

    /// Frees the memory without touching the files.
    func unload() {
        container = nil
        loadedID = nil
        idle?.invalidate()
        state = selected == nil ? .absent : .downloaded
    }

    /// To the Trash, like everything VoiceAI removes.
    func remove(_ entry: Entry) {
        if loadedID == entry.id { unload() }
        try? FileManager.default.trashItem(at: entry.folder, resultingItemURL: nil)
        rescan()
        if !installed.contains(where: { $0.id == selectedID }), let first = installed.first { selectedID = first.id }
    }

    // MARK: - Tasks

    /// Translates into the language with this code ("en", "pl", …). Plain translation of text
    /// already tidied: asked to drop fillers in the same pass, the model also dropped whole
    /// clauses and changed "kup" into "I bought" (2026-09-29).
    func translate(_ text: String, to language: String) async throws -> String {
        let target = Locale(identifier: "en").localizedString(forLanguageCode: language) ?? language
        return try await ask("Translate the user's text into natural \(target). Keep names as they are. "
                             + "Reply with the translation only.", text)
    }

    /// Removes fillers, repeats and slips, fixes punctuation — without changing the meaning.
    /// The Polish wording is the one measured on 2026-09-29; other languages get the same in English.
    func tidy(_ text: String, language: String) async throws -> String {
        let instructions = language == "pl"
            ? "Jesteś korektorem tekstu dyktowanego po polsku. Usuń wtrącenia (yyy, eee, znaczy), powtórzone słowa "
                + "i przejęzyczenia, popraw literówki, polskie znaki i interpunkcję. Nie zmieniaj sensu, stylu ani nazw "
                + "własnych, niczego nie dodawaj. Odpowiedz wyłącznie poprawionym tekstem."
            : "You correct dictated text. Remove fillers (uh, um), repeated words and slips, fix typos and punctuation. "
                + "Do not change the meaning, style or names, add nothing. Reply with the corrected text only."
        return try await ask(instructions, text)
    }

    /// Reasoning blocks that some models (Qwen 3 and others) write before the answer.
    private static let thinking = try! NSRegularExpression(pattern: "<think>[\\s\\S]*?</think>")

    private func ask(_ instructions: String, _ text: String) async throws -> String {
        if container == nil || loadedID != selected?.id { await load() }
        guard let container else { throw TextModelError.notReady }
        // Greedy (temperature 0): the same dictation always gives the same text. Thinking off:
        // it cost Gemma 4 10 s a sentence in Ollama; templates that know the switch honour it.
        let session = ChatSession(container, instructions: instructions,
                                  generateParameters: GenerateParameters(maxTokens: 1024, temperature: 0),
                                  additionalContext: ["enable_thinking": false])
        var answer = try await session.respond(to: text)
        answer = Self.thinking.stringByReplacingMatches(in: answer, range: NSRange(answer.startIndex..., in: answer),
                                                        withTemplate: "")
        Memory.clearCache()
        idle?.invalidate()
        idle = Timer.scheduledTimer(withTimeInterval: Self.idleSeconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.unload() }
        }
        return answer.trimmingCharacters(in: .whitespacesAndNewlines)
    }

}

enum TextModelError: LocalizedError {
    case notReady
    var errorDescription: String? { String(localized: "Model językowy nie jest pobrany.") }
}

/// swift-transformers' tokenizer behind mlx-swift-lm's protocol — the adapter the library's
/// Hugging Face macros generate, written out so no macro package is needed.
private struct TransformersLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await Tokenizers.AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) { self.upstream = upstream }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? { upstream.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { upstream.convertIdToToken(id) }
    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(messages: [[String: any Sendable]], tools: [[String: any Sendable]]?,
                           additionalContext: [String: any Sendable]?) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
