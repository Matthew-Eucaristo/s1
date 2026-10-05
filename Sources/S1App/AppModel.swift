import AppKit
import Foundation
import S1Core
import SwiftUI
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
        case auto, ax
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .auto: return "Auto (grammar + judge model)"
            case .ax:   return "AX (instant, no model)"
            }
        }
    }

    var goal = ""
    var transcript = "" { didSet { syncHUD() } }
    var brain: Brain = .auto { didSet { rearmServe() } }
    /// "auto" = detect Indonesian/English (+ the Mac's language) per turn.
    var locale = SpokenLanguage.auto { didSet { rearmServe(); invalidateStt() } }
    /// Pinned TTS voice identifier; "" = best installed voice per language.
    var ttsVoice = "" { didSet { rearmServe() } }
    /// Hard steps always escalate to S2 — the safety design, not a toggle.
    /// Left as a var so model-assignment helpers can set it harmlessly.
    var useS2 = true
    var speakReply = true { didSet { rearmServe() } }
    /// Voice interrupt (barge-in): talk over a run or the reply to stop it.
    var voiceInterrupt = true { didSet { rearmServe() } }
    /// Turn-end detector: "auto" = Apple SpeechDetector + energy; "energy"
    /// = RMS endpointer only. Applied at SpeechToText construction.
    var vadMode = "auto" { didSet { invalidateStt(); scheduleSave() } }
    var vadSensitivity = "medium" { didSet { invalidateStt(); scheduleSave() } }
    /// Text fields debounce — rearming the hotkey per keystroke would tear
    /// the tap down and back up while the user is still typing.
    var vlmBase = "http://localhost:11434/v1" { didSet { scheduleRearm() } }
    var vlmModel = "" { didSet { scheduleRearm() } }
    /// S2 (the escalation reasoner) gets its own endpoint — often a bigger
    /// model than S1's, or a cloud one behind an API key.
    var s2Base = Endpoints.defaultS2Base { didSet { scheduleRearm() } }
    var s2Model = Endpoints.defaultS2Model { didSet { scheduleRearm() } }
    /// VLM brains see a screenshot every step when on (richer grounding,
    /// more tokens + Screen Recording needed); off = AX-tree-only prompts.
    var vlmScreenshot = true { didSet { scheduleRearm() } }
    /// Optional GUI-grounding model for click targets ("" = none). Read
    /// from config by VLMPolicy at run time, so a save is enough.
    var grounderModel = "" { didSet { scheduleSave() } }
    /// S1 decision model (System One API) — empty = no judge.
    var decisionBase = Endpoints.defaultDecisionBase { didSet { scheduleRearm() } }
    var decisionModel = Endpoints.defaultDecisionModel { didSet { scheduleRearm() } }
    /// The configured judge model is pulled into local Ollama (or remote).
    var decisionReady: Bool {
        let m = decisionModel.trimmingCharacters(in: .whitespaces)
        guard !m.isEmpty else { return false }
        return !decisionIsLocal || ModelPull.contains(installedModels, m)
    }
    var decisionIsLocal: Bool {
        let host = URL(string: decisionBase)?.host?.lowercased() ?? ""
        return host == "localhost" || host == "127.0.0.1"
    }
    /// Bumped to pull focus into the command field (⌘N).
    var focusGoalToken = 0
    /// Bumped on Keychain writes so views re-read key presence.
    private(set) var keyRevision = 0
    /// User's extra STT words (comma-separated). Read at transcribe time,
    /// so edits need only a config save — no companion restart.
    var vocabulary = "" { didSet { scheduleSave(); invalidateStt() } }
    /// Selected Settings tab — the launcher deep-links to "snippets".
    var settingsTab = "general"
    /// Set by a live SwiftUI view holding `openSettings`; AppKit callers
    /// (the launcher panel) go through this.
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    func openSettings(_ tab: String) {
        settingsTab = tab
        NSApp.activate()
        if let openSettingsAction { openSettingsAction() } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }
    /// Optional cloud speech (empty model = on-device Apple speech).
    var sttBase = "https://api.groq.com/openai/v1" { didSet { scheduleRearm() } }
    var sttModel = "" { didSet { scheduleRearm() } }
    var ttsBase = "https://api.groq.com/openai/v1" { didSet { scheduleRearm() } }
    var ttsModel = "" { didSet { scheduleRearm() } }
    var ttsCloudVoice = "" { didSet { scheduleRearm() } }

    /// Shell sandbox (Anthropic sandbox-runtime) — off by default; Settings
    /// → General flips it. Persists as `sandbox: "srt"` in config.json.
    var sandboxSrt = false { didSet { scheduleSave() } }

    /// First-run state: the onboarding window opens whenever this flips
    /// true (launch + "Set Up s1 Again…"). Persisted as `onboarded`.
    var needsOnboarding = false

    /// Cua Driver install (onboarding + Settings → Executor).
    private(set) var cuaInstalling = false
    private(set) var cuaInstallLog = ""
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
        }
    }

    /// One tap: pull a catalog/model name into Ollama. On finish the model
    /// auto-assigns — a judge model to decision, anything else to S2.
    func pullModel(_ name: String, decision: Bool = false) {
        guard pullProgress[name] == nil else { return }
        pullProgress[name] = "starting…"
        Task {
            do {
                try await ModelPull.pull(model: name) { line in
                    Task { @MainActor in self.pullProgress[name] = line }
                }
                pullProgress[name] = nil
                refreshModels()
                if decision { useAsDecision(name) } else { useAsS2(name) }
                s2Status.refresh()
            } catch {
                pullProgress[name] = "failed: \(error.localizedDescription)"
            }
        }
    }

    /// Installed row → wire it into the matching slot without re-downloading.
    func useAsS2(_ name: String) { s2Model = name; useS2 = true }
    func useAsDecision(_ name: String) {
        decisionBase = "http://localhost:11434"; decisionModel = name
        rearmServe()   // the judge endpoint is resolved when serve arms
    }
    /// Settings → Voice → Preview: one line in each candidate language.
    func previewVoice() {
        let voice = ttsVoice.isEmpty ? nil : ttsVoice
        let langs = SpokenLanguage.candidates(for: locale)
        Task {
            for l in langs {
                let id = SpokenLanguage.code(l) == "id"
                await speaker.say(id ? "Halo, aku s1. Siap membantu." : "Hi, I'm s1. Ready when you are.",
                                  language: l.identifier, voice: voice, timeout: 8)
            }
        }
    }

    /// ⌘K — empty the step feed (artifacts on disk stay).
    func clearFeed() {
        guard !running else { return }
        steps = []; feed = []; runDir = nil; transcript = ""; status = "idle"
    }
    private(set) var steps: [StepRecord] = [] { didSet { syncHUD() } }
    /// The chat-style feed the main window renders — goals, steps, and
    /// turn replies in order. `steps` stays the step-only view (HUD, ⌘K).
    private(set) var feed: [FeedItem] = []
    private func appendFeed(_ kind: FeedItem.Kind) {
        feed.append(.init(kind: kind))
        if feed.count > 400 { feed.removeFirst(feed.count - 400) }
    }
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
        vocabulary.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    /// Settings → Voice → Custom words: the list editor's model.
    var vocabularyList: [String] { parsedVocab }
    func addVocabularyWord(_ w: String) {
        let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        guard !parsedVocab.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        vocabulary = (parsedVocab + [t]).joined(separator: ", ")
    }
    func removeVocabularyWord(_ w: String) {
        vocabulary = parsedVocab.filter { $0 != w }.joined(separator: ", ")
    }
    /// Cached: Vocabulary.assemble scans /Applications and locale changes
    /// rebuild the recognizer — neither belongs on a per-access path.
    private var _stt: SpeechToText?
    private var stt: SpeechToText {
        if let _stt { return _stt }
        let s = SpeechToText(locales: SpokenLanguage.candidates(for: locale),
                             vocabulary: Vocabulary.assemble(custom: parsedVocab),
                             vadMode: SpeechToText.VadMode(rawValue: vadMode),
                             vadSensitivity: SpeechToText.VadSensitivity(rawValue: vadSensitivity))
        _stt = s
        // Pre-warm the model assets so the first listen isn't cold-slow.
        Task { await s.warmup() }
        return s
    }
    private func invalidateStt() { _stt = nil }
    private var serve: Serve?
    private var rearmTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    /// One-click model install state for the S2 endpoint — the closures
    /// read the user's live field edits, so a changed base/model is what
    /// refreshes. (`lazy` is off-limits under @Observable — wired in init.)
    let s2Status: ModelPullStatus

    init() {
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
        if let v = cfg.voiceInterrupt { voiceInterrupt = v }
        if let v = cfg.vad { vadMode = v }
        if let v = cfg.vadSensitivity { vadSensitivity = v }
        if let v = cfg.vocabulary { vocabulary = v.joined(separator: ", ") }
        if let r = cfg.recent { recentGoals = r }
        if let e = cfg.stt { sttBase = e.base ?? sttBase; sttModel = e.model ?? "" }
        if let e = cfg.tts { ttsBase = e.base ?? ttsBase; ttsModel = e.model ?? "" }
        if let v = cfg.ttsCloudVoice { ttsCloudVoice = v }
        if let vs = cfg.vlmScreenshot { vlmScreenshot = vs }
        // Old "vlm" values decode to nil → falls back to .auto.
        if let b = cfg.brain, let kind = Brain(rawValue: b) { brain = kind }
        if let n = cfg.notchHUD { notchHUD = n }
        if let g = cfg.grounder?.model { grounderModel = g }
        if let b = cfg.decision?.base { decisionBase = b }
        if let m = cfg.decision?.model { decisionModel = m }
        if let v = cfg.voice { ttsVoice = v }
        sandboxSrt = cfg.sandbox == "srt"
        needsOnboarding = cfg.onboarded != true

        // Status providers read the live fields (typed-but-unsaved edits
        // count immediately) — wired post-init since they capture self.
        s2Status.ep = { [weak self] in self?.s2Endpoint() ?? Endpoints.s2() }

        refreshPermissions()
        refreshModels()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startServe()
        LauncherController.shared.install()
        // TCC grants land in System Settings while s1 is open — re-check
        // when the app reactivates so the sidebar stops showing stale ⚠
        // without forcing a relaunch.
        Task {
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification) {
                refreshPermissions()
            }
        }
        // AXIsProcessTrusted is live — poll while a grant is missing so the
        // banner clears the moment the toggle flips, focus change or not.
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                if !self.permissions.accessibility || !self.permissions.inputMonitoring {
                    self.refreshPermissions()
                }
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

    /// VLM endpoint — kept for config compat (`s1 --policy vlm` on the CLI
    /// still reads the same config); the app's brain picker no longer
    /// exposes a model-only mode.
    private func vlmEndpoint() -> Endpoint {
        let env = ProcessInfo.processInfo.environment
        return Endpoints.vlm(
            base: env["S1_VLM_BASE"] == nil ? vlmBase : nil,
            model: env["S1_VLM_MODEL"] == nil ? vlmModel : nil)
    }

    private func startServe() {
        let langs = SpokenLanguage.candidates(for: locale)
        let voiceID = ttsVoice.isEmpty ? nil : ttsVoice
        let brainKind = brain
        let s2On = !s2Endpoint().needsKey   // hard steps always escalate
        let speakOn = speakReply
        // Resolve endpoints now (MainActor) — the closures Serve holds are
        // non-isolated and must not reach back into the model.
        let s2Ep = s2Endpoint()
        let decisionEp = decisionEndpoint()
        let s = Serve(
            config: .init(
                makePolicy: {
                    // auto = deterministic grammar with the judge model
                    // voting on each step; ax = grammar alone, zero model
                    // calls. `wrapIfConfigured` degrades to the bare policy
                    // when no judge endpoint is configured.
                    let pol: any Policy = AXPolicy()
                    return brainKind == .auto
                        ? JudgedPolicy.wrapIfConfigured(pol, endpoint: decisionEp)
                        : pol
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
                return S1Runner.anotherRunActive() },
                languages: langs, voice: voiceID,
                voiceInterrupt: voiceInterrupt),
            locale: langs[0],
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
                    self.appendFeed(.goal(ev.text))
                    self.status = "running"
                case .step:
                    self.serveStatus = "running · \(ev.text)"
                    if let rec = ev.record {
                        self.steps.append(rec)
                        self.appendFeed(.step(rec))
                        // Serve mode runs forever — cap the feed so a day
                        // of voice turns can't grow the array unboundedly.
                        if self.steps.count > 300 { self.steps.removeFirst(self.steps.count - 300) }
                    }
                case .phase: self.serveStatus = ev.text
                case .runDone:
                    self.serveStatus = ev.text
                    self.status = ev.text
                    self.appendFeed(.reply(ev.text))
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
        cfg.voiceInterrupt = voiceInterrupt
        cfg.vad = vadMode
        cfg.vadSensitivity = vadSensitivity
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
        // Always written — an empty model is the explicit "judge off"; nil
        // would fall back to the hosted Jev default.
        cfg.decision = .init(base: decisionBase, model: decisionModel.trimmingCharacters(in: .whitespaces),
                             key: cfg.decision?.key, numCtx: nil)
        cfg.voice = ttsVoice.isEmpty ? nil : ttsVoice
        cfg.stt = .init(base: sttBase, model: sttModel, key: cfg.stt?.key)
        cfg.tts = .init(base: ttsBase, model: ttsModel, key: cfg.tts?.key)
        cfg.ttsCloudVoice = ttsCloudVoice.isEmpty ? nil : ttsCloudVoice
        cfg.sandbox = sandboxSrt ? "srt" : nil
        try? cfg.save()
    }

    /// Onboarding finished (or was skipped) — never ask again. Writes go
    /// through saveConfig so the flag lands with everything else.
    /// Onboarding finished (or was skipped) — never auto-ask again.
    func markOnboarded() {
        needsOnboarding = false
        var cfg = S1Config.load()
        cfg.onboarded = true
        try? cfg.save()
    }

    /// Re-open the wizard — "Set Up s1 Again…" menu item.
    func reopenOnboarding() { needsOnboarding = true }

    /// Install Cua Driver via CUA's own installer, streaming its output
    /// into `cuaInstallLog` for the wizard/settings to show live.
    func installCuaDriver() async {
        guard !cuaInstalling, !CuaInstaller.installed else { return }
        cuaInstalling = true
        cuaInstallLog = ""
        defer { cuaInstalling = false }
        do {
            try await CuaInstaller.install { [weak self] line in
                Task { @MainActor in
                    // Bound the streaming log — the installer can be chatty.
                    if (self?.cuaInstallLog.count ?? 0) > 8000 {
                        self?.cuaInstallLog = String((self?.cuaInstallLog ?? "").suffix(4000))
                    }
                    self?.cuaInstallLog += line + "\n"
                }
            }
            cuaInstallLog += "✓ installed — s1's executor will use it\n"
            // The driver carries its own TCC identity — without its own
            // Accessibility + Screen Recording grants every call fails over
            // to CGEvent. CUA's grant flow opens the real permission dialogs
            // attributed to com.trycua.driver; run it detached so the wizard
            // isn't pinned while the user clicks through System Settings.
            Task.detached {
                try? await CuaInstaller.grantPermissions { _ in }
            }
        } catch {
            cuaInstallLog += "✗ \(error.localizedDescription)\n"
        }
    }

    /// Connect a provider family: apply its best preset per role — one
    /// click wires S1/S2/STT/TTS for that provider.
    func connect(_ family: ProviderFamily) {
        var seen = Set<String>()
        for p in family.presets.sorted(by: { ($0.recommended ?? false) && !($1.recommended ?? false) }) {
            guard seen.insert(p.role).inserted else { continue }
            apply(p)
        }
        status = "\(family.name) connected"
    }

    /// Apply one preset's base+model to its role — the per-role model
    /// picker on a provider card goes through here.
    func apply(_ p: ProviderPreset) {
        switch p.role {
        case "decision": decisionBase = p.base; decisionModel = p.model
        case "s2": s2Base = p.base; s2Model = p.model
        case "vlm": vlmBase = p.base; vlmModel = p.model
        case "grounder": grounderModel = p.model
        case "stt": sttBase = p.base; sttModel = p.model
        case "tts":
            ttsBase = p.base; ttsModel = p.model
            if let v = p.voice { ttsCloudVoice = v }
        default: break
        }
        // connect() applies several presets at once — debounce so the
        // companion restarts once, not per role.
        scheduleRearm()
    }

    /// Provider-card key: one paste covers every role the family ships —
    /// same credential, stored once per role's Keychain account.
    func saveKey(_ key: String, forFamily fam: ProviderFamily) {
        for r in fam.roles.compactMap(ModelRole.init(rawValue:)) { saveKey(key, for: r) }
    }

    /// "Connected" on the card = a saved key under at least one covered
    /// role (keys store per role; one provider key unlocks all of them).
    func familyHasKey(_ fam: ProviderFamily) -> Bool {
        _ = keyRevision
        return fam.roles.compactMap(ModelRole.init(rawValue:)).contains { hasKey($0) }
    }

    /// Auto-test gate: a role is worth probing when a model is set and it
    /// has a credential — or its endpoint is local and needs none.
    func roleReady(_ role: ModelRole) -> Bool {
        let (base, name): (String, String) = switch role {
        case .decision: (decisionBase, decisionModel)
        case .s2: (s2Base, s2Model)
        case .vlm: (vlmBase, vlmModel)
        case .grounder: (vlmBase, grounderModel)
        case .stt: (sttBase, sttModel)
        case .tts: (ttsBase, ttsModel)
        }
        guard !name.isEmpty else { return false }
        return hasKey(role) || Endpoints.isLocal(base)
    }

    /// The live decision endpoint (typed-but-unsaved edits count); env wins.
    func decisionEndpoint() -> Endpoint? {
        var cfg = S1Config.load()
        let m = decisionModel.trimmingCharacters(in: .whitespaces)
        cfg.decision = .init(base: decisionBase, model: m, key: cfg.decision?.key)
        return Endpoints.decision(config: cfg)
    }

    /// Hosted roles still waiting for an API key — drives the one-line
    /// setup hint in the main window (nothing shows once keys are in).
    var missingKeys: [String] {
        _ = keyRevision
        var out: [String] = []
        let d = decisionModel.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty, d.lowercased() != "off", !decisionIsLocal, !hasKey(.decision) { out.append("S1 (Jev)") }
        if s2Endpoint().needsKey { out.append("S2 (\(URL(string: s2Base)?.host ?? "LLM"))") }
        return out
    }

    /// Last 30 days of metered model calls, grouped by role + model.
    func usageSummary() -> [UsageLog.Summary] {
        UsageLog.summarize(UsageLog.load(since: Date().addingTimeInterval(-30 * 86_400)))
    }

    func hasKey(_ role: ModelRole) -> Bool {
        if SecretStore.has(account: role.rawValue) { return true }
        let c = S1Config.load()
        switch role {
        case .vlm: return c.vlm?.key != nil
        case .s2: return c.s2?.key != nil
        case .grounder: return c.grounder?.key != nil
        case .decision: return c.decision?.key != nil
        case .stt: return c.stt?.key != nil
        case .tts: return c.tts?.key != nil
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
            guard let ep = decisionEndpoint() else { return decisionModel.isEmpty ? "judge is off" : "\(decisionModel) not pulled — download it below" }
            do {
                let r = try await SystemOneClient(endpoint: ep, timeout: 120).evaluate(
                    state: .string("The user said: open TextEdit."),
                    questions: ["ok": .noul("Does the user want to open an app?")])
                let p = r.answers["ok"]?.noul.map { String(format: "%.2f", $0) } ?? "?"
                return "✓ \(r.model ?? ep.model) answered p(yes)=\(p) in \(ms())"
            } catch {
                return "✗ \(error.localizedDescription)"
            }
        case .stt, .tts:
            var cfg = S1Config.load()
            cfg.stt = .init(base: sttBase, model: sttModel); cfg.tts = .init(base: ttsBase, model: ttsModel)
            guard let ep = role == .stt ? Endpoints.stt(config: cfg) : Endpoints.tts(config: cfg) else {
                return (role == .stt ? sttModel : ttsModel).isEmpty ? "off — on-device" : "needs an API key"
            }
            switch await AutoPolicy.probe(ep) {
            case .reachableWithModel: return "✓ \(ep.model) available (\(ms()))"
            case .reachableMissingModel: return "server up, but '\(ep.model)' isn't listed"
            case .unreachable: return "✗ \(ep.baseURL) unreachable or key rejected"
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
        if !permissions.accessibility { PermRow.open("Privacy_Accessibility") }
    }

    /// A toggle that's ON in System Settings but not honored belongs to an
    /// older build (ad-hoc signatures change every update, TCC pins the old
    /// one). Drop S1's stale entry, then ask again so the current build is
    /// the one listed.
    func resetAccessibility() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.mattheweuc.s1"]
        try? p.run(); p.waitUntilExit()
        requestPermissions()
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

    // ---- dictation (⌃⌥D): speech → text pasted into the focused app ----
    private var dictation: MicControl?
    private var dictationDownAt = Date.distantPast

    /// Hold ⌃⌥D to talk (release ends the turn); a quick tap starts a
    /// VAD-ended turn, and a second tap stops it early.
    func dictationKeyDown() {
        if let d = dictation { d.stop(); return }
        let control = MicControl(holding: true)
        dictation = control
        dictationDownAt = Date()
        let target = NSWorkspace.shared.frontmostApplication
        Task { await dictate(control, into: target) }
    }

    func dictationKeyUp() {
        guard let d = dictation else { return }
        if Date().timeIntervalSince(dictationDownAt) > 0.4 { d.stop() } else { d.holding = false }
    }

    private func dictate(_ control: MicControl, into target: NSRunningApplication?) async {
        defer { dictation = nil }
        guard !listening, !running, serve?.state == .idle || serve == nil else {
            status = "busy — stop the current listen/run before dictating"; return
        }
        do { try S1Runner.claimMic() } catch { status = "mic is in use"; return }
        defer { S1Runner.releaseMic() }
        listening = true
        transcript = ""
        defer { listening = false }
        do {
            let text = try await stt.transcribeMic(maxSeconds: 120, control: control) { p in
                Task { @MainActor in self.transcript = p }
            }.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { status = "heard nothing"; return }
            transcript = text
            if AXIsProcessTrusted() {
                LauncherController.shared.paste(text, restore: true, into: target)
                status = "dictated \(text.count) chars"
            } else {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(text, forType: .string)
                status = "dictation copied — press ⌘V (grant Accessibility to paste automatically)"
            }
        } catch {
            status = "mic: \(error.localizedDescription)"
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
        appendFeed(.goal(goalText))
        runDir = nil
        status = "running"

        // auto = grammar + judge model; ax = grammar alone. Hard steps
        // always escalate to S2 when its endpoint has credentials.
        let base: any Policy = AXPolicy()
        let pol = brain == .auto
            ? JudgedPolicy.wrapIfConfigured(base, endpoint: decisionEndpoint())
            : base
        let reasoner: (any Reasoner)? = s2Endpoint().needsKey
            ? nil
            : LLMReasoner(endpoint: s2Endpoint())

        do {
            let (report, logger) = try await S1Runner.run(
                goal: goalText, policy: pol, artifacts: artifactsRoot,
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: killPath, s2: reasoner,
                onStep: { [weak self] rec in
                    Task { @MainActor [weak self] in
                        self?.steps.append(rec)
                        self?.appendFeed(.step(rec))
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
            } else if let answer = report.answer {
                status = answer
            } else if report.status == .escalatedToS2,
                      let last = recorded.last(where: { $0.escalation != nil }) {
                status = "S2 couldn't decide — \((last.rationale ?? "").prefix(160))"
            } else {
                status = report.status.rawValue
            }
            recentGoals.removeAll { $0 == goalText }
            recentGoals.insert(goalText, at: 0)
            if recentGoals.count > 8 { recentGoals.removeLast() }
            saveConfig()
            running = false
            let lang = SpokenLanguage.detect(goalText, among: SpokenLanguage.candidates(for: locale))?
                .identifier ?? "en-US"
            let code = SpokenLanguage.code(Locale(identifier: lang))
            let reply: String = if let answer = report.answer { answer } else {
                switch report.status {
                case .done: SpokenLanguage.reply(.done, languageCode: code)
                case .needsHuman: SpokenLanguage.reply(.needsHuman, languageCode: code)
                case .escalatedToS2: SpokenLanguage.reply(.couldNotWorkOut, languageCode: code)
                default: SpokenLanguage.reply(.stopped, languageCode: code)
                }
            }
            appendFeed(.reply(status))
            if speakReply {
                // A user Stop means silence — never announce after the fact.
                if !FileManager.default.fileExists(atPath: killPath) {
                    await speaker.say(reply, language: lang, voice: ttsVoice.isEmpty ? nil : ttsVoice)
                }
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
                    Task { @MainActor in self.state = .downloading(line) }
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

/// One entry in the main window's conversation feed — the goal the user
/// asked for, a step the agent took, or the turn's closing line.
struct FeedItem: Identifiable {
    enum Kind {
        case goal(String)
        case step(StepRecord)
        case reply(String)
    }
    let kind: Kind
    let id = UUID()
}
