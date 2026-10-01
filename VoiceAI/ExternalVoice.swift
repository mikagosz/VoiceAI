import AVFoundation

/// Runs the program behind "Inny głos (polecenie)" (see `VoiceCommand`) and plays what it makes.
/// Sentences are asked for one by one on a background queue and queued for playback as they
/// arrive, so the first sentence plays while the next is still being made. The three sliders
/// still apply: tempo and pitch through a time-pitch unit, loudness as gain.
final class ExternalVoice: ObservableObject {
    enum State { case off, loading, ready }

    /// How long one sentence may take, model loading included, before the program is restarted.
    private static let replyTimeout: TimeInterval = 120

    private let queue = DispatchQueue(label: "com.mikagosz.VoiceAI.externalVoice")
    // Owned by `queue`.
    private var process: Process?
    private var input: FileHandle?
    private var lines: Lines?
    private var runningPath: String?

    // Owned by the main thread.
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let timePitch = AVAudioUnitTimePitch()
    private let gain = AVAudioUnitEQ(numberOfBands: 0)
    private var connected: AVAudioFormat?
    private(set) var speaking = false
    /// Shown in Settings: a slow model takes half a minute to load, "Posłuchaj" waits for it.
    @Published private(set) var state = State.off

    /// Bumped by `stop`; work of an older reading is dropped wherever it is.
    private let generation = Generation()

    init() {
        // A program that died would otherwise kill VoiceAI on the next write to its input.
        signal(SIGPIPE, SIG_IGN)
        for node in [player, timePitch, gain] as [AVAudioNode] { engine.attach(node) }
    }

    /// Starts the program ahead of the first reply and has it read one throwaway word, so the
    /// model is loaded — and its first, slowest sentence made — before anything is to be heard.
    /// English, the language a speech engine is most likely to know.
    func warmUp(_ command: String) {
        queue.async {
            if let process = self.process, process.isRunning, self.runningPath == command { return }
            DispatchQueue.main.async { self.state = .loading }
            if case .audio(let url) = self.ask(VoiceCommand.request(language: "en", text: "Ready."), command: command) {
                try? FileManager.default.removeItem(at: url)
            }
            let ready = self.process?.isRunning == true
            DispatchQueue.main.async { self.state = ready ? .ready : .off }
        }
    }

    /// Reads `text`; whatever the program fails to read goes to `fallback` (the system voice).
    func speak(_ text: String, language: String, command: String, fallback: @escaping (String) -> Void) {
        stop()
        let sentences = VoiceCommand.sentences(text)
        guard !sentences.isEmpty else { return }
        let reading = generation.current
        speaking = true
        queue.async {
            for (index, sentence) in sentences.enumerated() {
                guard self.generation.current == reading else { return }
                switch self.ask(VoiceCommand.request(language: language, text: sentence), command: command) {
                case .audio(let url):
                    let buffer = Self.load(url)
                    try? FileManager.default.removeItem(at: url)
                    guard let buffer else {
                        log.error("Voice command: unreadable audio file")
                        return self.giveUp(sentences[index...], reading, fallback)
                    }
                    let last = index == sentences.count - 1
                    DispatchQueue.main.async {
                        guard self.generation.current == reading else { return }
                        self.play(buffer, last: last, reading: reading)
                    }
                case .failure(let reason):
                    log.error("Voice command failed: \(reason, privacy: .private)")
                    return self.giveUp(sentences[index...], reading, fallback)
                }
            }
        }
    }

    func stop() {
        generation.bump()
        if player.isPlaying { player.stop() }
        speaking = false
    }

    private func giveUp(_ rest: ArraySlice<String>, _ reading: Int, _ fallback: @escaping (String) -> Void) {
        DispatchQueue.main.async {
            guard self.generation.current == reading else { return }
            // Whatever is already queued plays first; the system voice then reads the rest.
            let text = rest.joined(separator: " ")
            if self.player.isPlaying {
                self.player.scheduleBuffer(AVAudioPCMBuffer(pcmFormat: self.connected!, frameCapacity: 1)!) {
                    DispatchQueue.main.async {
                        guard self.generation.current == reading else { return }
                        self.speaking = false
                        fallback(text)
                    }
                }
            } else {
                self.speaking = false
                fallback(text)
            }
        }
    }

    // MARK: Playback (main thread)

    private func play(_ buffer: AVAudioPCMBuffer, last: Bool, reading: Int) {
        if connected != buffer.format || !engine.isRunning {
            engine.stop()
            engine.connect(player, to: timePitch, format: buffer.format)
            engine.connect(timePitch, to: gain, format: buffer.format)
            engine.connect(gain, to: engine.mainMixerNode, format: buffer.format)
            connected = buffer.format
            do { try engine.start() } catch {
                log.error("Voice command: audio engine did not start: \(error.localizedDescription, privacy: .public)")
                speaking = false
                return
            }
        }
        // The sliders store AVSpeechUtterance values; here they become ratios to normal.
        timePitch.rate = SpeechTuning.rate / Float(SpeechTuning.normalRate)
        timePitch.pitch = 1200 * log2(SpeechTuning.pitch / Float(SpeechTuning.normalPitch))
        gain.globalGain = 20 * log10(SpeechTuning.volume / Float(SpeechTuning.normalVolume))
        player.scheduleBuffer(buffer) {
            guard last else { return }
            DispatchQueue.main.async {
                if self.generation.current == reading { self.speaking = false }
            }
        }
        if !player.isPlaying { player.play() }
    }

    private static func load(_ url: URL) -> AVAudioPCMBuffer? {
        guard let file = try? AVAudioFile(forReading: url),
              let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)),
              (try? file.read(into: buffer)) != nil else { return nil }
        return buffer
    }

    // MARK: The program (queue)

    private func ask(_ request: String, command: String) -> VoiceCommand.Reply {
        guard ensureRunning(command), let input, let lines else { return .failure("the program did not start") }
        let start = Date()
        do { try input.write(contentsOf: Data(request.utf8)) } catch {
            shutDown()
            return .failure("the program closed its input")
        }
        guard let line = lines.next(timeout: Self.replyTimeout) else {
            shutDown()
            return .failure("no answer from the program")
        }
        log.info("Voice command answered in \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public) s")
        return VoiceCommand.parse(line)
    }

    private func ensureRunning(_ command: String) -> Bool {
        if let process, process.isRunning, runningPath == command { return true }
        shutDown()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        let toProgram = Pipe(), fromProgram = Pipe()
        process.standardInput = toProgram
        process.standardOutput = fromProgram
        process.standardError = FileHandle.nullDevice
        let lines = Lines()
        fromProgram.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; lines.close() } else { lines.append(data) }
        }
        do { try process.run() } catch {
            log.error("Voice command did not start: \(error.localizedDescription, privacy: .public)")
            return false
        }
        log.info("Voice command started")
        self.process = process
        self.input = toProgram.fileHandleForWriting
        self.lines = lines
        self.runningPath = command
        return true
    }

    private func shutDown() {
        if process != nil { DispatchQueue.main.async { self.state = .off } }
        if let process, process.isRunning { process.terminate() }
        try? input?.close()
        lines?.close()
        process = nil
        input = nil
        lines = nil
        runningPath = nil
    }
}

/// Lines coming from the program, waited for with a timeout.
private final class Lines {
    private let lock = NSLock()
    private let ready = DispatchSemaphore(value: 0)
    private var pending = Data()
    private var closed = false

    func append(_ data: Data) {
        lock.lock()
        pending.append(data)
        lock.unlock()
        let count = data.filter { $0 == UInt8(ascii: "\n") }.count
        for _ in 0..<count { ready.signal() }
    }

    func close() {
        lock.lock()
        let wasOpen = !closed
        closed = true
        lock.unlock()
        if wasOpen { ready.signal() }
    }

    func next(timeout: TimeInterval) -> String? {
        guard ready.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock()
        defer { lock.unlock() }
        guard let end = pending.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let line = pending[pending.startIndex..<end]
        pending.removeSubrange(pending.startIndex...end)
        return String(decoding: line, as: UTF8.self)
    }
}

private final class Generation {
    private let lock = NSLock()
    private var value = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func bump() {
        lock.lock()
        value += 1
        lock.unlock()
    }
}
