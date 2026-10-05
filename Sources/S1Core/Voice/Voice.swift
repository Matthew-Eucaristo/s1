import Foundation
import Speech
import AVFoundation
import NaturalLanguage

/// Spoken-language plumbing shared by STT, TTS and the serve loop.
///
/// SpeechTranscriber needs ONE locale per session and macOS has no public
/// spoken-language-ID API, so "auto" means: transcribe the turn in a small
/// candidate set at once (the Mac's language + English/Indonesian), then
/// keep the transcript whose recognizer was most confident and whose words
/// NaturalLanguage agrees are in that language.
public enum SpokenLanguage {
    public static let auto = "auto"

    /// Candidate locales for a setting: a concrete identifier ("id-ID")
    /// pins one language; "auto"/empty/nil → the system language plus
    /// English or Indonesian, at most two (each candidate costs a parallel
    /// on-device recognizer).
    public static func candidates(for setting: String?,
                                  preferred: [String] = Locale.preferredLanguages) -> [Locale] {
        let s = (setting ?? auto).trimmingCharacters(in: .whitespaces)
        if !s.isEmpty, s.lowercased() != auto { return [Locale(identifier: s)] }
        var out: [Locale] = []
        for id in [preferred.first, "en-US", "id-ID"].compactMap({ $0 }) {
            let l = Locale(identifier: id)
            if !out.contains(where: { code($0) == code(l) }) { out.append(l) }
        }
        return Array(out.prefix(2))
    }

    /// Two-letter language code ("id", "en").
    public static func code(_ l: Locale) -> String {
        l.language.languageCode?.identifier ?? String(l.identifier.prefix(2))
    }

    /// Which candidate `text` is written in — NaturalLanguage constrained
    /// to the candidates, first candidate on no signal. Used to answer in
    /// the language the user just spoke.
    public static func detect(_ text: String, among candidates: [Locale]) -> Locale? {
        guard let first = candidates.first else { return nil }
        let scores = likelihoods(text, among: candidates)
        return candidates.max { (scores[code($0)] ?? 0) < (scores[code($1)] ?? 0) } ?? first
    }

    static func likelihoods(_ text: String, among candidates: [Locale]) -> [String: Double] {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard candidates.count > 1, !t.isEmpty else { return [:] }
        let r = NLLanguageRecognizer()
        r.languageConstraints = candidates.map { NLLanguage(code($0)) }
        r.processString(t)
        return Dictionary(r.languageHypotheses(withMaximum: candidates.count)
            .map { ($0.key.rawValue, $0.value) }, uniquingKeysWith: max)
    }

    /// One candidate's transcript for a turn.
    public struct Candidate: Sendable {
        public var locale: Locale
        public var text: String
        /// Mean per-word recognizer confidence (0…1), nil if not reported.
        public var confidence: Double?
        public init(locale: Locale, text: String, confidence: Double?) {
            self.locale = locale; self.text = text; self.confidence = confidence
        }
    }

    /// Pick the transcript to act on: recognizer confidence, nudged by
    /// whether the words read as that language. A recognizer forced onto
    /// the wrong language still emits words, just low-confidence ones in
    /// the wrong vocabulary — both signals point the same way.
    public static func pick(_ cands: [Candidate]) -> Candidate? {
        let spoken = cands.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard spoken.count > 1 else { return spoken.first }
        func score(_ c: Candidate) -> Double {
            let lang = likelihoods(c.text, among: spoken.map(\.locale))[code(c.locale)] ?? 0
            return (c.confidence ?? 0.5) + 0.3 * lang
        }
        return spoken.enumerated().max { a, b in
            let sa = score(a.element), sb = score(b.element)
            return sa == sb ? a.offset > b.offset : sa < sb
        }?.element
    }
}

/// On-device speech-to-text via macOS 26's SpeechAnalyzer/SpeechTranscriber —
/// no cloud, 60+ locales, Indonesian included. With more than one locale it
/// auto-detects the spoken language per turn (see `SpokenLanguage`).
@available(macOS 26, *)
public struct SpeechToText: Sendable {
    /// Candidate languages — one = fixed, several = auto-detect per turn.
    public var locales: [Locale]
    /// The primary locale (legacy recognizer + tie-breaks).
    public var locale: Locale { locales.first ?? Locale(identifier: "id-ID") }
    /// Phrases the recognizer should bias toward (app names, jargon) —
    /// Apple's "contextual strings" on both the legacy and Analyzer paths.
    public var vocabulary: [String]

    public static var preferredLocale: Locale {
        Locale(identifier: Locale.preferredLanguages.first ?? "id-ID")
    }

    public init(locale: Locale = SpeechToText.preferredLocale, vocabulary: [String] = []) {
        self.init(locales: [locale], vocabulary: vocabulary)
    }

    public init(locales: [Locale], vocabulary: [String] = []) {
        self.locales = locales.isEmpty ? [SpeechToText.preferredLocale] : locales
        self.vocabulary = vocabulary
    }

    /// The text heard plus the language it was heard in.
    public struct Heard: Sendable {
        public var text: String
        public var locale: Locale
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

    /// A SpeechTranscriber the system can actually run for `locale` —
    /// nil when the configuration is unsupported. `SpeechTranscriber
    /// .isAvailable` is only class-level: a locale the machine can't
    /// serve still builds a transcriber, and SpeechAnalyzer then throws
    /// "modules configured with an unsupported configuration" mid-listen.
    /// Apple documents the real gate as supportedLocale + AssetInventory
    /// status; unsupported → the caller falls back to SFSpeechRecognizer.
    private static func supportedTranscriber(
        _ locale: Locale,
        reportingOptions: Set<SpeechTranscriber.ReportingOption> = []
    ) async -> SpeechTranscriber? {
        guard SpeechTranscriber.isAvailable,
              let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { return nil }
        let t = SpeechTranscriber(locale: supported,
                                  transcriptionOptions: [],
                                  reportingOptions: reportingOptions,
                                  attributeOptions: [.transcriptionConfidence])
        let status = await AssetInventory.status(forModules: [t])
        guard status != .unsupported else { return nil }
        if status != .installed,
           let request = try? await AssetInventory.assetInstallationRequest(supporting: [t]) {
            try? await request.downloadAndInstall()
        }
        return t
    }

    /// One runnable transcriber per distinct candidate language.
    private func lanes(reportingOptions: Set<SpeechTranscriber.ReportingOption> = [])
        async -> [(Locale, SpeechTranscriber)] {
        var out: [(Locale, SpeechTranscriber)] = []
        for l in locales where !out.contains(where: { SpokenLanguage.code($0.0) == SpokenLanguage.code(l) }) {
            if let t = await Self.supportedTranscriber(l, reportingOptions: reportingOptions) {
                out.append((l, t))
            }
        }
        return out
    }

    /// Transcribe an audio file end-to-end (the testable path — no mic needed).
    /// Prefers SpeechAnalyzer (macOS 26); falls back to SFSpeechRecognizer
    /// when the new speech assets aren't installed on the machine.
    public func transcribe(file url: URL) async throws -> String {
        try await transcribeDetailed(file: url).text
    }

    public func transcribeDetailed(file url: URL) async throws -> Heard {
        let lanes = await lanes()
        if !lanes.isEmpty {
            return try await transcribeAnalyzer(file: url, lanes: lanes)
        }
        // Legacy recognizer: one pass per candidate language (a file is
        // cheap to re-read), keep the most confident one in its language.
        var cands: [SpokenLanguage.Candidate] = []
        var firstError: Error?
        for l in locales {
            do {
                let (text, conf) = try await transcribeLegacy(file: url, locale: l)
                cands.append(.init(locale: l, text: text, confidence: conf))
            } catch { firstError = firstError ?? error }
        }
        if let best = SpokenLanguage.pick(cands) { return Heard(text: best.text, locale: best.locale) }
        if let firstError { throw firstError }
        return Heard(text: "", locale: locale)
    }

    /// Live mic on the legacy recognizer can only run one language: take
    /// the first candidate this Mac can recognize on-device, else any.
    var legacyMicLocale: Locale {
        let usable = locales.filter { SFSpeechRecognizer(locale: $0)?.isAvailable == true }
        return usable.first { SFSpeechRecognizer(locale: $0)?.supportsOnDeviceRecognition == true }
            ?? usable.first ?? locale
    }

    /// SFSpeechRecognizer path — works on macOS 15+, uses whichever speech
    /// assets the system already has (en-US ships with Dictation).
    private func transcribeLegacy(file url: URL, locale: Locale) async throws -> (String, Double?) {
        guard let rec = SFSpeechRecognizer(locale: locale), rec.isAvailable else {
            throw S1Error.aborted("no speech recognizer for \(locale.identifier)")
        }
        let req = SFSpeechURLRecognitionRequest(url: url)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        if !vocabulary.isEmpty { req.contextualStrings = vocabulary }
        return try await withCheckedThrowingContinuation { (c: CheckedContinuation<(String, Double?), Error>) in
            // The callback isn't serialized — resume-at-most-once needs a
            // lock, or a final+error pair on two queues double-resumes (fatal).
            let once = OnceFlag()
            rec.recognitionTask(with: req) { result, error in
                if let r = result, r.isFinal {
                    let segs = r.bestTranscription.segments
                    let conf = segs.isEmpty ? nil : segs.map { Double($0.confidence) }.reduce(0, +) / Double(segs.count)
                    if once.claim() { c.resume(returning: (r.bestTranscription.formattedString, conf)) }
                } else if let error {
                    if once.claim() { c.resume(throwing: error) }
                }
            }
        }
    }

    /// Pre-warm the speech models so the first utterance isn't cold-slow —
    /// Apple's `SpeechAnalyzer.prepareToAnalyze` exists for exactly this.
    /// Best-effort: every failure is swallowed (the real path retries).
    public func warmup() async {
        for (_, t) in await lanes() {
            let analyzer = SpeechAnalyzer(modules: [t])
            guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [t]) else { continue }
            try? await analyzer.prepareToAnalyze(in: format)
        }
    }

    /// Mean per-character confidence of a result, with its weight.
    static func confidence(of text: AttributedString) -> (Double, Int)? {
        var sum = 0.0, n = 0
        for run in text.runs {
            guard let c = run.transcriptionConfidence else { continue }
            let len = text[run.range].characters.count
            sum += c * Double(len); n += len
        }
        return n > 0 ? (sum / Double(n), n) : nil
    }

    /// SpeechAnalyzer/SpeechTranscriber path (macOS 26 assets required) —
    /// one analyzer per candidate language over the same file.
    private func transcribeAnalyzer(file url: URL, lanes: [(Locale, SpeechTranscriber)]) async throws -> Heard {
        let collectors = lanes.map { _ in TextCollector() }
        let failures = Locked<[Error]>([])
        let ctx = analysisContext
        // One language failing (e.g. its model can't run here) must not
        // sink the others — a lane error just leaves that lane empty.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for (i, (_, transcriber)) in lanes.enumerated() {
                guard let file = try? AVAudioFile(forReading: url) else {
                    throw S1Error.aborted("cannot open audio file \(url.path)")
                }
                let analyzer = SpeechAnalyzer(modules: [transcriber])
                // Vocabulary is a bias, not a requirement — a lane whose
                // context can't be set still transcribes (or fails in-lane).
                if let ctx { try? await analyzer.setContext(ctx) }
                let collected = collectors[i]
                group.addTask {
                    do {
                        for try await result in transcriber.results {
                            let c = Self.confidence(of: result.text)
                            await collected.append(String(result.text.characters), confidence: c)
                        }
                    } catch {
                        failures.value.append(error)
                    }
                }
                group.addTask {
                    do {
                        if let last = try await analyzer.analyzeSequence(from: file) {
                            try await analyzer.finalizeAndFinish(through: last)
                        }
                    } catch {
                        failures.value.append(error)
                        await analyzer.cancelAndFinishNow()
                    }
                }
            }
            try await group.waitForAll()
        }
        let heard = await Self.choose(lanes: lanes, collectors: collectors)
        if heard.text.isEmpty, let err = failures.value.first { throw err }
        return heard
    }

    private static func choose(lanes: [(Locale, SpeechTranscriber)],
                               collectors: [TextCollector]) async -> Heard {
        var cands: [SpokenLanguage.Candidate] = []
        for (i, (l, _)) in lanes.enumerated() {
            cands.append(.init(locale: l,
                               text: await collectors[i].value.trimmingCharacters(in: .whitespacesAndNewlines),
                               confidence: await collectors[i].meanConfidence))
        }
        let best = SpokenLanguage.pick(cands)
        return Heard(text: best?.text ?? "", locale: best?.locale ?? lanes[0].0)
    }

    /// Live microphone transcription until `stop` flips true or `maxSeconds`
    /// elapses. Requires mic permission + an input device. Uses whichever
    /// engine the system supports (legacy recognizer if Analyzer assets are
    /// absent — the honest fallback, same on-device privacy).
    /// `onPartial` receives the live best-guess transcript while the user is
    /// still speaking — the volatile results Apple emits between finals —
    /// so a UI can show words landing instead of looking dead mid-utterance.
    public func transcribeMic(maxSeconds: Double = 30, control: MicControl? = nil,
                            onPartial: (@Sendable (String) -> Void)? = nil) async throws -> String {
        try await transcribeMicDetailed(maxSeconds: maxSeconds, control: control, onPartial: onPartial).text
    }

    public func transcribeMicDetailed(maxSeconds: Double = 30, control: MicControl? = nil,
                                      onPartial: (@Sendable (String) -> Void)? = nil) async throws -> Heard {
        // No input device at all → clean error. Without this, installTap throws
        // an NSException (uncatchable from Swift) and kills the whole process —
        // which would take down the always-on daemon with it.
        guard AVCaptureDevice.default(for: .audio) != nil else {
            throw S1Error.aborted("no microphone input available")
        }
        let lanes = await lanes(reportingOptions: [.volatileResults])
        if !lanes.isEmpty {
            return try await transcribeMicAnalyzer(maxSeconds: maxSeconds, lanes: lanes,
                                                  control: control, onPartial: onPartial)
        }
        let l = legacyMicLocale
        return Heard(text: try await transcribeMicLegacy(maxSeconds: maxSeconds, locale: l, control: control, onPartial: onPartial),
                     locale: l)
    }

    /// Seconds of unchanged transcript after words arrived that end a turn.
    static let textSettle = 1.2

    private func transcribeMicLegacy(maxSeconds: Double, locale: Locale, control: MicControl?,
                                     onPartial: (@Sendable (String) -> Void)?) async throws -> String {
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
        req.shouldReportPartialResults = true
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        if !vocabulary.isEmpty { req.contextualStrings = vocabulary }
        let collected = Locked<String>("")
        let failure = Locked<Error?>(nil)
        let finished = FinishedFlag()
        let lastText = Locked<Date?>(nil)
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
            } else if let r = result {
                // Partial hypothesis — volatile best-guess while the user
                // is still mid-word; live UI transcript, never persisted.
                lastText.value = Date()
                onPartial?(r.bestTranscription.formattedString)
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
            MicLevel.shared.reset()
        }
        let endpointer = Endpointer()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            endpointer.feed(buffer: buffer, dB: MicLevel.push(buffer: buffer))
            req.append(buffer)
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()
        // End the turn when the user stops talking (energy endpointer), when
        // recognition fails, or when a final transcript lands early — this
        // recognizer rarely declares "final" on its own mid-stream.
        var waited = 0.0
        var endReason = "timeout"
        while waited < maxSeconds {
            if failure.value != nil { endReason = "error"; break }
            if finished.get { endReason = "final"; break }
            if control?.stopped == true { endReason = "released"; break }
            if control?.holding != true {
                if endpointer.isDone { endReason = "endpointer:\(endpointer.state)"; break }
                if let t = lastText.value, Date().timeIntervalSince(t) > Self.textSettle { endReason = "textSettle"; break }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
            waited += 0.1
        }
        DebugTrace.event("voice", ["path": "legacy", "end": endReason, "seconds": waited,
                                   "locale": locale.identifier])
        // Close the audio so the recognizer finalizes what it has now.
        req.endAudio()
        for _ in 0 ..< 15 where !finished.get { try await Task.sleep(nanoseconds: 100_000_000) }
        task.finish()
        // finish() delivers the final result asynchronously — give that
        // callback a beat too, or the last words get read as silence.
        for _ in 0 ..< 10 where !finished.get { try await Task.sleep(nanoseconds: 100_000_000) }
        if let error = failure.value { throw error }
        return collected.value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One mic tap feeds every candidate-language analyzer the same
    /// converted buffers; the VAD rides on the first lane only.
    private func transcribeMicAnalyzer(maxSeconds: Double, lanes: [(Locale, SpeechTranscriber)],
                                       control: MicControl?,
                                       onPartial: (@Sendable (String) -> Void)?) async throws -> Heard {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else {
            throw S1Error.aborted("no microphone input available")
        }
        // SpeechDetector is Apple's VAD module — its results tell us when
        // speech actually ended rather than guessing from transcript-idle
        // timeouts, so a mid-word pause can't cut the turn early.
        let detector = SpeechDetector(detectionOptions: .init(sensitivityLevel: .medium),
                                      reportResults: true)
        let analyzers = lanes.enumerated().map { i, lane in
            SpeechAnalyzer(modules: i == 0 ? [lane.1, detector] : [lane.1])
        }
        if let ctx = analysisContext {
            for a in analyzers { try? await a.setContext(ctx) }
        }
        // Apple doc pattern: feed the analyzer its best available format —
        // the mic's native rate may differ, and odd hardware (8 kHz devices)
        // would otherwise hand the analyzer a format it can't use.
        let modules: [any SpeechModule] = lanes.map(\.1) + [detector]
        let best = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        let converter = best.flatMap { AVAudioConverter(from: format, to: $0) }
        let streams = lanes.map { _ in AsyncStream<AnalyzerInput>.makeStream() }
        let continuations = streams.map(\.1)
        var tapInstalled = false
        // Same cancellation rule as the legacy path: the tap and engine must
        // come down even when the task is cancelled mid-listen.
        var resultsTasks: [Task<Void, Error>] = []
        var inputTasks: [Task<Void, Error>] = []
        var detectorTask: Task<Void, Never>?
        defer {
            // Cancelled mid-listen → children must not outlive the scope.
            resultsTasks.forEach { $0.cancel() }
            inputTasks.forEach { $0.cancel() }
            detectorTask?.cancel()
            if tapInstalled { input.removeTap(onBus: 0) }
            engine.stop()
            continuations.forEach { $0.finish() }
            MicLevel.shared.reset()
        }
        // The analyzer must only ever see ONE format: a buffer in the mic's
        // native format slipped past a failed conversion traps inside
        // Speech (EXC_BREAKPOINT on RealtimeMessenger.mServiceQueue, macOS 27).
        // So a buffer that can't be converted is dropped, never forwarded raw.
        let needsConversion = best.map { $0 != format } ?? false
        if needsConversion, converter == nil {
            throw S1Error.aborted("cannot convert mic audio to the speech analyzer's format")
        }
        let endpointer = Endpointer()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            endpointer.feed(buffer: buffer, dB: MicLevel.push(buffer: buffer))
            let feed: AVAudioPCMBuffer
            if needsConversion {
                guard let converter, let best,
                      let out = Self.convert(buffer, from: format, to: best, using: converter) else { return }
                feed = out
            } else {
                feed = buffer
            }
            for c in continuations { c.yield(AnalyzerInput(buffer: feed)) }
        }
        tapInstalled = true
        engine.prepare()
        try engine.start()

        let collectors = lanes.map { _ in TextCollector() }
        let leader = Locked<[Double]>(Array(repeating: -1, count: lanes.count))
        let speechEnded = FinishedFlag()
        let lastText = Locked<Date?>(nil)
        // VAD: speechDetected true→false means the utterance is over —
        // close the turn promptly even when the final segment lags.
        detectorTask = Task {
            var spoke = false
            do {
                for try await r in detector.results {
                    if r.speechDetected { spoke = true }
                    else if spoke { speechEnded.set(); break }
                }
            } catch { /* detector stream dying shouldn't kill the turn */ }
        }
        for (i, (_, transcriber)) in lanes.enumerated() {
            let collected = collectors[i]
            resultsTasks.append(Task {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { lastText.value = Date() }
                    if result.isFinal {
                        await collected.append(text, confidence: Self.confidence(of: result.text))
                        let mean = await collected.meanConfidence ?? 0
                        leader.value[i] = mean
                    } else {
                        // Volatile best-guess of the in-flight segment — only
                        // the currently most confident language streams to
                        // the UI, so the live line doesn't flicker between two.
                        let scores = leader.value
                        let lead = scores.indices.max { scores[$0] < scores[$1] || (scores[$0] == scores[$1] && $0 > $1) } ?? 0
                        guard lead == i else { continue }
                        let soFar = await collected.value
                        onPartial?(soFar.isEmpty ? text : soFar + " " + text)
                    }
                }
            })
        }
        for (i, a) in analyzers.enumerated() {
            let stream = streams[i].0
            inputTasks.append(Task { try await a.start(inputSequence: stream) })
        }
        // End the turn on speech, not on the clock: VAD (SpeechDetector or
        // the energy endpointer) says the utterance ended, or once a final
        // segment has landed a short grace catches
        // trailing words. Burning the full maxSeconds after every command
        // made every voice turn feel frozen.
        var waited = 0.0
        var endReason = "timeout"
        while waited < maxSeconds {
            try await Task.sleep(nanoseconds: 150_000_000)
            waited += 0.15
            if control?.stopped == true { endReason = "released"; break }
            // Hold-to-talk: the key, not the VAD, ends the turn.
            if control?.holding == true { continue }
            if speechEnded.get { endReason = "speechDetector"; break }
            if endpointer.isDone { endReason = "endpointer:\(endpointer.state)"; break }
            // The recognizer is a VAD too: words stopped changing → turn over.
            if let t = lastText.value, Date().timeIntervalSince(t) > Self.textSettle { endReason = "textSettle"; break }
            var settled = false
            for c in collectors {
                if await c.hasContent, await c.idleFor(0.9) { settled = true; break }
            }
            if settled { endReason = "collectorIdle"; break }
        }
        DebugTrace.event("voice", ["path": "analyzer", "end": endReason, "seconds": waited,
                                   "lanes": collectors.count])
        continuations.forEach { $0.finish() }
        var laneErrors: [Error] = []
        for (i, t) in inputTasks.enumerated() {
            do {
                try await t.value
                try await analyzers[i].finalizeAndFinishThroughEndOfInput()
            } catch {
                laneErrors.append(error)
                await analyzers[i].cancelAndFinishNow()
            }
        }
        // The results stream SHOULD terminate once the analyzer finishes —
        // but that contract is unverified on macOS 26, and a stream that
        // never ends wedges this turn forever (serve would never time out).
        // Bound the drain: after finalize, a straggler stream is cancelled
        // and we take whatever transcript already landed.
        let pending = resultsTasks
        let watchdog = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            pending.forEach { $0.cancel() }
        }
        for t in resultsTasks {
            do { try await t.value } catch is CancellationError {
                // Watchdog fired — the results that already landed are still good.
            } catch {
                laneErrors.append(error)
            }
        }
        watchdog.cancel()
        let heard = await Self.choose(lanes: lanes, collectors: collectors)
        // Only fail the turn when every language failed and nothing was heard.
        if heard.text.isEmpty, laneErrors.count >= lanes.count, let err = laneErrors.first { throw err }
        return heard
    }

    /// Resample a tap buffer into the analyzer's preferred format.
    /// The converter is reused across the whole stream, so an exhausted
    /// input block must answer `.noDataNow` — `.endOfStream` puts the
    /// converter in its terminal state and every later call yields 0 frames.
    static func convert(_ buffer: AVAudioPCMBuffer,
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
            if consumed { status.pointee = .noDataNow; return nil }
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
    private var confSum = 0.0
    private var confWeight = 0
    var hasContent: Bool { !value.isEmpty }
    /// Mean recognizer confidence over every final segment so far.
    var meanConfidence: Double? { confWeight > 0 ? confSum / Double(confWeight) : nil }
    func append(_ s: String, confidence: (Double, Int)? = nil) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        value += (value.isEmpty ? "" : " ") + t
        lastAppend = Date()
        if let (c, n) = confidence { confSum += c * Double(n); confWeight += n }
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
    /// `voice` pins a voice identifier; it's only used when its language
    /// matches `language` (an English voice reading Indonesian is worse than
    /// the best Indonesian one), otherwise the best installed voice wins.
    public func say(_ text: String, language: String = "id-ID", voice: String? = nil,
                    timeout: Double = 30) async {
        // read-modify-write of the tail under the same lock the continuation
        // slot uses — an atomic pair or two concurrent callers both chain nil.
        let t = lock.withLock {
            let prev = sayTail
            let t = Task { [weak self] in
                _ = await prev?.value
                await self?.speakOnce(text, language: language, voice: voice, timeout: timeout)
            }
            sayTail = t
            return t
        }
        await t.value
    }

    static func voice(for language: String, pinned: String?) -> AVSpeechSynthesisVoice? {
        if let id = pinned, !id.isEmpty, let v = AVSpeechSynthesisVoice(identifier: id),
           v.language.prefix(2) == language.prefix(2) {
            return v
        }
        return preferredVoice(language: language)
    }

    private func speakOnce(_ text: String, language: String, voice: String?, timeout: Double) async {
        self.stop()
        await withTaskGroup(of: Void.self) { group in
            group.addTask { [self] in
                let u = AVSpeechUtterance(string: text)
                u.voice = Self.voice(for: language, pinned: voice)
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

/// External control over a mic turn — hold-to-talk and push-to-stop.
/// `holding` suspends VAD end-of-turn; `stopped` ends the turn now.
public final class MicControl: @unchecked Sendable {
    private let lock = NSLock()
    private var _holding = false, _stopped = false
    public init(holding: Bool = false) { _holding = holding }
    public var holding: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _holding }
        set { lock.lock(); _holding = newValue; lock.unlock() }
    }
    public var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
    public func stop() { lock.lock(); _stopped = true; lock.unlock() }
}
