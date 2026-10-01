import AVFoundation
import WhisperKit

/// Whisper large-v3-turbo on this Mac, about 1.6 s per pass on an M4. The model (~1.5 GB)
/// downloads once into Application Support; after that the app starts without the network.
final class Transcriber {
    static let variant = "openai_whisper-large-v3-v20240930_turbo"
    private static let repo = "argmaxinc/whisperkit-coreml"

    private let base: URL
    private var whisper: WhisperKit?

    init(directory: URL) {
        base = directory.appending(path: "Modele")
    }

    private var localModel: URL {
        base.appending(path: "models/\(Self.repo)/\(Self.variant)")
    }


    /// Loads the model from disk; when it is missing or does not load — a first download cut
    /// off halfway leaves folders that look complete — it is downloaded again from scratch.
    /// `progress` gets 0…1 while downloading and nil once loading starts.
    func load(progress: @escaping (Double?) -> Void) async throws {
        let folder = localModel
        if FileManager.default.fileExists(atPath: folder.appending(path: "TextDecoder.mlmodelc").path) {
            progress(nil)
            do {
                try await open(folder)
                return
            } catch {
                log.error("Whisper model on disk does not load, downloading again: \(error.localizedDescription, privacy: .public)")
                try? FileManager.default.removeItem(at: folder)
            }
        }
        let downloaded = try await WhisperKit.download(variant: Self.variant, downloadBase: base, from: Self.repo) {
            progress($0.fractionCompleted)
        }
        progress(nil)
        try await open(downloaded)
    }

    private func open(_ folder: URL) async throws {
        let config = WhisperKitConfig(modelFolder: folder.path, tokenizerFolder: base,
                                      verbose: false, logLevel: .error, load: true, download: false)
        whisper = try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float], vocabulary: Vocabulary) async throws -> String {
        guard let whisper else { return "" }
        let prompt = vocabulary.prompt
        let promptTokens = prompt.isEmpty ? nil : whisper.tokenizer?.encode(text: prompt)
        var options = DecodingOptions(
            language: vocabulary.jezyk,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )
        // One retry at most, not WhisperKit's five: each retry decodes the whole text again at a
        // higher temperature, and 2 of 12 dictations (2026-10-01) went through all five — 7–8 s
        // instead of ~1.5 s after the key was released. Files keep the default, nobody waits on them.
        options.temperatureFallbackCount = 1
        let text = try await text(of: samples, options: options, whisper: whisper)
        guard Language.wrongScript(text, language: vocabulary.jezyk) else { return text }
        // A Latin-script language came back in another alphabet. Whisper's retries sample at
        // rising temperature and can drift out of the forced language; one greedy pass without
        // the word-list hint instead.
        var greedy = options
        greedy.promptTokens = nil
        greedy.temperature = 0
        greedy.temperatureFallbackCount = 0
        let again = try await self.text(of: samples, options: greedy, whisper: whisper)
        log.notice("Wrong alphabet for \(vocabulary.jezyk, privacy: .public), second pass \(Language.wrongScript(again, language: vocabulary.jezyk) ? "still wrong" : "fixed", privacy: .public)")
        return again.isEmpty ? text : again
    }

    private func text(of samples: [Float], options: DecodingOptions, whisper: WhisperKit) async throws -> String {
        let results = try await whisper.transcribe(audioArray: samples, decodeOptions: options)
        // TEMPORARY timing (speed work 2026-10-01) — where Whisper's ~1.7 s goes; remove with this block.
        for t in results.map(\.timings) {
            log.notice("WHISPER audio \(t.inputAudioSeconds, format: .fixed(precision: 1), privacy: .public) s | mel \(t.logmels, format: .fixed(precision: 2), privacy: .public) | encoder \(t.encoding, format: .fixed(precision: 2), privacy: .public) (\(Int(t.totalEncodingRuns), privacy: .public)×) | decoder \(t.decodingLoop, format: .fixed(precision: 2), privacy: .public) (\(Int(t.totalDecodingLoops), privacy: .public) steps, prompt \(options.promptTokens?.count ?? 0, privacy: .public) tokens, fallbacks \(Int(t.totalDecodingFallbacks), privacy: .public), windows \(Int(t.totalDecodingWindows), privacy: .public)) | first token \(t.firstTokenTime - t.pipelineStart, format: .fixed(precision: 2), privacy: .public) | full \(t.fullPipeline, format: .fixed(precision: 2), privacy: .public)")
        }
        return results.map(\.text).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A whole audio or video file. Subtitles need the timestamps that the vocabulary hint
    /// switches off (4 segments without it, 1 with it — 2026-09-29), so this pass runs without
    /// the hint and the vocabulary only swaps words afterwards. `progress` gets 0…1.
    /// The sound is read and recognised ten minutes at a time, cut at the quietest moment near
    /// the boundary, so a two-hour film does not sit in memory whole (≈460 MB of samples).
    func transcribe(file: URL, vocabulary: Vocabulary, progress: @escaping (Double) -> Void) async throws -> FileTranscript {
        guard let whisper else { throw FileError.modelNotReady }
        let options = DecodingOptions(
            language: vocabulary.jezyk,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: false,
            wordTimestamps: true,
            chunkingStrategy: .vad
        )
        let total = max(1, try await AVURLAsset(url: file).load(.duration).seconds)
        var segments: [(start: Double, end: Double, text: String)] = []
        var words: [FileTranscript.Word] = []
        var heardAny = false
        try await Self.pieces(of: file) { piece, offset in
            heardAny = true
            let length = Double(piece.count) / Recorder.sampleRate
            // WhisperKit counts finished pieces in its own Progress; read it a few times a second.
            let watcher = Task {
                while !Task.isCancelled {
                    let inPiece = min(1, max(0, whisper.progress.fractionCompleted))
                    progress(min(1, (offset + inPiece * length) / total))
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { watcher.cancel() }
            let results = try await whisper.transcribe(audioArray: piece, decodeOptions: options)
            for segment in results.flatMap(\.segments).sorted(by: { $0.start < $1.start }) {
                segments.append((offset + Double(segment.start), offset + Double(segment.end), segment.text))
                words += (segment.words ?? []).map {
                    FileTranscript.Word(text: $0.word, start: offset + Double($0.start), end: offset + Double($0.end))
                }
            }
        }
        guard heardAny else { throw FileError.noAudio }
        if !words.isEmpty {
            return FileTranscript(lines: FileTranscript.cues(from: words) { vocabulary.apply(to: $0) })
        }
        // No word timings came back: whole segments, as before.
        let lines = segments.compactMap { segment -> FileTranscript.Line? in
            let text = vocabulary.apply(to: FileTranscript.clean(segment.text))
            return text.isEmpty ? nil : FileTranscript.Line(start: segment.start, end: segment.end, text: FileTranscript.wrapped(text))
        }
        return FileTranscript(lines: lines)
    }

    /// Ten minutes of sound per piece.
    static let pieceSamples = Int(Recorder.sampleRate * 600)

    /// Hands the file's sound to `body` a piece at a time, with each piece's start in seconds.
    /// A piece ends at the quietest moment of its last 15 s, so no word is cut in half.
    static func pieces(of file: URL, _ body: ([Float], Double) async throws -> Void) async throws {
        let (reader, output) = try await Self.reader(for: file)
        var buffer: [Float] = []
        var offset = 0.0
        while let chunk = Self.next(output) {
            buffer += chunk
            if buffer.count >= pieceSamples {
                let cut = FileTranscript.quietestCut(in: buffer, searchLast: Int(Recorder.sampleRate * 15),
                                                     window: Int(Recorder.sampleRate / 10))
                try await body(Array(buffer[..<cut]), offset)
                offset += Double(cut) / Recorder.sampleRate
                buffer.removeFirst(cut)
            }
        }
        if reader.status == .failed { throw reader.error ?? FileError.noAudio }
        if !buffer.isEmpty { try await body(buffer, offset) }
    }

    enum FileError: LocalizedError {
        case modelNotReady, noAudio, noSpeech

        var errorDescription: String? {
            switch self {
            case .modelNotReady: String(localized: "Model Whisper nie jest jeszcze wczytany.")
            case .noAudio: String(localized: "W pliku nie ma ścieżki dźwiękowej.")
            case .noSpeech: String(localized: "Whisper nie usłyszał w pliku mowy.")
            }
        }
    }

    /// The file's sound as 16 kHz mono floats — what Whisper reads. AVAssetReader does the
    /// resampling and mixes the channels down, and it opens video as well as audio.
    private static func reader(for file: URL) async throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let asset = AVURLAsset(url: file)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw FileError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? FileError.noAudio }
        return (reader, output)
    }

    /// The next block of samples, nil at the end.
    private static func next(_ output: AVAssetReaderTrackOutput) -> [Float]? {
        while let buffer = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { raw in
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
            }
            return chunk
        }
        return nil
    }
}

/// What the settings show for Whisper: downloading (with progress), loading, ready or failed —
/// and the button that downloads it again. Until 0.1.42 the row had only a size and a Finder
/// button, so a missing or broken model could not be fetched from the app at all.
@MainActor
final class WhisperStatus: ObservableObject {
    static let shared = WhisperStatus()

    enum State: Equatable {
        case downloading(Double?), ready, failed(String)
    }

    @Published var state = State.downloading(nil)
    /// Set by the app delegate: loads the model, downloading it first when it is not on disk.
    var load: () -> Void = {}
}
