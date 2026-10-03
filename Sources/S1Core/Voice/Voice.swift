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
            // The callback isn't serialized — resume-at-most-once needs a
            // lock, or a final+error pair on two queues double-resumes (fatal).
            let once = OnceFlag()
            rec.recognitionTask(with: req) { result, error in
                if let r = result, r.isFinal {
                    if once.claim() { c.resume(returning: r.bestTranscription.formattedString) }
                } else if let error {
                    if once.claim() { c.resume(throwing: error) }
                }
            }
        }
    }

    /// Pre-warm the speech model so the first utterance isn't cold-slow —
    /// Apple's `SpeechAnalyzer.prepareToAnalyze` exists for exactly this.
    /// Best-effort: every failure is swallowed (the real path retries).
    public func warmup() async {
        guard SpeechTranscriber.isAvailable else { return }
        let t = SpeechTranscriber(locale: locale, transcriptionOptions: [],
                                  reportingOptions: [], attributeOptions: [])
        if let req = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await req.downloadAndInstall()
        }
        let analyzer = SpeechAnalyzer(modules: [t])
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { return }
        try? await analyzer.prepareToAnalyze(in: format)
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
            // First terminal callback wins — a trailing error must not erase
            // a final transcript that already landed.
            if let r = result, r.isFinal {
                if !finished.get {
                    collected.value = r.bestTranscription.formattedString
                    finished.set()
                }
            } else if let error {
                if !finished.get {
                    failure.value = error
                    finished.set()
                }
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
        // Listen for the full turn — but bail the moment recognition fails,
        // or a final transcript lands early (the recognizer decided the
        // utterance ended; burning the rest of the turn adds only silence).
        var waited = 0.0
        while waited < maxSeconds, failure.value == nil, !finished.get {
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
        // Apple doc pattern: feed the analyzer its best available format —
        // the mic's native rate may differ, and odd hardware (8 kHz devices)
        // would otherwise hand the analyzer a format it can't use.
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber])
        let converter = best.flatMap { AVAudioConverter(from: format, to: $0) }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        var tapInstalled = false
        // Same cancellation rule as the legacy path: the tap and engine must
        // come down even when the task is cancelled mid-listen.
        var resultsTask: Task<Void, Error>?
        var inputTask: Task<Void, Error>?
        defer {
            // Cancelled mid-listen → children must not outlive the scope.
            resultsTask?.cancel()
            inputTask?.cancel()
            if tapInstalled { input.removeTap(onBus: 0) }
            engine.stop()
            continuation.finish()
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            if let converter, let best, let out = Self.convert(buffer, from: format, to: best, using: converter) {
                continuation.yield(AnalyzerInput(buffer: out))
            } else {
                continuation.yield(AnalyzerInput(buffer: buffer))
            }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()

        let collected = TextCollector()
        resultsTask = Task {
            for try await result in transcriber.results {
                if result.isFinal {
                    await collected.append(String(result.text.characters))
                }
            }
        }
        inputTask = Task { try await analyzer.start(inputSequence: stream) }
        // End the turn on speech, not on the clock: once a final segment has
        // landed, a short grace catches trailing words, then the turn closes.
        // Burning the full maxSeconds after every command made every voice
        // turn feel frozen — the legacy path already exits on `isFinal`.
        var waited = 0.0
        while waited < maxSeconds {
            try await Task.sleep(nanoseconds: 150_000_000)
            waited += 0.15
            if await collected.hasContent, await collected.idleFor(0.9) { break }
        }
        continuation.finish()
        try await inputTask?.value
        try await analyzer.finalizeAndFinishThroughEndOfInput()
        // The results stream terminates once the analyzer finishes — awaiting
        // it is what lands the final transcript chunk.
        try await resultsTask?.value
        return await collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Resample a tap buffer into the analyzer's preferred format.
    private static func convert(_ buffer: AVAudioPCMBuffer,
                                from src: AVAudioFormat, to dst: AVAudioFormat,
                                using converter: AVAudioConverter) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * dst.sampleRate / src.sampleRate)) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: capacity) else { return nil }
        // The input block runs synchronously inside convert() — the capture
        // never actually crosses a concurrency boundary.
        nonisolated(unsafe) var consumed = false
        nonisolated(unsafe) let source = buffer
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if consumed { status.pointee = .endOfStream; return nil }
            consumed = true
            status.pointee = .haveData
            return source
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
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
    private var lastAppend = Date.distantPast
    var hasContent: Bool { !value.isEmpty }
    func append(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        value += (value.isEmpty ? "" : " ") + t
        lastAppend = Date()
    }
    /// No new final segment for `seconds` — the utterance has ended.
    func idleFor(_ seconds: Double) -> Bool {
        Date().timeIntervalSince(lastAppend) >= seconds
    }
}

/// One-bit flag settable from a non-isolated callback.
private final class FinishedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    var get: Bool { lock.lock(); defer { lock.unlock() }; return done }
    func set() { lock.lock(); done = true; lock.unlock() }
}

/// First `claim()` wins — the atomic test-and-set continuation resumption
/// needs when several callbacks could race to finish it.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// On-device text-to-speech — AVSpeechSynthesizer, works fully offline.
public final class Speaker: NSObject, @unchecked Sendable, AVSpeechSynthesizerDelegate {
    let synth = AVSpeechSynthesizer()
    private let lock = NSLock()
    var finished: CheckedContinuation<Void, Never>?
    /// Serializes concurrent `say` calls — two overlapping callers would
    /// overwrite `finished` and leak the first caller's continuation.
    private var sayTail: Task<Void, Never>?

    public override init() {
        super.init()
        synth.delegate = self
    }

    /// Available on-device voices for a BCP-47 prefix ("id", "en").
    public static func voices(matching prefix: String) -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix(prefix) }
    }

    /// The best installed voice for a language — premium > enhanced >
    /// default. `AVSpeechSynthesisVoice(language:)` picks whatever Apple
    /// marked default, which is the base quality even when the user
    /// downloaded the enhanced variant in Accessibility settings.
    static func preferredVoice(language: String) -> AVSpeechSynthesisVoice? {
        let prefix = String(language.prefix(2))
        let candidates = voices(matching: language.isEmpty ? prefix : language)
            .isEmpty ? voices(matching: prefix) : voices(matching: language)
        return candidates.max(by: { $0.quality.rawValue < $1.quality.rawValue })
            ?? AVSpeechSynthesisVoice(language: language)
    }

    /// Speak and return after the utterance finishes — bounded by `timeout`
    /// so a wedged synthesizer can't pin the caller (UI status, serve loop).
    /// Overlapping calls queue behind each other rather than racing the
    /// shared continuation slot.
    public func say(_ text: String, language: String = "id-ID", timeout: Double = 30) async {
        // read-modify-write of the tail under the same lock the continuation
        // slot uses — an atomic pair or two concurrent callers both chain nil.
        let t = lock.withLock {
            let prev = sayTail
            let t = Task { [weak self] in
                _ = await prev?.value
                await self?.speakOnce(text, language: language, timeout: timeout)
            }
            sayTail = t
            return t
        }
        await t.value
    }

    private func speakOnce(_ text: String, language: String, timeout: Double) async {
        self.stop()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                let u = AVSpeechUtterance(string: text)
                u.voice = Self.preferredVoice(language: language)
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
