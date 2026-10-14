import AppKit
import Foundation

/// Lifecycle events the serve daemon reports — UI and CLI both render these.
public struct ServeEvent: Sendable {
    public enum Kind: String, Sendable {
        case armed, idle, listening, partial, heard, runStart, phase, step, runDone, error, sleeping, stopped
        /// The reply is being spoken (text = the reply); the next `.listening` ends it.
        case speaking
        /// The user talked over the run or the reply; listening resumes next.
        case interrupted
        /// Esc pressed (by the user): whatever s1 is doing should stop.
        case escape
        /// Hands-free dictation switched on ("on") or off ("").
        case dictating
        /// Speech recognition failed for one turn (transient; repeated
        /// failures sleep the listener with reason "stt errors").
        case listenError
        /// The agent run itself threw.
        case runError
        /// A gated step waits for the user (text = the question asked).
        case confirm
        /// The user answered (text = "yes" / "no").
        case confirmDone
    }
    public var kind: Kind
    public var text: String
    /// Full step record on `.step` events (nil otherwise) — lets a UI
    /// render the live feed, not just the digest line.
    public var record: StepRecord?
    /// Artifacts dir on `.runDone` — the UI's "open run folder" affordance.
    public var dir: String?
    public init(_ kind: Kind, _ text: String = "",
                record: StepRecord? = nil, dir: String? = nil) {
        self.kind = kind
        self.text = text
        self.record = record
        self.dir = dir
    }
}

/// The always-on companion loop: a hotkey wakes it, it listens continuously,
/// runs each utterance through the agent, speaks the ack, and goes back to
/// listening — until told to stop, the hotkey fires again, or it idles out.
///
/// Battery story: `idle` means zero mic and zero CPU beyond the key monitor.
/// `listening` uses the mic for `listenSeconds` per turn; `maxSilentTurns`
/// consecutive silent turns drop it back to idle automatically.
public final class Serve: @unchecked Sendable {
    public enum State: String, Sendable { case idle, listening, running }

    public struct Config: Sendable {
        /// How each utterance is executed (policy choice lives outside).
        public var makePolicy: @Sendable () -> any Policy
        public var s2: (any Reasoner)?
        public var speak: Bool
        public var listenSeconds: Double
        public var maxSilentTurns: Int
        public var maxListenErrors: Int
        public var artifacts: String
        public var killSwitch: String
        /// One-listener lock (~/.s1/serve.pid). `wake()` re-verifies it —
        /// a stolen or deleted lock must not let two listeners coexist.
        public var lockPath: String?
        /// Utterances that end the listening session instead of running.
        public var stopPhrases: [String]
        /// Injectable transcription — real path is the mic; tests/demos feed files.
        /// The parameter forwards live partial (volatile) text to the UI —
        /// pass it through to SpeechToText.transcribeMic's onPartial.
        public var transcribe: @Sendable (@Sendable @escaping (String) -> Void) async throws -> String
        /// True while another agent run (e.g. the app's Run button) owns the
        /// screen — heard utterances are skipped rather than starting a second
        /// concurrent run that would fight it for keyboard focus.
        public var isBusy: @Sendable () async -> Bool
        /// Candidate reply languages — the ack is spoken in whichever of
        /// these the heard goal is in (empty = the serve locale).
        public var languages: [Locale]
        /// Pinned TTS voice identifier (nil = best installed per language).
        public var voice: String?
        /// Voice interrupt: while a run or the reply is in flight, a
        /// sustained voice burst aborts it and the listener reopens for
        /// the next command. Off = only the hotkey/kill switch stops work.
        public var voiceInterrupt: Bool
        /// Types one dictated chunk into the focused field.
        public var dictate: @Sendable (String) async throws -> Void
        /// True while something else in this process records the mic (the
        /// app's own listen or dictation): waking would open a second audio
        /// engine on the same input.
        public var micBusy: @Sendable () -> Bool
        /// The host's own way to answer a gated step (the app's Allow/Cancel
        /// buttons). Raced against the spoken answer; nil = voice only.
        public var confirm: ConfirmHandler?

        public init(makePolicy: @escaping @Sendable () -> any Policy = { AXPolicy() },
                    s2: (any Reasoner)? = nil,
                    speak: Bool = true,
                    listenSeconds: Double = 45,
                    maxSilentTurns: Int = 3,
                    maxListenErrors: Int = 3,
                    artifacts: String = S1Home.path + "/artifacts",
                    killSwitch: String = NSTemporaryDirectory() + "s1-serve-stop",
                    lockPath: String? = nil,
                    stopPhrases: [String] = ["stop", "berhenti", "stop listening", "matikan", "tidur",
                                             "sleep", "go to sleep", "istirahat"],
                    transcribe: @escaping @Sendable (@Sendable @escaping (String) -> Void) async throws -> String,
                    isBusy: @escaping @Sendable () async -> Bool = {
                        S1Runner.anotherRunActive() },
                    languages: [Locale] = [],
                    voice: String? = nil,
                    voiceInterrupt: Bool = true,
                    dictate: @escaping @Sendable (String) async throws -> Void = { text in
                        _ = try await CGEventActuator().perform(
                            .typeText(text),
                            frontmostPID: NSWorkspace.shared.frontmostApplication?.processIdentifier)
                    },
                    micBusy: @escaping @Sendable () -> Bool = { false },
                    confirm: ConfirmHandler? = nil) {
            self.micBusy = micBusy
            self.confirm = confirm
            self.makePolicy = makePolicy
            self.s2 = s2
            self.speak = speak
            self.listenSeconds = listenSeconds
            self.maxSilentTurns = maxSilentTurns
            self.maxListenErrors = maxListenErrors
            self.artifacts = artifacts
            self.killSwitch = killSwitch
            self.lockPath = lockPath
            self.stopPhrases = stopPhrases
            self.transcribe = transcribe
            self.isBusy = isBusy
            self.languages = languages
            self.voice = voice
            self.voiceInterrupt = voiceInterrupt
            self.dictate = dictate
        }
    }

    /// Written by the hotkey callback (main run loop) and read by the
    /// listen task — always under `stateLock`.
    private var _state: State = .idle
    private let stateLock = NSLock()
    public var state: State {
        stateLock.lock(); defer { stateLock.unlock() }
        return _state
    }
    private func setState(_ s: State) { stateLock.lock(); _state = s; stateLock.unlock() }
    /// Move `from` → `to` only if still in `from` — a sleep landing between
    /// a check and a set can't be undone by a stale transition.
    private func transition(from: State, to: State) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard _state == from else { return false }
        _state = to
        return true
    }

    private let config: Config
    private let speaker = Speaker()
    private let onEvent: @Sendable (ServeEvent) -> Void
    private var hotkey: Hotkey?
    private var listenTask: Task<Void, Never>?
    /// A request the user kept talking over within `continuationWindow` of
    /// it starting: they weren't interrupting, they hadn't finished. The next
    /// utterance is joined onto it instead of becoming a fresh command.
    private var pendingPrefix: (text: String, at: Date)?
    static let continuationWindow: TimeInterval = 3
    /// Hands-free dictation: utterances are typed, not run.
    private let dictating = Locked(false)
    /// Pauses to think are normal while dictating — allow ~2 min of silence.
    static let dictationSilentTurns = 10
    private let sayLanguage: String
    /// ~/.s1/serve-state.json — external observability for `s1 status`.
    /// Best-effort: a daemon should never fail because telemetry can't write.
    public static let statePath = S1Home.path + "/serve-state.json"

    public init(config: Config,
                locale: Locale = Locale(identifier: Locale.preferredLanguages.first ?? "id-ID"),
                hotkeyPatterns: [HotkeyPattern]? = nil,
                onEvent: @escaping @Sendable (ServeEvent) -> Void) {
        self.config = config
        self.sayLanguage = locale.identifier
        self.onEvent = onEvent
        if let patterns = hotkeyPatterns {
            hotkey = Hotkey(patterns: patterns, onEscape: { [weak self] in
                self?.escapePressed()
            }) { [weak self] in
                self?.toggle()
            }
        }
    }

    /// Install the hotkey monitor. After this, pressing the hotkey toggles
    /// listening on/off — this is the always-on daemon arm.
    public func armHotkey() {
        // The monitor's handler is delivered on the run loop of the
        // installing thread — always main, or callbacks are lost.
        if Thread.isMainThread {
            installMonitor()
        } else {
            DispatchQueue.main.async { [weak self] in self?.installMonitor() }
        }
    }

    private func installMonitor() {
        hotkey?.start()
        emit(.armed)
        if let h = hotkey, !h.isArmed {
            emit(.error, "hotkey monitor not installed — grant Input Monitoring + run in a GUI session")
        } else if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            // TCC can let tapCreate succeed while delivering zero events —
            // the process would sit "armed" forever with a dead hotkey.
            emit(.error, "armed but Input Monitoring is NOT granted — hotkey will fire nothing; grant it in System Settings")
        }
    }

    public func disarm() {
        if Thread.isMainThread {
            hotkey?.stop()
        } else {
            DispatchQueue.main.async { [weak self] in self?.hotkey?.stop() }
        }
        sleep()
    }

    /// Esc stops a run or a spoken reply (like ⇧⇧ would), or ends dictation.
    /// While only listening it does nothing — Esc in other apps stays theirs.
    private func escapePressed() {
        emit(.escape)
        if dictating.withLock({ d in defer { d = false }; return d }) { emit(.dictating, "") }
        else if state == .running { sleep("escape") }
    }

    /// Hotkey/menu action: idle → start listening; listening/running → stop.
    public func toggle() {
        switch state {
        case .idle: wake()
        case .listening, .running: sleep()
        }
    }

    public func wake() {
        guard state == .idle else { return }
        guard !config.micBusy() else { emit(.error, "the microphone is in use — finish that first"); return }
        // One listener per machine — re-verify on every wake, not just at
        // startup: a deleted or stolen pid file would otherwise let this
        // wake run alongside a competitor's listener.
        if let lockPath = config.lockPath,
           !S1Runner.holdsPidFile(lockPath) {
            do { try S1Runner.claimPidFile(lockPath, what: "s1 listener") }
            catch { emit(.error, "another listener is running"); return }
        }
        // The mic is shared with foreground `s1 transcribe`/`listen` —
        // claim it for the whole listening session or two audio engines
        // race on the same input.
        do { try S1Runner.claimMic() }
        catch { emit(.error, "mic is in use — try again"); return }
        try? FileManager.default.removeItem(atPath: config.killSwitch)
        setState(.listening)
        emit(.listening)
        // Chain behind the previous task's unwind: its defer must drop the
        // mic tap/engine BEFORE a new turn grabs the input device, or two
        // engines race on rapid wake→sleep→wake.
        let prev = listenTask
        listenTask = Task { [weak self] in
            _ = await prev?.value
            // emit(.listening) handlers run synchronously — one that
            // toggled back to sleep leaves state idle while this task
            // would grab the mic anyway. Re-check at run time.
            guard self?.state == .listening else { return }
            await self?.listenLoop()
        }
    }

    public func sleep() { sleep("") }

    private func sleep(_ reason: String) {
        // Idle first, atomically: a run that hasn't started yet sees it and
        // never starts; one already running is told by the stop file.
        let was: State = stateLock.withLock { defer { _state = .idle }; return _state }
        // Land the kill switch — only when this listener's own run is in
        // flight (the stop file may be shared with other runs), and before
        // the cancel, so the run reads "stopped", not "failed: cancelled".
        if was == .running {
            try? "stop".write(toFile: config.killSwitch, atomically: true, encoding: .utf8)
        }
        // Keep the (cancelled) task reference: the next wake() chains behind
        // its unwind so the mic tap is down before a new turn starts. Setting
        // it nil here would let two audio engines race on rapid toggles.
        listenTask?.cancel()
        // The mic goes free the moment we stop listening — a foreground
        // `s1 transcribe` must not stay locked out by a sleeping daemon.
        S1Runner.releaseMic()
        // And cut any speech in flight — "sleep" should mean silent.
        speaker.stop()
        if dictating.withLock({ d in defer { d = false }; return d }) { emit(.dictating, "") }
        if was != .idle { emit(.sleeping, reason) }
    }

    /// One full listen→run→listen cycle. Silence and STT errors count toward
    /// auto-sleep; a stop phrase ends the session; anything else becomes a goal.
    /// Chunks typed this dictation session (the first gets no leading space).
    private var typedChunks = 0

    private func listenLoop() async {
        var silentTurns = 0
        var errors = 0        // STT/transcribe failures
        var runErrors = 0     // run failures — separate counter: a working
                              // microphone must not hide a dead endpoint
        while state == .listening, !Task.isCancelled {
            do {
                // Partial hypotheses stream straight to the UI — words
                // appear while the user is still speaking instead of one
                // dump at end-of-turn.
                let text = try await config.transcribe { [onEvent] partial in
                    onEvent(ServeEvent(.partial, partial))
                }
                errors = 0
                // `s1 stop` (or the app's Stop button) wrote the stop file
                // while we were transcribing — honor it as "sleep the
                // listener", not only as a per-run abort.
                if FileManager.default.fileExists(atPath: config.killSwitch) {
                    sleep("stopped")
                    return
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if let cmd = Dictation.command(trimmed) {
                    emit(.heard, trimmed)
                    dictating.value = cmd == .start
                    typedChunks = 0
                    pendingPrefix = nil
                    emit(.dictating, cmd == .start ? "on" : "")
                    continue
                }
                if Self.isStop(trimmed, phrases: config.stopPhrases) {
                    emit(.heard, trimmed)
                    emit(.stopped, "stop phrase")
                    sleep()
                    return
                }
                if trimmed.isEmpty {
                    silentTurns += 1
                    let limit = dictating.value ? Self.dictationSilentTurns : config.maxSilentTurns
                    if silentTurns >= limit {
                        sleep("silence")
                        return
                    }
                    continue
                }
                silentTurns = 0
                if dictating.value {
                    emit(.heard, trimmed)
                    do {
                        try await config.dictate(Dictation.chunk(trimmed, first: typedChunks == 0))
                        typedChunks += 1
                    } catch {
                        emit(.error, error.localizedDescription)
                    }
                    continue
                }
                var goal = trimmed
                if let p = pendingPrefix, Date().timeIntervalSince(p.at) < 15 {
                    goal = Self.join(p.text, trimmed)
                }
                pendingPrefix = nil
                emit(.heard, goal)
                if await config.isBusy() {
                    // Another run owns the screen — drop this utterance and
                    // keep listening instead of starting a competing agent.
                    emit(.error, "another run is in progress")
                    try? await Task.sleep(nanoseconds: 500_000_000)
                    continue
                }
                if await run(goal: goal) {
                    runErrors = 0
                } else {
                    // A broken endpoint (or a run that keeps failing) must
                    // not spin forever — consecutive run failures auto-sleep
                    // even while the mic keeps transcribing fine.
                    runErrors += 1
                    if runErrors >= config.maxListenErrors {
                        sleep("run errors x\(runErrors)")
                        return
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                errors += 1
                emit(.listenError, error.localizedDescription)
                if errors >= config.maxListenErrors {
                    sleep("stt errors x\(errors)")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Run one goal through the full agent loop and speak the outcome.
    /// Returns false when the run itself errored — the caller counts those
    /// toward auto-sleep, same as STT failures.
    private func run(goal: String) async -> Bool {
        // Put to sleep while the words were being heard: no run.
        guard transition(from: .listening, to: .running) else { return true }
        emit(.runStart, goal)
        // Barge-in: the mic is otherwise closed for the whole run + reply,
        // so "wait—"/"stop" said out loud would never be heard. The monitor
        // is energy-only (near-free); voice processing's AEC keeps our own
        // TTS from tripping it.
        let barged = AtomicFlag()
        let started = Date()
        let bargedEarly = AtomicFlag()
        // The reply language, known up front: a gated step asks in it too.
        let langs = config.languages.isEmpty ? [Locale(identifier: sayLanguage)] : config.languages
        let lang = SpokenLanguage.detect(goal, among: langs)?.identifier ?? sayLanguage
        let code = SpokenLanguage.code(Locale(identifier: lang))
        var barge: BargeMonitor?
        if config.voiceInterrupt {
            barge = BargeMonitor { [weak self] in
                if Date().timeIntervalSince(started) < Self.continuationWindow { bargedEarly.set() }
                barged.set()
                self?.interrupted()
            }
            barge?.start()
        }
        defer {
            barge?.stop()
            if barged.get {
                // The run aborted at its next step; consume the kill file
                // the interrupt wrote so the loop's own kill check doesn't
                // read it as "sleep the listener" — the user interrupted to
                // say something NEW, so the next turn should still open.
                try? FileManager.default.removeItem(atPath: config.killSwitch)
            }
        }
        var ok = true
        let bargeNow = barge
        let ask: ConfirmHandler = { [weak self] req in
            await self?.ask(req, language: lang, code: code, barge: bargeNow) ?? false
        }
        do {
            let (report, logger) = try await S1Runner.run(
                goal: goal, policy: config.makePolicy(), artifacts: config.artifacts,
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: config.killSwitch,
                s2: config.s2, confirm: ask,
                onStep: { [onEvent] rec in
                    // The full digest (decider, conf, action → outcome) —
                    // the daemon's log should tell the whole story per step.
                    onEvent(ServeEvent(.step, rec.digest, record: rec))
                },
                onPhase: { [onEvent] phase in
                    onEvent(ServeEvent(.phase, phase))
                })
            emit(.runDone, report.status.rawValue, dir: logger.runDir.path)
            // A kill file means the user cancelled — sleep must mean silent,
            // so an aborted run never says "Stopped" after the fact. A
            // barge-in sets its flag before the kill file, and it stays set
            // through the defer — a user who talked over the run doesn't
            // want a reply about it.
            if config.speak && !barged.get
               && !FileManager.default.fileExists(atPath: config.killSwitch) {
                // Speak the truth: "done" is only said when it actually is.
                let reply: String = if let answer = report.answer { answer } else {
                    switch report.status {
                    case .done: SpokenLanguage.reply(.done, languageCode: code)
                    case .needsHuman: SpokenLanguage.reply(.needsHuman, languageCode: code)
                    case .escalatedToS2: SpokenLanguage.reply(.couldNotWorkOut, languageCode: code)
                    default: SpokenLanguage.reply(.stopped, languageCode: code)
                    }
                }
                emit(.speaking, reply)
                await speaker.say(reply, language: lang, voice: config.voice)
            }
        } catch {
            ok = false
            emit(.runError, error.localizedDescription)
        }
        // Talked over within the first seconds: still the same request.
        if bargedEarly.get { pendingPrefix = (goal, Date()) }
        if !barged.get, state == .running, FileManager.default.fileExists(atPath: config.killSwitch) {
            // Stopped from outside (`s1 stop`, the app's Stop): stop means
            // the listener sleeps too — reopening the mic would only throw
            // the next utterance away on the leftover stop file.
            sleep("stopped")
        } else if transition(from: .running, to: .listening) {
            // Publish the transition — the app's badge tracks events, so a
            // run that finishes must announce "listening again" or the badge
            // keeps showing "running" until the next utterance lands.
            emit(.listening, "")
        }
        return ok
    }

    /// A gated step the user may approve: ask out loud and listen for the
    /// answer, while the host's own control (the app's Allow/Cancel) can
    /// answer too — whichever comes first. Talking is the answer here, so
    /// the barge-in monitor (which would abort the run) is paused meanwhile.
    private func ask(_ req: ConfirmRequest, language: String, code: String,
                     barge: BargeMonitor?) async -> Bool {
        barge?.stop()
        defer { barge?.start() }
        let question = Self.question(req, code: code)
        emit(.confirm, question)
        let yes: Bool = await withTaskGroup(of: Bool?.self) { group in
            if let host = config.confirm { group.addTask { await host(req) } }
            group.addTask { [weak self] in await self?.voiceAnswer(question, language: language, code: code) ?? nil }
            for await answer in group {
                if let answer { group.cancelAll(); return answer }
            }
            return false
        }
        speaker.stop()   // the question may still be playing when a button answered
        emit(.confirmDone, yes ? "yes" : "no")
        return yes
    }

    /// Speak the question, then hear "yes"/"no" (two tries); nil = no clear answer.
    private func voiceAnswer(_ question: String, language: String, code: String) async -> Bool? {
        if config.speak { await speaker.say(Self.speakable(question), language: language, voice: config.voice) }
        for attempt in 0 ..< 2 {
            if Task.isCancelled { return nil }
            guard let heard = try? await config.transcribe({ _ in }) else { return nil }
            if let a = Confirmation.answer(heard) { return a }
            if attempt == 0, config.speak, !Task.isCancelled {
                await speaker.say(code == "id" ? "Ya atau tidak?" : "Yes or no?", language: language, voice: config.voice)
            }
        }
        return nil
    }

    static func question(_ req: ConfirmRequest, code: String) -> String {
        code == "id"
            ? "Ini perlu izinmu: \(req.reason). Lanjutkan? Jawab ya atau tidak."
            : "This needs you: \(req.reason). Should I go ahead? Say yes or no."
    }

    /// Key glyphs and path arrows read as words.
    static func speakable(_ s: String) -> String {
        [("⌘", "command "), ("⌥", "option "), ("⌃", "control "), ("⇧", "shift "), ("⌫", "delete"),
         ("⎋", "escape"), (" › ", ", "), ("“", ""), ("”", "")]
            .reduce(s) { $0.replacingOccurrences(of: $1.0, with: $1.1) }
    }

    /// "Please open Microme." + "browser please" → one request.
    static func join(_ first: String, _ rest: String) -> String {
        first.trimmingCharacters(in: CharacterSet(charactersIn: ".!?, ").union(.whitespaces)) + " " + rest
    }

    /// Barge-in callback (audio monitor queue): abort the in-flight run at
    /// its next step check and cut any speech already playing.
    private func interrupted() {
        try? "stop".write(toFile: config.killSwitch, atomically: true, encoding: .utf8)
        speaker.stop()
        emit(.interrupted)
    }

    /// True when the utterance is a "go to sleep" phrase (case/locale-insensitive,
    /// prefix match so "stop dong" still works).
    ///
    /// Phrases that are also ordinary verbs ("matikan wifi", "tidur siang",
    /// "sleep mode") must be the WHOLE utterance — a leading "matikan" with
    /// an object is a command, not a bedtime wish. Unambiguous phrases like
    /// "stop"/"berhenti" still match as a prefix.
    public static func isStop(_ text: String, phrases: [String]) -> Bool {
        let exactOnly: Set<String> = ["matikan", "tidur", "istirahat", "sleep",
                                      "turn off", "shut down"]
        let t = text.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return phrases.contains { p in
            t == p || (!exactOnly.contains(p) &&
                       (t.hasPrefix(p + " ") || t.hasPrefix(p + ",")))
        }
    }

    private func emit(_ kind: ServeEvent.Kind, _ text: String = "",
                      record: StepRecord? = nil, dir: String? = nil) {
        writeState(kind, text)
        onEvent(ServeEvent(kind, text, record: record, dir: dir))
    }

    /// Publish state transitions for `s1 status`. Only lifecycle events land
    /// in the file — per-step noise stays in the event stream.
    private func writeState(_ kind: ServeEvent.Kind, _ text: String) {
        switch kind {
        case .armed, .listening, .runStart, .runDone, .sleeping, .stopped, .idle: break
        default: return
        }
        let json = Self.stateJSON(state: state.rawValue, event: kind.rawValue,
                                  detail: text, pid: ProcessInfo.processInfo.processIdentifier)
        try? FileManager.default.createDirectory(
            atPath: (Self.statePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? json.write(toFile: Self.statePath, atomically: true, encoding: .utf8)
    }

    /// Builds the state-file JSON — static so tests can verify escaping.
    /// Hand-rolled: backslash must escape first or it double-escapes; without
    /// it a "C:\foo"-style detail makes the file unparseable for `s1 status`.
    static func stateJSON(state: String, event: String, detail: String, pid: Int32) -> String {
        var e = detail.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
        // Other control chars (tab, BEL, …) are also invalid raw inside a
        // JSON string — the file must stay parseable no matter what a
        // transcript or model reply carried.
        e = e.terminalSafe
        e = String(e.prefix(120))
        // Truncation can slice a "\\" pair in half — a trailing lone
        // backslash would escape the closing quote and corrupt the file.
        while e.hasSuffix("\\") { e.removeLast() }
        let iso = ISO8601DateFormatter().string(from: Date())
        return "{\"state\":\"\(state)\",\"event\":\"\(event)\","
            + "\"detail\":\"\(e)\",\"pid\":\(pid),\"updated\":\"\(iso)\"}"
    }
}
