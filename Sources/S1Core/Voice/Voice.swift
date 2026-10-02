import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text via macOS 26's SpeechAnalyzer/SpeechTranscriber —
/// no cloud, 60+ locales, Indonesian included.
@available(macOS 26, *)
public struct SpeechToText: Sendable {
    public var locale: Locale

    public init(locale: Locale = Locale(identifier: "id-ID")) {
        self.locale = locale
    }

    /// Locales with a downloaded speech model on this machine.
    public static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// Transcribe an audio file end-to-end (the testable path — no mic needed).
    /// Prefers SpeechAnalyzer (macOS 26); falls back to SFSpeechRecognizer
    /// when the new speech assets aren't installed on the machine.
    public func transcribe(file url: URL) async throws -> String {
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            return try await transcribeAnalyzer(file: url)
        }
        return try await transcribeLegacy(file: url)
    }

    /// SFSpeechRecognizer path — works on macOS 15+, uses whichever speech
    /// assets the system already has (en-US ships with Dictation).
    private func transcribeLegacy(file url: URL) async throws -> String {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw S1Error.aborted("no speech recognizer for \(locale.identifier)")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Error>) in
            var resumed = false
            rec.recognitionTask(with: req) { result, error in
                guard !resumed else { return }
                if let r = result, r.isFinal {
                    resumed = true
                    c.resume(returning: r.bestTranscription.formattedString)
                } else if let error {
                    resumed = true
                    c.resume(throwing: error)
                }
            }
        }
    }

    /// SpeechAnalyzer/SpeechTranscriber path (macOS 26 assets required).
    private func transcribeAnalyzer(file url: URL) async throws -> String {
        let transcriber = SpeechTranscriber(locale: locale,
                                          transcriptionOptions: [],
                                          reportingOptions: [],
                                          attributeOptions: [])
        guard SpeechTranscriber.isAvailable else {
            throw S1Error.aborted("SpeechTranscriber not available on this system")
        }
        // Ensure the locale's assets are installed (downloads on demand).
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        guard let file = try? AVAudioFile(forReading: url) else {
            throw S1Error.aborted("cannot open audio file \(url.path)")
        }
        let collected = TextCollector()
        // Analyzer finishes when the file ends; results stream concurrently.
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for try await result in transcriber.results {
                    await collected.append(String(result.text.characters))
                }
            }
            group.addTask {
                if let last = try await analyzer.analyzeSequence(from: file) {
                    try await analyzer.finalizeAndFinish(through: last)
                }
            }
            try await group.waitForAll()
        }
        return await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Live microphone transcription until `stop` flips true or `maxSeconds`
    /// elapses. Requires mic permission + an input device. Uses whichever
    /// engine the system supports (legacy recognizer if Analyzer assets are
    /// absent — the honest fallback, same on-device privacy).
    public func transcribeMic(maxSeconds: Double = 30) async throws -> String {
        // No input device at all → clean error. Without this, installTap throws
        // an NSException (uncatchable from Swift) and kills the whole process —
        // which would take down the always-on daemon with it.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw S1Error.aborted("no microphone input available")
        }
        if #available(macOS 26, *), SpeechTranscriber.isAvailable {
            return try await transcribeMicAnalyzer(maxSeconds: maxSeconds)
        }
        return try await transcribeMicLegacy(maxSeconds: maxSeconds)
    }

    private func transcribeMicLegacy(maxSeconds: Double) async throws -> String {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw S1Error.aborted("no speech recognizer for \(locale.identifier)")
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw S1Error.aborted("no microphone input available")
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let collected = TextCollector()
        let finished = FinishedFlag()
        let task = rec.recognitionTask(with: req) { result, error in
            if let r = result, r.isFinal {
                let text = r.bestTranscription.formattedString
                Task { await collected.append(text) }
                finished.set()
            }
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            req.append(buffer)
        }
        engine.prepare()
        try engine.start()
        try await Task.sleep(nanoseconds: UInt64(maxSeconds * 1e9))
        input.removeTap(onBus: 0)
        engine.stop()
        req.endAudio()
        // Give the final result a moment to arrive, then settle.
        for _ in 0 ..< 20 where !finished.get { try await Task.sleep(nanoseconds: 100_000_000) }
        task.finish()
        return await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func transcribeMicAnalyzer(maxSeconds: Double) async throws -> String {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw S1Error.aborted("no microphone input available")
        }
        let transcriber = SpeechTranscriber(locale: locale,
                                          transcriptionOptions: [],
                                          reportingOptions: [.volatileResults],
                                          attributeOptions: [])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            try await request.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        engine.prepare()
        try engine.start()

        let collected = TextCollector()
        let resultsTask = Task {
            for try await result in transcriber.results {
                if result.isFinal {
                    await collected.append(String(result.text.characters))
                }
            }
        }
        let inputTask = Task { try await analyzer.start(inputSequence: stream) }
        try await Task.sleep(nanoseconds: UInt64(maxSeconds * 1e9))
        continuation.finish()
        input.removeTap(onBus: 0)
        engine.stop()
        try await inputTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        try await resultsTask.value
        return await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Mutable string shared safely between the results task and the analyzer.
private actor TextCollector {
    var value = ""
    func append(_ s: String) { value += s }
}

/// One-bit flag settable from a non-isolated callback.
private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var get: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func set() { lock.lock(); done = true; lock.unlock() }
}

/// On-device text-to-speech — AVSpeechSynthesizer, works fully offline.
public final class Speaker: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    let synth = AVSpeechSynthesizer()
    var finished: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        synth.delegate = self
    }

    /// Available on-device voices for a BCP-47 prefix ("id", "en").
    public static func voices(matching prefix: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
    }

    /// Speak and return after the utterance finishes.
    public func say(_ text: String, language: String = "id-ID") async {
        let u = AVSpeechUtterance(string: text)
        u.voice = AVSpeechSynthesisVoice(language: language)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            finished = c
            synth.speak(u)
        }
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        finished?.resume()
        finished = nil
    }
}
