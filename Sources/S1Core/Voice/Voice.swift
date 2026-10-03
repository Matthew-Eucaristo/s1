import Foundation
import Speech
import AVFoundation

/// On-device speech-to-text via macOS 26's SpeechAnalyzer/SpeechTranscriber —
/// no cloud, 60+ locales, Indonesian included.
@available(macOS 26, *)
public struct SpeechToText: Sendable {
    public var locale: Locale
    /// Phrases the recognizer should bias toward (app names, jargon) —
    /// Apple's "contextual strings" on both the legacy and Analyzer paths.
    public var vocabulary: [String]

    public init(locale: Locale = Locale(identifier: "id-ID"), vocabulary: [String] = []) {
        self.locale = locale
        self.vocabulary = vocabulary
    }

    /// The AnalysisContext carrying our vocabulary — setContext REPLACES the
    /// analyzer's context, so build the whole thing each time.
    private var analysisContext: AnalysisContext? {
        guard !vocabulary.isEmpty else { return nil }
        let ctx = AnalysisContext()
        ctx.contextualStrings = [
            AnalysisContext.ContextualStringsTag(rawValue: "vocabulary"): vocabulary
        ]
        return ctx
    }

    /// Locales with a downloaded speech model on this machine.
    public static func installedLocales() async -> [Locale] {
        await SpeechTranscriber.installedLocales
    }

    /// Transcribe an audio file end-to-end (the testable path — no mic needed).
    /// Prefers SpeechAnalyzer (macOS 26); falls back to SFSpeechRecognizer
    /// when the new speech assets aren't installed on the machine.
    public func transcribe(file url: URL) async throws -> String {
        if SpeechTranscriber.isAvailable {
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
        if !vocabulary.isEmpty { req.contextualStrings = vocabulary }
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
        if let ctx = analysisContext { try await analyzer.setContext(ctx) }
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
        if SpeechTranscriber.isAvailable {
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
        if !vocabulary.isEmpty { req.contextualStrings = vocabulary }
        let collected = Locked<String>("")
        let failure = Locked<Error?>(nil)
        let finished = FinishedFlag()
        let task = rec.recognitionTask(with: req) { result, error in
            if let r = result, r.isFinal {
                collected.value = r.bestTranscription.formattedString
                finished.set()
            } else if let error {
                failure.value = error
                finished.set()
            }
        }
        var tapInstalled = false
        // Cancellation (serve sleep / kill switch) must still drop the tap and
        // stop the engine — without defer the mic would stay live after the
        // task is gone.
        defer {
            if tapInstalled { input.removeTap(onBus: 0) }
            engine.stop()
            req.endAudio()
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            req.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        // Listen for the full turn — but bail the moment recognition fails
        // instead of sleeping through a dead recognizer.
        var waited = 0.0
        while waited < maxSeconds, failure.value == nil {
            try await Task.sleep(nanoseconds: 200_000_000)
            waited += 0.2
        }
        // Give the final result a moment to arrive, then settle.
        for _ in 0 ..< 20 where !finished.get { try await Task.sleep(nanoseconds: 100_000_000) }
        task.finish()
        // finish() delivers the final result asynchronously — give that
        // callback a beat too, or the last words get read as silence.
        for _ in 0 ..< 10 where !finished.get { try await Task.sleep(nanoseconds: 100_000_000) }
        if let error = failure.value { throw error }
        return collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
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
        if let ctx = analysisContext { try await analyzer.setContext(ctx) }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        var tapInstalled = false
        // Same cancellation rule as the legacy path: the tap and engine must
        // come down even when the task is cancelled mid-listen.
        defer {
            if tapInstalled { input.removeTap(onBus: 0) }
            engine.stop()
            continuation.finish()
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            continuation.yield(AnalyzerInput(buffer: buffer))
        }
        tapInstalled = true
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
        try await inputTask.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        // The results stream terminates once the analyzer finishes — awaiting
        // it is what lands the final transcript chunk.
        try await resultsTask.value
        return await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Lock-protected cell for values written from non-isolated callbacks and
/// read on the calling task — replaces fire-and-forget `Task { await … }`
/// appends that could lose the final transcript.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ v: Value) { stored = v }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// Mutable string shared safely between the results task and the analyzer.
/// Segments arrive per-utterance — joining without a space welds words
/// ("buka" + "TextEdit" → "bukaTextEdit") and breaks the intent parser.
private actor TextCollector {
    var value = ""
    func append(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        value += (value.isEmpty ? "" : " ") + t
    }
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
    private let lock = NSLock()
    var finished: CheckedContinuation<Void, Never>?

    public override init() {
        super.init()
        synth.delegate = self
    }

    /// Available on-device voices for a BCP-47 prefix ("id", "en").
    public static func voices(matching prefix: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
    }

    /// Speak and return after the utterance finishes — bounded by `timeout`
    /// so a wedged synthesizer can't pin the caller (UI status, serve loop).
    public func say(_ text: String, language: String = "id-ID", timeout: Double = 30) async {
        // One utterance at a time: a second say() would overwrite `finished`
        // and leak the first caller's continuation — settle it first.
        self.stop()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                let u = AVSpeechUtterance(string: text)
                u.voice = AVSpeechSynthesisVoice(language: language)
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    self.lock.lock()
                    self.finished = c
                    self.lock.unlock()
                    self.synth.speak(u)
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            }
            _ = await group.next()
            group.cancelAll()
            self.stop()
        }
    }

    /// Cut speech immediately; also unblocks a pending `say` continuation.
    public func stop() {
        synth.stopSpeaking(at: .immediate)
        lock.lock()
        finished?.resume()
        finished = nil
        lock.unlock()
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        lock.lock()
        finished?.resume()
        finished = nil
        lock.unlock()
    }
}
