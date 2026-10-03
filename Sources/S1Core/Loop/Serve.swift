import Foundation

/// Lifecycle events the serve daemon reports — UI and CLI both render these.
public struct ServeEvent: Sendable {
    public enum Kind: String, Sendable {
        case armed, idle, listening, heard, runStart, step, runDone, error, sleeping, stopped
    }
    public var kind: Kind
    public var text: String
    public init(_ kind: Kind, _ text: String = "") { self.kind = kind; self.text = text }
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
        /// Utterances that end the listening session instead of running.
        public var stopPhrases: [String]
        /// Injectable transcription — real path is the mic; tests/demos feed files.
        public var transcribe: @Sendable () async throws -> String

        public init(makePolicy: @escaping @Sendable () -> any Policy = { AXPolicy() },
                    s2: (any Reasoner)? = nil,
                    speak: Bool = true,
                    listenSeconds: Double = 12,
                    maxSilentTurns: Int = 3,
                    maxListenErrors: Int = 3,
                    artifacts: String = "artifacts",
                    killSwitch: String = NSTemporaryDirectory() + "s1-serve-stop",
                    stopPhrases: [String] = ["stop", "berhenti", "stop listening", "matikan", "tidur"],
                    transcribe: @escaping @Sendable () async throws -> String) {
            self.makePolicy = makePolicy
            self.s2 = s2
            self.speak = speak
            self.listenSeconds = listenSeconds
            self.maxSilentTurns = maxSilentTurns
            self.maxListenErrors = maxListenErrors
            self.artifacts = artifacts
            self.killSwitch = killSwitch
            self.stopPhrases = stopPhrases
            self.transcribe = transcribe
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

    private let config: Config
    private let speaker = Speaker()
    private let onEvent: @Sendable (ServeEvent) -> Void
    private var hotkey: Hotkey?
    private var listenTask: Task<Void, Never>?
    private let sayLanguage: String

    public init(config: Config, locale: Locale = Locale(identifier: "id-ID"),
                hotkeyPatterns: [HotkeyPattern]? = nil,
                onEvent: @escaping @Sendable (ServeEvent) -> Void) {
        self.config = config
        self.sayLanguage = locale.identifier
        self.onEvent = onEvent
        if let patterns = hotkeyPatterns {
            hotkey = Hotkey(patterns: patterns) { [weak self] in
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
            emit(.error, "hotkey monitor not installed — grant Accessibility + run in a GUI session")
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

    /// Hotkey/menu action: idle → start listening; listening/running → stop.
    public func toggle() {
        switch state {
        case .idle: wake()
        case .listening, .running: sleep()
        }
    }

    public func wake() {
        guard state == .idle else { return }
        try? FileManager.default.removeItem(atPath: config.killSwitch)
        setState(.listening)
        emit(.listening)
        // Chain behind the previous task's unwind: its defer must drop the
        // mic tap/engine BEFORE a new turn grabs the input device, or two
        // engines race on rapid wake→sleep→wake.
        let prev = listenTask
        listenTask = Task { [weak self] in
            _ = await prev?.value
            await self?.listenLoop()
        }
    }

    public func sleep() { sleep("") }

    private func sleep(_ reason: String) {
        listenTask?.cancel()
        listenTask = nil
        // Land the kill switch too — an in-flight run aborts at its next step
        // instead of finishing a task the user already cancelled.
        try? "stop".write(toFile: config.killSwitch, atomically: true, encoding: .utf8)
        // And cut any speech in flight — "sleep" should mean silent.
        speaker.stop()
        if state != .idle {
            setState(.idle)
            emit(.sleeping, reason)
        }
    }

    /// One full listen→run→listen cycle. Silence and STT errors count toward
    /// auto-sleep; a stop phrase ends the session; anything else becomes a goal.
    private func listenLoop() async {
        var silentTurns = 0
        var errors = 0
        while state == .listening, !Task.isCancelled {
            do {
                let text = try await config.transcribe()
                errors = 0
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if Self.isStop(trimmed, phrases: config.stopPhrases) {
                    emit(.heard, trimmed)
                    emit(.stopped, "stop phrase")
                    sleep()
                    return
                }
                if trimmed.isEmpty {
                    silentTurns += 1
                    if silentTurns >= config.maxSilentTurns {
                        sleep("silence")
                        return
                    }
                    continue
                }
                silentTurns = 0
                emit(.heard, trimmed)
                await run(goal: trimmed)
            } catch is CancellationError {
                return
            } catch {
                errors += 1
                emit(.error, error.localizedDescription)
                if errors >= config.maxListenErrors {
                    sleep("stt errors x\(errors)")
                    return
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    /// Run one goal through the full agent loop and speak the outcome.
    private func run(goal: String) async {
        setState(.running)
        emit(.runStart, goal)
        do {
            let (report, _) = try await S1Runner.run(
                goal: goal, policy: config.makePolicy(), artifacts: config.artifacts,
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: config.killSwitch,
                s2: config.s2,
                onStep: { [onEvent] rec in
                    onEvent(ServeEvent(.step, "step \(rec.index): \(rec.decidedBy)"))
                })
            emit(.runDone, report.status.rawValue)
            if config.speak {
                let reply = sayLanguage.hasPrefix("id") ? "Selesai" : "Done"
                await speaker.say(reply, language: sayLanguage)
            }
        } catch {
            emit(.error, error.localizedDescription)
        }
        if state == .running { setState(.listening) }
    }

    /// True when the utterance is a "go to sleep" phrase (case/locale-insensitive,
    /// prefix match so "stop dong" still works).
    public static func isStop(_ text: String, phrases: [String]) -> Bool {
        let t = text.lowercased().trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters))
        return phrases.contains { p in
            t == p || t.hasPrefix(p + " ") || t.hasPrefix(p + ",")
        }
    }

    private func emit(_ kind: ServeEvent.Kind, _ text: String = "") {
        onEvent(ServeEvent(kind, text))
    }
}
