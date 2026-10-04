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
        case auto, ax, vlm
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto (model if reachable)"
            case .ax:   return "AX (instant, no model)"
            case .vlm:  return "VLM (model)"
            }
        }
    }

    var goal = ""
    var transcript = "" { didSet { syncHUD() } }
    var brain: Brain = .auto { didSet { rearmServe() } }
    /// Cached endpoint probe for the auto brain — read inside Serve's
    /// @Sendable makePolicy, so it lives in a lock box, not MainActor state.
    /// Unknown while the first probe is in flight → auto degrades to ax
    /// for that utterance, then resolves once the answer lands.
    private let vlmAlive = LockedFlag()
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
    /// Optional GUI-grounding model for click targets ("" = none). Read
    /// from config by VLMPolicy at run time, so a save is enough.
    var grounderModel = "" { didSet { scheduleSave() } }
    /// S1 decision model (System One API) — empty = no judge.
    var decisionBase = "http://localhost:11434" { didSet { scheduleRearm() } }
    var decisionModel = "" { didSet { scheduleRearm() } }
    /// Bumped on Keychain writes so views re-read key presence.
    private(set) var keyRevision = 0
    var showConnections = false
    /// User's extra STT words (comma-separated). Read at transcribe time,
    /// so edits need only a config save — no companion restart.
    var vocabulary = "" { didSet { scheduleSave(); invalidateStt() } }
    /// Floating status pill under the camera notch while s1 is doing
    /// something. Off = the window never exists (see NotchHUD.swift).
    var notchHUD = true { didSet { if !notchHUD { hud.hide() }; scheduleSave() } }

    // MARK: - model library (one-click downloads)

    /// Models `ollama list` reports — refreshed on appear and after pulls.
    private(set) var installedModels: [String] = []
    /// Live download line per model name while a pull is in flight.
    var pullProgress: [String: String] = [:]
    /// The shipped shortlist (S1Core) minus what's already installed.
    var catalog: [ModelPull.CatalogEntry] { ModelPull.catalog }
    /// True while any pull runs — the section shows one progress at a time.
    var pullInFlight: Bool { !pullProgress.isEmpty }
    /// Ollama CLI found on disk?
    var ollamaPresent: Bool { ModelPull.ollamaBinary() != nil }

    /// Read `ollama list` off the main actor — Process.waitUntilExit is
    /// synchronous; keep it off the UI thread.
    func refreshModels() {
        Task {
            let names = await Task.detached { ModelPull.installed() }.value
            self.installedModels = names
            self.adoptPulledBrainIfUnset(names)
        }
    }

    /// A terminal `ollama pull` never reaches pullModel(), so the endpoint
    /// can keep asking for a model that isn't there. When the user never
    /// picked a brain (still on the default) and exactly one catalog-vision
    /// model is installed, adopt it — the pull's intent was obvious.
    private func adoptPulledBrainIfUnset(_ installed: [String]) {
        guard vlmModel == "gemma3:4b", !installed.contains("gemma3:4b") else { return }
        let vision = installed.filter { n in
            guard let e = ModelPull.catalog.first(where: { $0.name == n }) else { return false }
            return e.vision && !e.grounding
        }
        if vision.count == 1, let only = vision.first { useAsBrain(only) }
    }

    /// One tap: pull a catalog/model name into Ollama. On finish the model
    /// auto-assigns — a vision model becomes the S1 brain, a text-only
    /// model becomes S2 — matching how the catalog describes them.
    func pullModel(_ name: String, vision: Bool, grounding: Bool = false) {
        guard pullProgress[name] == nil else { return }
        pullProgress[name] = "starting…"
        Task {
            do {
                try await ModelPull.pull(model: name) { [weak self] line in
                    Task { @MainActor in self?.pullProgress[name] = line }
                }
                pullProgress[name] = nil
                refreshModels()
                if grounding {
                    useAsGrounder(name)
                } else if vision {
                    vlmModel = name; brain = .vlm
                } else {
                    s2Model = name; useS2 = true
                }
                vlmStatus.refresh(); s2Status.refresh()
            } catch {
                pullProgress[name] = "failed: \(error.localizedDescription)"
            }
        }
    }

    /// Installed row → wire it into the matching slot without re-downloading.
    func useAsBrain(_ name: String) { vlmModel = name; brain = .vlm }
    func useAsS2(_ name: String) { s2Model = name; useS2 = true }
    /// Grounding only runs on the VLM brain's click steps — pick it too
    /// unless the user already chose a model brain.
    func useAsGrounder(_ name: String) {
        grounderModel = name
        if brain == .ax { brain = .auto }
    }

    private(set) var steps: [StepRecord] = [] { didSet { syncHUD() } }
    private(set) var status = "idle" { didSet { syncHUD() } }
    private(set) var running = false { didSet { syncHUD() } }
    private(set) var listening = false { didSet { syncHUD() } }
    private(set) var runDir: String?
    private(set) var permissions = PermissionReport()

    // ---- always-on companion (hotkey -> continuous listening -> run -> listen) ----
    private(set) var serveState: Serve.State = .idle { didSet { syncHUD() } }
    private(set) var serveStatus = "hotkey armed: ⇧⇧ or ⌃⌥Space" { didSet { syncHUD() } }
    var launchAtLogin = false

    private let speaker = Speaker()
    private let hud = NotchHUDController()
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
    /// Slow re-probe while `auto` finds the endpoint down — Ollama coming
    /// up after launch must upgrade the brain without a settings change.
    private var vlmProbeTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// One-click model install state per endpoint — the closures read the
    /// user's live field edits, so a changed base/model is what refreshes.
    /// (`lazy` is off-limits under @Observable — these get wired in init.)
    let vlmStatus: ModelPullStatus
    let s2Status: ModelPullStatus

    init() {
        vlmStatus = ModelPullStatus { Endpoints.vlm() }
        s2Status = ModelPullStatus { Endpoints.s2() }
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
        if let n = cfg.notchHUD { notchHUD = n }
        if let g = cfg.grounder?.model { grounderModel = g }
        if let b = cfg.decision?.base { decisionBase = b }
        if let m = cfg.decision?.model { decisionModel = m }

        // Status providers read the live fields (typed-but-unsaved edits
        // count immediately) — wired post-init since they capture self.
        vlmStatus.ep = { [weak self] in self?.vlmEndpoint() ?? Endpoints.vlm() }
        s2Status.ep = { [weak self] in self?.s2Endpoint() ?? Endpoints.s2() }

        refreshPermissions()
        refreshModels()
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
        let decisionEp = decisionEndpoint()
        let box = vlmAlive
        // Any rearm replaces the upgrade probe — a brain switch away from
        // `auto` must kill it outright, not leave it polling.
        vlmProbeTask?.cancel()
        if brainKind == .auto {
            box.value = nil   // re-probe on each rearm — the server may have come up
            Task { box.value = await AutoPolicy.endpointAlive(vlmEp) }
            // That one shot isn't enough for a long-lived companion: if the
            // endpoint comes up later, auto would stay pinned to `ax` until
            // some unrelated rearm. Probe slowly while down — upgrade only;
            // a mid-run endpoint death still errors honestly per step.
            vlmProbeTask = Task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(60))
                    if Task.isCancelled || box.value == true { return }
                    if await AutoPolicy.endpointAlive(vlmEp) {
                        box.value = true
                        return
                    }
                }
            }
        }
        let s = Serve(
            config: .init(
                makePolicy: {
                    let wantsModel = brainKind == .vlm
                        || (brainKind == .auto && box.value == true)
                    let pol: any Policy = wantsModel
                        ? VLMPolicy(endpoint: vlmEp, useScreenshot: shot)
                        : AXPolicy()
                    return JudgedPolicy.wrapIfConfigured(pol, endpoint: decisionEp)
                },
                s2: s2On ? LLMReasoner(endpoint: s2Ep) : nil,
                speak: speakOn,
                artifacts: artifactsRoot,
                // One stop file for the app: Stop (⌘.) aborts serve-driven
                // runs the same as Run-button runs — and `s1 stop` writes
                // it too. The serve loop also sleeps on seeing it.
                killSwitch: killPath,
                lockPath: NSHomeDirectory() + "/.s1/serve.pid",
                transcribe: { [weak self] onPartial in
                    guard let self else { return "" }
                    return try await self.stt.transcribeMic(maxSeconds: 12, onPartial: onPartial)
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
                // Words landing while the user is still speaking — volatile
                // partials, never the final goal text.
                case .partial: self.transcript = ev.text
                case .heard: self.serveStatus = "heard: \(ev.text)"; self.transcript = ev.text
                case .runStart:
                    self.serveState = .running
                    self.serveStatus = "running: \(ev.text)"
                    // Companion turns get the same live feed as the Run
                    // button — a voice turn should show its steps, not just
                    // its status line.
                    self.steps = []
                    self.status = "running"
                case .step:
                    self.serveStatus = "running · \(ev.text)"
                    if let rec = ev.record {
                        self.steps.append(rec)
                        // Serve mode runs forever — cap the feed so a day
                        // of voice turns can't grow the array unboundedly.
                        if self.steps.count > 300 { self.steps.removeFirst(self.steps.count - 300) }
                    }
                case .phase: self.serveStatus = ev.text
                case .runDone:
                    self.serveStatus = ev.text
                    self.status = ev.text
                    if let dir = ev.dir { self.runDir = dir }
                case .sleeping: self.serveState = .idle; self.serveStatus = "idle (sleeping)"
                case .stopped: self.serveState = .idle; self.serveStatus = "stopped"
                // "last run" framing: the line lingers until the next event —
                // "error:" alone looked like a live stuck state.
                case .error: self.serveStatus = "last run failed: \(ev.text)"
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
        cfg.notchHUD = notchHUD
        cfg.grounder = grounderModel.isEmpty ? nil
            : .init(base: cfg.grounder?.base, model: grounderModel,
                    key: cfg.grounder?.key, numCtx: cfg.grounder?.numCtx)
        cfg.decision = decisionModel.trimmingCharacters(in: .whitespaces).isEmpty ? nil
            : .init(base: decisionBase, model: decisionModel.trimmingCharacters(in: .whitespaces),
                    key: cfg.decision?.key, numCtx: nil)
        try? cfg.save()
    }

    /// The live decision endpoint (typed-but-unsaved edits count); env wins.
    func decisionEndpoint() -> Endpoint? {
        var cfg = S1Config.load()
        let m = decisionModel.trimmingCharacters(in: .whitespaces)
        cfg.decision = m.isEmpty ? nil : .init(base: decisionBase, model: m, key: cfg.decision?.key)
        return Endpoints.decision(config: cfg)
    }

    func hasKey(_ role: ModelRole) -> Bool {
        if SecretStore.has(account: role.rawValue) { return true }
        let c = S1Config.load()
        switch role {
        case .vlm: return c.vlm?.key != nil
        case .s2: return c.s2?.key != nil
        case .grounder: return c.grounder?.key != nil
        case .decision: return c.decision?.key != nil
        }
    }

    func saveKey(_ key: String, for role: ModelRole) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do {
            try SecretStore.set(k, account: role.rawValue)
            try S1Config.stripPlaintextKey(role)
            status = "\(role.rawValue) key saved to Keychain"
        } catch {
            status = "keychain: \(error.localizedDescription)"
        }
        keyRevision += 1
        scheduleRearm()
    }

    func removeKey(for role: ModelRole) {
        SecretStore.delete(account: role.rawValue)
        try? S1Config.stripPlaintextKey(role)
        status = "\(role.rawValue) key removed"
        keyRevision += 1
        scheduleRearm()
    }

    /// One real round-trip per role — a 200 from /models isn't proof the
    /// decision API exists, so the decision role asks an actual question.
    func testConnection(_ role: ModelRole) async -> String {
        let started = Date()
        func ms() -> String { "\(Int(Date().timeIntervalSince(started) * 1000)) ms" }
        switch role {
        case .decision:
            guard let ep = decisionEndpoint() else { return "set a model first" }
            do {
                let r = try await SystemOneClient(endpoint: ep, timeout: 120).evaluate(
                    state: .string("The user said: open TextEdit."),
                    questions: ["ok": .noul("Does the user want to open an app?")])
                let p = r.answers["ok"]?.noul.map { String(format: "%.2f", $0) } ?? "?"
                return "✓ \(r.model ?? ep.model) answered p(yes)=\(p) in \(ms())"
            } catch {
                return "✗ \(error.localizedDescription)"
            }
        case .vlm, .grounder, .s2:
            let ep = role == .s2 ? s2Endpoint() : vlmEndpoint()
            switch await AutoPolicy.probe(ep) {
            case .reachableWithModel: return "✓ \(ep.model) available (\(ms()))"
            case .reachableMissingModel: return "server up, but '\(ep.model)' isn't listed"
            case .unreachable: return "✗ \(ep.baseURL) unreachable or key rejected"
            }
        }
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

    /// Hotkey-equivalent toggle for menu/UI buttons. A nil companion means
    /// a CLI `s1 serve` owns the listener slot — say so instead of silently
    /// doing nothing when the button is tapped.
    func toggleServe() {
        guard let s = serve else {
            serveStatus = "companion off — a CLI `s1 serve` holds the listener"
            return
        }
        s.toggle()
    }

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
        // The mic lock is shared with the CLI daemon and foreground
        // `s1 transcribe`/`s1 listen` — the companion's own state only
        // covers this process.
        do { try S1Runner.claimMic() } catch {
            status = "mic is in use — a CLI listener or capture owns it (`s1 stop` first)"
            return
        }
        defer { S1Runner.releaseMic() }
        listening = true
        status = "listening…"
        defer { listening = false; listenTask = nil }
        do {
            let text = try await stt.transcribeMic(maxSeconds: 20) { p in
                Task { @MainActor in self.transcript = p }
            }
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

        // Honor `.auto` here too — the companion probes vlmAlive when it
        // arms, but a window run can happen before (or without) arming, so
        // kick a probe when the answer is unknown rather than silently
        // degrading to the grammar.
        if brain == .auto && vlmAlive.value == nil {
            let box = vlmAlive
            Task { box.value = await AutoPolicy.endpointAlive(vlmEndpoint()) }
        }
        let wantsModel = brain == .vlm || (brain == .auto && vlmAlive.value == true)
        let pol = JudgedPolicy.wrapIfConfigured(
            wantsModel ? VLMPolicy(endpoint: vlmEndpoint(), useScreenshot: vlmScreenshot) : AXPolicy(),
            endpoint: decisionEndpoint())
        let reasoner: (any Reasoner)? = useS2
            ? LLMReasoner(endpoint: s2Endpoint())
            : nil

        do {
            let (report, logger) = try await S1Runner.run(
                goal: goalText, policy: pol, artifacts: artifactsRoot,
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: killPath, s2: reasoner,
                onStep: { [weak self] rec in
                    Task { @MainActor [weak self] in
                        self?.steps.append(rec)
                        if let n = self?.steps.count, n > 300 { self?.steps.removeFirst(n - 300) }
                    }
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
        // An in-flight listen doesn't check the kill file — cancel it too,
        // or Stop leaves the mic live until the turn times out.
        listenTask?.cancel()
        listenTask = nil
        listening = false
        speaker.stop()
        status = "stopping…"
    }

    /// Priority: listening (serve or one-shot mic) > running > a brief
    /// final-status flash > hidden. Every state-bearing property feeds
    /// this through didSet so the pill never lies about what's happening.
    private func syncHUD() {
        guard notchHUD else { return }
        if serveState == .listening || listening {
            hud.show(phase: .listening,
                     detail: transcript.isEmpty ? "hear a command…" : "heard: \(transcript)")
            return
        }
        if serveState == .running || running {
            let detail = serveState == .running
                ? serveStatus
                : steps.last.map { $0.digest } ?? status
            hud.show(phase: .running, detail: detail)
            return
        }
        // idle — flash the terminal outcome a beat, then release the panel.
        switch status {
        case "done", "aborted", "escalatedToS2", "needsHuman",
             "maxStepsReached", "stuckLoop":
            hud.flash(phase: .running, detail: status)
        case let s where s.hasPrefix("needs human") || s.hasPrefix("error:"):
            hud.flash(phase: .running, detail: s)
        default:
            hud.hide()
        }
    }

    /// The pill's stop control: sleeping the listener when it's awake,
    /// aborting whatever run is in flight otherwise.
    func hudStopTapped() {
        if serveState == .listening { toggleServe(); return }
        if serveState == .running || running { stop() }
    }

    func revealRunDir() {
        guard let runDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runDir)])
    }
}

/// Per-endpoint "is the model there" status + one-click `ollama pull`.
/// One instance per endpoint section (S1's VLM, S2's reasoner) — remote
/// endpoints just report `.remote` and the row hides itself.
@MainActor @Observable
final class ModelPullStatus {
    enum State: Equatable {
        case checking
        case installed
        case missing
        case downloading(String)
        case failed(String)
        case noOllama
        case unreachable
        case remote
    }

    private(set) var state: State = .checking
    /// The endpoint's display name — the model the pull targets.
    private(set) var modelName = ""
    /// Wired after init — callers can't capture self until it exists.
    var ep: @MainActor () -> Endpoint
    private var pullTask: Task<Void, Never>?

    init(_ ep: @escaping @MainActor () -> Endpoint = { Endpoints.vlm() }) { self.ep = ep }

    /// Re-probe — call on appear and after state that could change the
    /// answer (a pull finishing, a server starting).
    func refresh() {
        let e = ep()
        modelName = e.model
        guard e.isLocal else { state = .remote; return }
        guard pullTask == nil else { return }   // a pull in flight owns the state
        state = .checking
        Task { [weak self] in
            guard let self else { return }
            switch await AutoPolicy.probe(e) {
            case .reachableWithModel: self.state = .installed
            case .reachableMissingModel: self.state = .missing
            case .unreachable: self.state = .unreachable
            }
        }
    }

    /// `ollama pull` talks to the registry directly — it works even while
    /// the local server is down, so the button shows in `.unreachable` too.
    func pull() {
        guard pullTask == nil else { return }
        let e = ep()
        modelName = e.model
        guard ModelPull.ollamaBinary() != nil else { state = .noOllama; return }
        state = .downloading("starting…")
        lastAttempt = { [weak self] in self?.pull() }
        pullTask = Task { [weak self] in
            guard let self else { return }
            defer { self.pullTask = nil }
            do {
                try await ModelPull.pull(model: e.model) { line in
                    Task { @MainActor [weak self] in
                        self?.state = .downloading(line)
                    }
                }
                self.state = .checking
                self.refresh()
            } catch {
                self.state = .failed(error.localizedDescription)
            }
        }
    }

    /// Server down → bring it up. `ollama serve` detached survives the app
    /// (launchd reparents it); stderr is kept so an instant crash (port
    /// taken, binary too old for the OS, missing GPU libs) tells the user
    /// WHY instead of spinning "checking…" forever.
    func startServer() {
        guard let bin = ModelPull.ollamaBinary() else { state = .noOllama; return }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["serve"]
        proc.standardOutput = FileHandle.nullDevice
        let errTail = LockedTail(capacity: 4)
        let errPipe = Pipe()
        proc.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { h in
            errTail.append(String(decoding: h.availableData, as: UTF8.self))
        }
        try? proc.run()
        lastAttempt = { [weak self] in self?.startServer() }
        state = .checking
        Task { [weak self] in
            // give serve a moment to bind before the first probe
            for _ in 0..<6 {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.pullTask == nil else { return }
                if !proc.isRunning {
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    let tail = errTail.lastLine()
                    self.state = .failed(
                        "ollama serve exited" + (tail.map { ": \($0)" } ?? ""))
                    return
                }
                self.refresh()
            }
            // refresh() probes async — settle before reading the verdict.
            try? await Task.sleep(for: .seconds(3))
            guard let self, self.pullTask == nil else { return }
            if case .unreachable = self.state {
                self.state = .failed(
                    "ollama serve didn't come up — check `ollama serve` in Terminal")
            }
        }
    }

    /// Redo whatever last failed — a pull or a server start.
    func retry() {
        if let lastAttempt { lastAttempt() } else { refresh() }
    }

    /// Remembered so .failed's Retry re-runs the right op, not always pull.
    private var lastAttempt: (() -> Void)?
}

/// Ring of the last N lines — `ollama serve` writes the crash reason to
/// stderr and we only want its tail for the status row.
final class LockedTail: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    private let capacity: Int
    init(capacity: Int) { self.capacity = capacity }
    func append(_ chunk: String) {
        lock.lock()
        for line in chunk.split(whereSeparator: \.isNewline) {
            let s = line.trimmingCharacters(in: .whitespaces)
            if !s.isEmpty {
                lines.append(s)
                if lines.count > capacity { lines.removeFirst(lines.count - capacity) }
            }
        }
        lock.unlock()
    }
    func lastLine() -> String? {
        lock.lock(); defer { lock.unlock() }
        // ollama prefixes each log with time= level= source= — keep just the msg.
        guard let raw = lines.last else { return nil }
        if let r = raw.range(of: "msg=", options: .backwards) { return String(raw[r.upperBound...]).trimmingCharacters(in: .init(charactersIn: "\"")) }
        return raw
    }
}

/// Lock-protected tri-state read from @Sendable closures (the auto brain's
/// endpoint probe lands off-actor; makePolicy reads it on whatever thread
/// the serve loop calls it from).
final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: Bool?
    var value: Bool? {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}
