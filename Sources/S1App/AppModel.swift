import AppKit
import Foundation
import S1Core
import ServiceManagement
import UniformTypeIdentifiers

/// Observable bridge between the SwiftUI shell and the S1Core agent loop.
/// `@Observable` (not ObservableObject+Combine) — the current Apple-recommended
/// state model for macOS 15+ apps.
@available(macOS 26, *)
@MainActor
@Observable
final class AppModel {
    /// The one model behind the window, the menu-bar companion, AND App
    /// Intents — a Siri/Shortcuts invocation drives the same instance the
    /// user sees, never a parallel agent.
    static let shared = AppModel()

    enum Brain: String, CaseIterable, Identifiable {
        case ax, vlm
        var id: String { rawValue }
        var title: String { self == .ax ? "AX (instant, no model)" : "VLM (model)" }
    }

    var goal = ""
    var transcript = ""
    var brain: Brain = .ax { didSet { rearmServe() } }
    var locale = "id-ID" { didSet { rearmServe(); invalidateStt() } }
    var useS2 = false { didSet { rearmServe() } }
    var speakReply = true { didSet { rearmServe() } }
    /// Text fields debounce — rearming the hotkey per keystroke would tear
    /// the tap down and back up while the user is still typing.
    var vlmBase = "http://localhost:11434/v1" { didSet { scheduleRearm() } }
    var vlmModel = "gemma3:4b" { didSet { scheduleRearm() } }
    /// S2 (the escalation reasoner) gets its own endpoint — often a bigger
    /// model than S1's, or a cloud one behind an API key.
    var s2Base = "http://localhost:11434/v1" { didSet { scheduleRearm() } }
    var s2Model = "gemma3:4b" { didSet { scheduleRearm() } }
    /// VLM brains see a screenshot every step when on (richer grounding,
    /// more tokens + Screen Recording needed); off = AX-tree-only prompts.
    var vlmScreenshot = true { didSet { scheduleRearm() } }
    /// User's extra STT words (comma-separated). Read at transcribe time,
    /// so edits need only a config save — no companion restart.
    var vocabulary = "" { didSet { scheduleSave(); invalidateStt() } }

    private(set) var steps: [StepRecord] = []
    private(set) var status = "idle"
    private(set) var running = false
    private(set) var listening = false
    private(set) var runDir: String?
    private(set) var permissions = PermissionReport()

    // ---- always-on companion (hotkey -> continuous listening -> run -> listen) ----
    private(set) var serveState: Serve.State = .idle
    private(set) var serveStatus = "hotkey armed: ⇧⇧ or ⌃⌥Space"
    var launchAtLogin = false

    private let speaker = Speaker()
    private let killPath = NSTemporaryDirectory() + "s1-app-stop"
    /// GUI apps launched from Finder/Spotlight have cwd "/" — a relative
    /// "artifacts" path lands on the read-only root. Anchor run output under
    /// the same home as the config file instead.
    private let artifactsRoot = NSHomeDirectory() + "/.s1/artifacts"
    private var parsedVocab: [String] {
        vocabulary.split(separator: ",").map { String($0) }
    }
    /// Cached: Vocabulary.assemble scans /Applications and locale changes
    /// rebuild the recognizer — neither belongs on a per-access path.
    private var _stt: SpeechToText?
    private var stt: SpeechToText {
        if let _stt { return _stt }
        let s = SpeechToText(locale: Locale(identifier: locale),
                             vocabulary: Vocabulary.assemble(custom: parsedVocab))
        _stt = s
        // Pre-warm the model assets so the first listen isn't cold-slow.
        Task { await s.warmup() }
        return s
    }
    private func invalidateStt() { _stt = nil }
    private var serve: Serve?
    private var rearmTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?

    init() {
        // ~/.s1/config.json seeds the app too — model choices made in the app
        // persist, and the CLI picks them up (and vice versa).
        let cfg = S1Config.load()
        if let l = cfg.locale { locale = l }
        if let b = cfg.vlm?.base { vlmBase = b }
        if let m = cfg.vlm?.model { vlmModel = m }
        if let b = cfg.s2?.base { s2Base = b }
        if let m = cfg.s2?.model { s2Model = m }
        if let s = cfg.speak { speakReply = s }
        if let v = cfg.vocabulary { vocabulary = v.joined(separator: ", ") }
        if let r = cfg.recent { recentGoals = r }
        if let vs = cfg.vlmScreenshot { vlmScreenshot = vs }
        if let b = cfg.brain, let kind = Brain(rawValue: b) { brain = kind }
        if let u = cfg.useS2 { useS2 = u }

        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startServe()
        // TCC grants land in System Settings while s1 is open — re-check
        // when the app reactivates so the sidebar stops showing stale ⚠
        // without forcing a relaunch.
        Task {
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification) {
                refreshPermissions()
            }
        }
    }

    /// Arm the companion: installs the global hotkey (double-tap Shift and
    /// ⌃⌥Space both work). Idle = zero mic, zero model — battery stays flat.
    /// S2 endpoint for app-initiated work — same resolution the CLI uses.
    /// The in-app field is the user's live choice: it beats the config file
    /// but NOT an env override (precedence stays flag > env > file > default).
    private func s2Endpoint() -> Endpoint {
        var e = Endpoints.s2()
        let env = ProcessInfo.processInfo.environment
        if env["S1_S2_BASE"] == nil { e.baseURL = s2Base }
        if env["S1_S2_MODEL"] == nil { e.model = s2Model }
        return e
    }

    /// VLM endpoint — same precedence as `s2Endpoint`.
    private func vlmEndpoint() -> Endpoint {
        let env = ProcessInfo.processInfo.environment
        return Endpoints.vlm(
            base: env["S1_VLM_BASE"] == nil ? vlmBase : nil,
            model: env["S1_VLM_MODEL"] == nil ? vlmModel : nil)
    }

    private func startServe() {
        let loc = locale
        let brainKind = brain
        let s2On = useS2
        let speakOn = speakReply
        let shot = vlmScreenshot
        // Resolve endpoints now (MainActor) — the closures Serve holds are
        // non-isolated and must not reach back into the model.
        let vlmEp = vlmEndpoint()
        let s2Ep = s2Endpoint()
        let s = Serve(
            config: .init(
                makePolicy: {
                    if brainKind == .vlm {
                        return VLMPolicy(endpoint: vlmEp,
                                         useScreenshot: shot)
                    }
                    return AXPolicy()
                },
                s2: s2On ? LLMReasoner(endpoint: s2Ep) : nil,
                speak: speakOn,
                artifacts: artifactsRoot,
                // One stop file for the app: Stop (⌘.) aborts serve-driven
                // runs the same as Run-button runs — and `s1 stop` writes
                // it too. The serve loop also sleeps on seeing it.
                killSwitch: killPath,
                lockPath: NSHomeDirectory() + "/.s1/serve.pid",
                transcribe: { [weak self] in
                    guard let self else { return "" }
                    return try await self.stt.transcribeMic(maxSeconds: 12)
                },
            isBusy: { [weak self] in
                // Our own Run button OR another process's agent (a CLI
                // `s1 run`/`s1 serve` holds ~/.s1/run.pid) owns the screen.
                if await self?.running == true { return true }
                return S1Runner.anotherRunActive() }),
            locale: Locale(identifier: loc),
            hotkeyPatterns: [Hotkey.doubleShift, Hotkey.defaultChord]
        ) { [weak self] ev in
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch ev.kind {
                case .armed: self.serveStatus = "hotkey armed: ⇧⇧ or ⌃⌥Space"
                case .listening: self.serveState = .listening; self.serveStatus = "listening…"
                case .heard: self.serveStatus = "heard: \(ev.text)"; self.transcript = ev.text
                case .runStart: self.serveState = .running; self.serveStatus = "running: \(ev.text)"
                case .step: self.serveStatus = "running · \(ev.text)"
                case .runDone: self.serveStatus = ev.text
                case .sleeping: self.serveState = .idle; self.serveStatus = "idle (sleeping)"
                case .stopped: self.serveState = .idle; self.serveStatus = "stopped"
                case .error: self.serveStatus = "error: \(ev.text)"
                case .idle: self.serveState = .idle
                }
            }
        }
        // Claim the listener slot BEFORE arming the hotkey: a `s1 serve`
        // CLI daemon holding serve.pid must not be stomped — `s1 stop`
        // would then kill the wrong process and two hotkey listeners would
        // double-trigger on every press. When it's taken, the window still
        // does one-shot runs; only the companion stays off.
        let pidPath = NSHomeDirectory() + "/.s1/serve.pid"
        do {
            try S1Runner.claimPidFile(pidPath, what: "s1 listener")
        } catch {
            s.disarm()
            serve = nil
            serveStatus = "a listener is already running — companion off"
            return
        }
        s.armHotkey()
        serve = s
    }

    /// Rebuild the serve config when brain/locale/s2/speak settings change —
    /// and persist them so `s1` CLI commands see the same brains.
    func rearmServe() {
        serve?.disarm()
        startServe()
        saveConfig()
    }

    private func saveConfig() {
        var cfg = S1Config.load()
        cfg.locale = locale
        cfg.speak = speakReply
        // Keep key/numCtx from the file — the app owns base/model, not the
        // credentials: wiping them on every save would break the CLI's auth.
        cfg.vlm = .init(base: vlmBase, model: vlmModel,
                        key: cfg.vlm?.key, numCtx: cfg.vlm?.numCtx)
        cfg.s2 = .init(base: s2Base, model: s2Model,
                       key: cfg.s2?.key, numCtx: cfg.s2?.numCtx)
        cfg.vocabulary = parsedVocab
        cfg.recent = recentGoals
        cfg.vlmScreenshot = vlmScreenshot
        cfg.brain = brain.rawValue
        cfg.useS2 = useS2
        try? cfg.save()
    }

    private func scheduleRearm() {
        rearmTask?.cancel()
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.rearmServe()
        }
    }

    /// Persist-only path for fields that don't affect the running companion.
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.saveConfig()
        }
    }

    /// Hotkey-equivalent toggle for menu/UI buttons.
    func toggleServe() { serve?.toggle() }

    /// The Serve object's own state — synchronous under its lock, unlike
    /// `serveState` which mirrors events through an async MainActor hop
    /// (so it still reads `idle` for a beat after toggle()).
    var serveIsListening: Bool {
        guard let s = serve else { return false }
        return s.state != .idle
    }

    func toggleLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            // Read back the truth rather than trusting the flag flip.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            status = "login item: \(error.localizedDescription)"
        }
    }

    /// Clean shutdown: disarm the hotkey, stop speech, then terminate.
    func shutdown() {
        serve?.disarm()
        speaker.stop()
        // Pid-checked release — if a CLI `s1 serve` daemon holds the lock
        // (our companion was refused), its file must survive our quit.
        S1Runner.releasePidFile(NSHomeDirectory() + "/.s1/serve.pid")
        NSApp.terminate(nil)
    }

    func refreshPermissions() {
        permissions = Preflight.check(request: false)
    }

    func requestPermissions() {
        permissions = Preflight.check(request: true)
    }

    /// File-picker STT path — also the testable path on mic-less machines.
    func pickAudioAndTranscribe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await transcribe(url) }
    }

    func transcribe(_ url: URL) async {
        listening = true
        status = "transcribing…"
        do {
            let text = try await stt.transcribe(file: url)
            transcript = text
            if !text.isEmpty { goal = text }
            status = text.isEmpty ? "heard nothing" : "transcribed"
        } catch {
            status = "stt: \(error.localizedDescription)"
        }
        listening = false
    }

    /// Mic → transcript → run. The voice-first path. Tapping the mic while
    /// it listens cancels — the task handle lives in `listenTask`.
    private var listenTask: Task<Void, Never>?

    func toggleListen() {
        if listening {
            listenTask?.cancel()
            listenTask = nil
            listening = false
            status = "stopped"
            return
        }
        listenTask = Task { await listenAndRun() }
    }

    func listenAndRun() async {
        guard !listening else { return }
        guard !running else { status = "a run is in progress — stop it first"; return }
        // One mic at a time: the companion can't share the input device,
        // and one agent at a time: two concurrent runs would fight the screen.
        // serve.state (synchronous, locked) — NOT serveState, which mirrors
        // through a Task hop and still reads .idle just after a hotkey wake.
        guard serve?.state != .listening else {
            status = "companion is listening — press ⇧⇧ / ⌃⌥Space to pause it first"
            return
        }
        guard serve?.state != .running else {
            status = "companion is running — wait or sleep it first"
            return
        }
        listening = true
        status = "listening…"
        defer { listening = false; listenTask = nil }
        do {
            let text = try await stt.transcribeMic(maxSeconds: 20)
            guard !Task.isCancelled else { return }
            transcript = text
            if text.isEmpty {
                status = "heard nothing"
            } else {
                goal = text
                status = "heard: \(text)"
                listening = false
                await run()
            }
        } catch {
            if !Task.isCancelled { status = "mic: \(error.localizedDescription)" }
        }
    }

    /// Goals the user has run, newest first — offered back for quick reruns.
    private(set) var recentGoals: [String] = []

    func run() async {
        guard !running else { return }
        // Synchronous lock-read like above — the mirrored serveState lags
        // a MainActor hop and could let a run start mid-companion-run.
        guard serve?.state != .running else {
            status = "companion is running — wait or sleep it first"
            return
        }
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goalText.isEmpty else { status = "nothing to run"; return }
        // A CLI `s1 run`/`s1 serve` owns the screen — same agent-one-at-a-
        // time rule as the companion guards above.
        guard !S1Runner.anotherRunActive() else {
            status = "another s1 run is in progress (CLI) — wait or run `s1 stop`"
            return
        }
        try? FileManager.default.removeItem(atPath: killPath)
        running = true
        steps = []
        runDir = nil
        status = "running"

        let pol: any Policy = brain == .vlm
            ? VLMPolicy(endpoint: vlmEndpoint(), useScreenshot: vlmScreenshot)
            : AXPolicy()
        let reasoner: (any Reasoner)? = useS2
            ? LLMReasoner(endpoint: s2Endpoint())
            : nil

        do {
            let (report, logger) = try await S1Runner.run(
                goal: goalText, policy: pol, artifacts: artifactsRoot,
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: killPath, s2: reasoner,
                onStep: { [weak self] rec in
                    Task { @MainActor [weak self] in self?.steps.append(rec) }
                })
            runDir = report.runDir
            // "needsHuman" alone is jargon — say what for (denylist, secure
            // field, irreversible). The triggering step carries the reason.
            // Read it from the log file, NOT the live `steps` array: those
            // arrive through MainActor Task hops that can still be in flight
            // when the run returns, so the reason lookup could race-empty.
            let recorded = (try? RunReader.steps(in: logger.runDir)) ?? steps
            if report.status == .needsHuman,
               let hit = recorded.last(where: { $0.gate.hasPrefix("needsHuman") || $0.escalation?.to == "human" }) {
                var why = hit.escalation?.reason ?? hit.gate
                // The gate label wraps its reason — "needsHuman(denylist: x)"
                // → "denylist: x", so the status doesn't stutter the prefix.
                if why.hasPrefix("needsHuman("), why.hasSuffix(")") {
                    why = String(why.dropFirst("needsHuman(".count).dropLast())
                }
                status = "needs human — \(why)"
            } else {
                status = report.status.rawValue
            }
            recentGoals.removeAll { $0 == goalText }
            recentGoals.insert(goalText, at: 0)
            if recentGoals.count > 8 { recentGoals.removeLast() }
            saveConfig()
            running = false
            if speakReply {
                let id = locale.hasPrefix("id")
                let reply: String = switch report.status {
                case .done: id ? "Selesai" : "Done"
                case .needsHuman, .escalatedToS2: id ? "Butuh kamu" : "Needs you"
                default: id ? "Berhenti" : "Stopped"
                }
                await speaker.say("\(reply): \(goalText)", language: locale)
            }
        } catch {
            status = "error: \(error.localizedDescription)"
        }
        running = false
        refreshPermissions()
    }

    func stop() {
        try? "stop".write(toFile: killPath, atomically: true, encoding: .utf8)
        speaker.stop()
        status = "stopping…"
    }

    func revealRunDir() {
        guard let runDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runDir)])
    }
}
