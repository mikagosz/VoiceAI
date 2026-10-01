import AVFoundation

/// Records the default microphone into 16 kHz mono Float samples — the format Whisper takes.
/// The engine runs only between start() and stop(), so the orange mic dot shows only then.
final class Recorder {
    static let sampleRate = 16_000.0

    /// A new engine for every recording. One engine kept for the app's lifetime remembers the
    /// microphone format from the first time it looked; after the input changes (another mic, or a
    /// Bluetooth headset switching between 24 and 48 kHz) the tap gets the old format, AVFoundation
    /// throws an Objective-C exception Swift cannot catch, and the key stays dead until a restart.
    private var engine: AVAudioEngine?
    private let lock = NSLock()
    private var samples: [Float] = []
    private var lastLevel: Float = 0

    func start() throws {
        lock.withLock {
            samples = []
            lastLevel = 0
        }
        stopEngine()
        let engine = AVAudioEngine()
        self.engine = engine
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        // No input device at all: the format comes back empty, and a tap on it would throw.
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            self.engine = nil
            throw RecorderError.noMicrophone
        }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate,
                                            channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw RecorderError.noMicrophone
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            let capacity = AVAudioFrameCount(Double(buffer.frameLength) * Self.sampleRate / inFormat.sampleRate) + 1
            guard let self, let out = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: capacity) else { return }
            var fed = false
            converter.convert(to: out, error: nil) { _, status in
                if fed { status.pointee = .noDataNow; return nil }
                fed = true
                status.pointee = .haveData
                return buffer
            }
            guard let data = out.floatChannelData?[0] else { return }
            let chunk = Array(UnsafeBufferPointer(start: data, count: Int(out.frameLength)))
            let rms = chunk.isEmpty ? 0 : (chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count)).squareRoot()
            self.lock.withLock {
                self.samples.append(contentsOf: chunk)
                self.lastLevel = rms
            }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            stopEngine()
            throw error
        }
    }

    private func stopEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
    }

    /// Loudness (RMS) of the latest chunk from the microphone — for the level bar.
    var level: Float {
        lock.withLock { lastLevel }
    }

    /// Lifts a quiet recording to `loudness` (RMS); never makes it quieter. Samples are
    /// clipped at ±1, so a loud cough inside a whisper cannot wrap around.
    static func boosted(_ samples: [Float], to loudness: Float) -> [Float] {
        guard !samples.isEmpty else { return samples }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        guard rms > 0, rms < loudness else { return samples }
        let gain = loudness / rms
        return samples.map { min(1, max(-1, $0 * gain)) }
    }

    /// Stops the microphone and hands back everything recorded since start().
    func stop() -> [Float] {
        stopEngine()
        return lock.withLock { samples }
    }
}

enum RecorderError: LocalizedError {
    case noMicrophone
    var errorDescription: String? { String(localized: "Nie znaleziono mikrofonu.") }
}
