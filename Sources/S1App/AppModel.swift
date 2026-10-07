import AppKit
import Foundation
import S1Core
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// One request and everything s1 did about it — the unit the conversation
/// renders: your goal, the steps, the closing line.
struct Turn: Identifiable {
    enum State: Equatable {
        case running
        case done
        /// Stopped on purpose for a human: a secure field, an irreversible step.
        case needsYou
        case failed
        case stopped
    }

    let id = UUID()
    let goal: String
    let spoken: Bool
    let started = Date()
    var steps: [StepRecord] = []
    /// Live phase line while running ("thinking…", "skill: morning setup").
    var phase: String?
    var state: State = .running
    var reply: String?
    var runDir: String?
    var finished: Date?

    var duration: TimeInterval? { finished.map { $0.timeIntervalSince(started) } }
}

/// Observable bridge between the SwiftUI shell and the S1Core agent loop —
/// the one model behind the window, the menu-bar companion and App
/// Intents, so a Siri invocation drives the same agent the user sees.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    /// Providers + role assignments (Settings → Models).
    let models = ModelStore()

    // MARK: conversation

    var goal = ""
    private(set) var turns: [Turn] = [] { didSet { syncHUD() } }
    /// Live partial transcript while a mic turn is open.
    var transcript = "" { didSet { syncHUD() } }
    private(set) var running = false { didSet { syncHUD() } }
    private(set) var listening = false { didSet { syncHUD() } }
    /// A short-lived line for things that aren't a turn ("mic is busy").
    private(set) var notice: String?
    /// Bumped when a run lands on disk — the history sidebar reloads.
    private(set) var historyRevision = 0
    /// Bumped to pull focus into the composer (⌘N).
    var focusGoalToken = 0
    /// Goals the user has run, newest first.
    private(set) var recentGoals: [String] = []

    var currentTurn: Turn? { turns.last { $0.state == .running } }

    // MARK: companion

    private(set) var serveState: Serve.State = .idle { didSet { syncHUD() } }
    /// A reply is being spoken: the pill keeps it on screen until the voice
    /// ends or you talk over it, then turns into the listening pill.
    private(set) var speaking = false { didSet { syncHUD() } }
    /// False when a CLI `s1 serve` owns the listener slot.
    private(set) var companionAvailable = true
    var launchAtLogin = false
    var notchHUD = true { didSet { if !notchHUD && !booting { hud.hide() }; scheduleSave() } }

    // MARK: voice

    /// "auto" = detect per turn among English + the Mac's language.
    var locale = SpokenLanguage.auto { didSet { rearmServe(); invalidateStt() } }
    /// Pinned Apple voice identifier; "" = best installed per language.
    var ttsVoice = "" { didSet { scheduleRearm() } }
    /// Provider-side voice name when the speak role is a cloud model.
    var cloudVoice = "" { didSet { scheduleSave() } }
    var speakReply = true { didSet { scheduleRearm() } }
    var voiceInterrupt = true { didSet { scheduleRearm() } }
    var vadMode = "auto" { didSet { invalidateStt(); scheduleSave() } }
    var vadSensitivity = "medium" { didSet { invalidateStt(); scheduleSave() } }
    /// Custom STT words, comma-separated in memory, a list in config.
    var vocabulary = "" { didSet { scheduleSave(); invalidateStt() } }

    // MARK: system

    private(set) var permissions = PermissionReport()
    var sandboxSrt = false { didSet { scheduleSave() } }
    var needsOnboarding = false
    private(set) var cuaInstalling = false
    private(set) var cuaInstallLog = ""

    /// UI language: "system" follows macOS; anything else writes an
    /// AppleLanguages override that resolves at the next launch.
    var appLanguage = AppModel.launchLanguagePref() {
        didSet {
            if appLanguage == "system" {
                UserDefaults.standard.removeObject(forKey: "AppleLanguages")
            } else {
                UserDefaults.standard.set([appLanguage, "en"], forKey: "AppleLanguages")
            }
            UserDefaults.standard.set(appLanguage, forKey: "appLanguage")
            languageNeedsRelaunch = appLanguage != launchLanguage
        }
    }
    private(set) var languageNeedsRelaunch = false
    private let launchLanguage = AppModel.launchLanguagePref()

    /// s1 orange or the macOS accent — remembered per Mac.
    var accentChoice = AccentChoice(rawValue: UserDefaults.standard.string(forKey: "accent") ?? "") ?? .s1 {
        didSet { UserDefaults.standard.set(accentChoice.rawValue, forKey: "accent") }
    }
    var accent: Color { accentChoice == .s1 ? Theme.orange : Color(nsColor: .controlAccentColor) }
    /// Text drawn on an accent fill.
    var onAccent: Color { accentChoice == .s1 ? Theme.ink : .white }

    /// Selected Settings pane — deep links set it before opening.
    var settingsTab = "general"
    @ObservationIgnored var openSettingsAction: (() -> Void)?

    private let speaker = Speaker()
    private let hud = NotchHUDController()
    private let killPath = NSTemporaryDirectory() + "s1-app-stop"
    /// GUI apps launched from Finder have cwd "/" — anchor run output in ~/.s1.
    private let artifactsRoot = S1Home.path + "/artifacts"
    private var serve: Serve?
    private var rearmTask: Task<Void, Never>?
    private var saveTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    /// Seeding from config.json in init must not re-arm or re-save per field.
    @ObservationIgnored private var booting = true

    init() {
        if appLanguage == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
        // ~/.s1/config.json seeds the app; the CLI reads what the app writes.
        let cfg = S1Config.load()
        if let l = cfg.locale { locale = l }
        if let s = cfg.speak { speakReply = s }
        if let v = cfg.voiceInterrupt { voiceInterrupt = v }
        if let v = cfg.vad { vadMode = v }
        if let v = cfg.vadSensitivity { vadSensitivity = v }
        if let v = cfg.vocabulary { vocabulary = v.joined(separator: ", ") }
        if let r = cfg.recent { recentGoals = r }
        if let n = cfg.notchHUD { notchHUD = n }
        if let v = cfg.voice { ttsVoice = v }
        if let v = cfg.cloudVoice { cloudVoice = v }
        sandboxSrt = cfg.sandbox == "srt"
        needsOnboarding = cfg.onboarded != true
        booting = false

        models.onChange = { [weak self] in self?.scheduleRearm() }

        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        if DemoContent.enabled {
            turns = DemoContent.turns()
            recentGoals = DemoContent.recent
            needsOnboarding = false
            Task { try? await Task.sleep(for: .milliseconds(600)); DemoContent.sizeWindow() }
            return
        }
        startServe()
        LauncherController.shared.install()
        // Grants land in System Settings while s1 is open — re-check when
        // the app reactivates, and poll only while a required one is missing.
        Task {
            for await _ in NotificationCenter.default.notifications(
                named: NSApplication.didBecomeActiveNotification) {
                refreshPermissions()
                pollPermissionsWhileMissing()
            }
        }
        pollPermissionsWhileMissing()
        // Window closed → live in the menu bar (no Dock icon), or quit.
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.willCloseNotification) {
                try? await Task.sleep(for: .milliseconds(150))
                windowsChanged()
            }
        }
        Task {
            for await _ in NotificationCenter.default.notifications(named: NSWindow.didBecomeKeyNotification) {
                windowsChanged()
            }
        }
    }

    /// A 1.5 s poll while Accessibility or Input Monitoring is missing, so a
    /// grant made in System Settings lands without a relaunch — and nothing
    /// once both are on: an idle s1 must not wake itself up.
    private var permissionPoll: Task<Void, Never>?
    private func pollPermissionsWhileMissing() {
        guard permissionPoll == nil, !(permissions.accessibility && permissions.inputMonitoring) else { return }
        permissionPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1.5))
                guard let self else { return }
                self.refreshPermissions()
                if self.permissions.accessibility && self.permissions.inputMonitoring { break }
            }
            self?.permissionPoll = nil
        }
    }

    /// Keep running in the menu bar when the window closes (⇧⇧, the launcher
    /// and dictation need s1 alive), or quit — the user's choice.
    var keepRunning = UserDefaults.standard.object(forKey: "keepRunning") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepRunning, forKey: "keepRunning") }
    }

    /// No titled window open → no Dock icon (a menu-bar companion); a window
    /// opens → back in the Dock and the app switcher.
    private func windowsChanged() {
        let open = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        if !open && !keepRunning && !DemoContent.enabled { NSApp.terminate(nil); return }
        let want: NSApplication.ActivationPolicy = open ? .regular : .accessory
        guard NSApp.activationPolicy() != want else { return }
        NSApp.setActivationPolicy(want)
        if want == .regular { NSApp.activate() }
    }

    // MARK: - language

    private static func launchLanguagePref() -> String {
        if let l = UserDefaults.standard.string(forKey: "appLanguage") { return l }
        return "system"
    }

    var appLanguageOptions: [(id: String, name: String)] {
        Bundle.main.localizations
            .filter { $0 != "Base" }
            .sorted()
            .map { ($0, Locale.current.localizedString(forLanguageCode: $0) ?? $0) }
    }

    /// A detached shell waits for this process to exit, then reopens the
    /// bundle — the serve.pid owner is gone before the new instance binds.
    func relaunchApp() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 0.6; open \"\(Bundle.main.bundlePath)\""]
        try? p.run()
        shutdown()
    }

    // MARK: - settings plumbing

    func openSettings(_ tab: String) {
        settingsTab = tab
        NSApp.activate()
        if let openSettingsAction { openSettingsAction() } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
    }

    func show(_ message: String) {
        notice = message
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            self?.notice = nil
        }
    }

    private var parsedVocab: [String] {
        vocabulary.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    var vocabularyList: [String] { parsedVocab }
    func addVocabularyWord(_ w: String) {
        let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty,
              !parsedVocab.contains(where: { $0.caseInsensitiveCompare(t) == .orderedSame }) else { return }
        vocabulary = (parsedVocab + [t]).joined(separator: ", ")
    }
    func removeVocabularyWord(_ w: String) {
        vocabulary = parsedVocab.filter { $0 != w }.joined(separator: ", ")
    }

    private func saveConfig() {
        try? S1Config.update { cfg in
            cfg.locale = locale
            cfg.speak = speakReply
            cfg.voiceInterrupt = voiceInterrupt
            cfg.vad = vadMode
            cfg.vadSensitivity = vadSensitivity
            cfg.vocabulary = parsedVocab.isEmpty ? nil : parsedVocab
            cfg.recent = recentGoals.isEmpty ? nil : recentGoals
            cfg.notchHUD = notchHUD
            cfg.voice = ttsVoice.isEmpty ? nil : ttsVoice
            cfg.cloudVoice = cloudVoice.isEmpty ? nil : cloudVoice
            cfg.sandbox = sandboxSrt ? "srt" : nil
        }
    }

    private func scheduleRearm() {
        guard !booting else { return }
        rearmTask?.cancel()
        rearmTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.rearmServe()
        }
    }

    private func scheduleSave() {
        guard !booting else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.saveConfig()
        }
    }

    // MARK: - speech

    private var _stt: SpeechToText?
    /// Cached: Vocabulary.assemble scans /Applications — not per access.
    private var stt: SpeechToText {
        if let _stt { return _stt }
        let s = SpeechToText(locales: SpokenLanguage.candidates(for: locale),
                             vocabulary: Vocabulary.assemble(custom: parsedVocab),
                             vadMode: SpeechToText.VadMode(rawValue: vadMode),
                             vadSensitivity: SpeechToText.VadSensitivity(rawValue: vadSensitivity))
        _stt = s
        Task { await s.warmup() }
        return s
    }
    private func invalidateStt() { _stt = nil }

    func previewVoice() {
        let voice = ttsVoice.isEmpty ? nil : ttsVoice
        Task {
            for l in SpokenLanguage.candidates(for: locale) {
                let id = SpokenLanguage.code(l) == "id"
                await speaker.say(id ? "Halo, aku s1. Siap membantu." : "Hi, I'm s1. Ready when you are.",
                                  language: l.identifier, voice: voice, timeout: 8)
            }
        }
    }

    // MARK: - companion (hotkey → listen → run → speak)

    private func startServe() {
        let langs = SpokenLanguage.candidates(for: locale)
        let s = Serve(
            config: .init(
                // Rebuilt per utterance from config — a model picked in
                // Settings applies to the very next command.
                makePolicy: { Brain.policy() },
                s2: Brain.reasoner(),
                speak: speakReply,
                artifacts: artifactsRoot,
                // One stop file: Stop (⌘.), the HUD and `s1 stop` all write it.
                killSwitch: killPath,
                lockPath: S1Home.path + "/serve.pid",
                transcribe: { [weak self] onPartial in
                    guard let self else { return "" }
                    return try await self.stt.transcribeMic(maxSeconds: 12, onPartial: onPartial)
                },
                isBusy: { [weak self] in
                    if await self?.running == true { return true }
                    return S1Runner.anotherRunActive()
                },
                languages: langs, voice: ttsVoice.isEmpty ? nil : ttsVoice,
                voiceInterrupt: voiceInterrupt),
            locale: langs[0],
            hotkeyPatterns: [Hotkey.doubleShift, Hotkey.defaultChord]
        ) { [weak self] ev in
            Task { @MainActor [weak self] in self?.handle(ev) }
        }
        // Claim the listener slot BEFORE arming: a CLI `s1 serve` holding
        // serve.pid must not be stomped. When it's taken, the window still
        // runs one-shot commands; only the companion stays off.
        do {
            try S1Runner.claimPidFile(S1Home.path + "/serve.pid", what: "s1 listener")
        } catch {
            s.disarm()
            serve = nil
            companionAvailable = false
            return
        }
        companionAvailable = true
        s.armHotkey()
        serve = s
    }

    private func handle(_ ev: ServeEvent) {
        switch ev.kind {
        case .armed: break
        case .listening:
            speaking = false
            serveState = .listening
        case .partial: transcript = ev.text
        case .heard: transcript = ev.text
        case .speaking: speaking = true
        case .interrupted:
            // You're talking again: go straight to the listening pill.
            transcript = ""
            serveState = .listening
            speaking = false
        case .runStart:
            serveState = .running
            transcript = ""
            appendTurn(Turn(goal: ev.text, spoken: true))
        case .step:
            if let rec = ev.record { updateCurrent { $0.steps.append(rec); $0.phase = nil } }
        case .phase:
            updateCurrent { $0.phase = ev.text }
        case .runDone:
            let summary = ev.dir.flatMap { RunHistory.summary(of: URL(fileURLWithPath: $0)) }
            let status = RunStatus(rawValue: ev.text) ?? .aborted
            finishCurrent(status: status, answer: summary?.summary, why: nil, runDir: ev.dir)
        case .sleeping, .stopped, .idle:
            speaking = false
            serveState = .idle
            transcript = ""
        case .error:
            show(String(localized: "Last run failed: \(ev.text)"))
            updateCurrent { $0.state = .failed; $0.reply = ev.text; $0.finished = Date() }
        }
    }

    func rearmServe() {
        guard !booting else { return }
        serve?.disarm()
        startServe()
        saveConfig()
    }

    func toggleServe() {
        guard let s = serve else {
            show(String(localized: "The companion is off — a terminal `s1 serve` holds the listener."))
            return
        }
        s.toggle()
    }

    /// Synchronous truth from the Serve lock (`serveState` lags a hop).
    var serveIsListening: Bool { serve.map { $0.state != .idle } ?? false }

    func toggleLoginItem() {
        do {
            if launchAtLogin { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
            launchAtLogin = SMAppService.mainApp.status == .enabled
        } catch {
            show(String(localized: "Login item: \(error.localizedDescription)"))
        }
    }

    func shutdown() {
        serve?.disarm()
        speaker.stop()
        S1Runner.releasePidFile(S1Home.path + "/serve.pid")
        NSApp.terminate(nil)
    }

    // MARK: - turns

    private func appendTurn(_ t: Turn) {
        turns.append(t)
        if turns.count > 100 { turns.removeFirst(turns.count - 100) }
    }

    private func updateCurrent(_ body: (inout Turn) -> Void) {
        guard let i = turns.lastIndex(where: { $0.state == .running }) else { return }
        body(&turns[i])
        // A daemon day of voice turns can't grow one turn without bound.
        if turns[i].steps.count > 300 { turns[i].steps.removeFirst(turns[i].steps.count - 300) }
    }

    /// Close the running turn with a human line for how it ended.
    private func finishCurrent(status: RunStatus, answer: String?, why: String?, runDir: String?) {
        let reply: String
        let state: Turn.State
        switch status {
        case .done:
            state = .done
            // The grammar's own summary isn't an answer worth showing.
            let real = answer.flatMap { ["done", "goal completed"].contains($0.lowercased()) ? nil : $0 }
            reply = real ?? String(localized: "Done.")
        case .needsHuman:
            state = .needsYou
            reply = why.map { String(localized: "This one needs you — \($0).") }
                ?? String(localized: "This one needs you.")
        case .escalatedToS2:
            state = .failed
            let steps = runDir.flatMap { try? RunReader.steps(in: URL(fileURLWithPath: $0)) } ?? []
            if !models.hasReasoner, let failed = steps.last(where: { $0.outcome?.hasPrefix("error:") == true })?.outcome {
                let why = failed.replacingOccurrences(of: "error: ", with: "")
                    .replacingOccurrences(of: "aborted: ", with: "")
                reply = String(localized: "That didn't work: \(why).")
            } else if !models.hasReasoner {
                reply = String(localized: "I don't know how to do that yet. Connect a Reasoner in Settings → Models.")
            } else {
                switch ReasonerFailure.last(in: steps) {
                case .usageLimit?:
                    reply = String(localized: "Your Reasoner hit its usage limit. Pick another in Settings → Models, or try again later.")
                case .badKey?:
                    reply = String(localized: "Your Reasoner's key was rejected. Check it in Settings → Models.")
                case .unreachable?:
                    reply = String(localized: "I couldn't reach your Reasoner. Check your connection.")
                case .other(let message)?:
                    reply = String(localized: "Your Reasoner failed: \(message)")
                case nil:
                    // Name the step that failed rather than a generic shrug.
                    if let failed = steps.last(where: { $0.outcome?.hasPrefix("error:") == true })?.outcome {
                        let why = failed.replacingOccurrences(of: "error: ", with: "")
                            .replacingOccurrences(of: "aborted: ", with: "")
                        reply = String(localized: "That didn't work: \(why).")
                    } else {
                        reply = String(localized: "I couldn't work out how to do that.")
                    }
                }
            }
        case .maxStepsReached, .stuckLoop:
            state = .failed
            let steps = runDir.flatMap { try? RunReader.steps(in: URL(fileURLWithPath: $0)) } ?? []
            if let failed = steps.last(where: { $0.outcome?.hasPrefix("error:") == true })?.outcome {
                let why = failed.replacingOccurrences(of: "error: ", with: "")
                    .replacingOccurrences(of: "aborted: ", with: "")
                reply = String(localized: "That didn't work: \(why).")
            } else if status == .stuckLoop {
                reply = String(localized: "I got stuck repeating the same step.")
            } else {
                reply = String(localized: "I gave up after too many steps.")
            }
        case .aborted:
            state = .stopped
            reply = String(localized: "Stopped.")
        }
        updateCurrent {
            $0.state = state
            $0.reply = reply
            $0.runDir = runDir
            $0.phase = nil
            $0.finished = Date()
        }
        if serveState == .running { serveState = .idle }
        historyRevision += 1
    }

    func clearConversation() {
        guard !running else { return }
        turns = []
        transcript = ""
    }

    // MARK: - one-shot runs

    func run() async {
        guard !running else { return }
        guard serve?.state != .running else {
            show(String(localized: "The companion is running a command — wait for it or press Stop."))
            return
        }
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goalText.isEmpty else { return }
        guard !S1Runner.anotherRunActive() else {
            show(String(localized: "Another s1 run is in progress in Terminal."))
            return
        }
        try? FileManager.default.removeItem(atPath: killPath)
        goal = ""
        running = true
        appendTurn(Turn(goal: goalText, spoken: !transcript.isEmpty))
        transcript = ""
        recentGoals.removeAll { $0 == goalText }
        recentGoals.insert(goalText, at: 0)
        if recentGoals.count > 8 { recentGoals.removeLast() }

        do {
            let (report, logger) = try await S1Runner.run(
                goal: goalText, policy: Brain.policy(), artifacts: artifactsRoot,
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: killPath, s2: Brain.reasoner(),
                onStep: { [weak self] rec in
                    Task { @MainActor [weak self] in self?.updateCurrent { $0.steps.append(rec); $0.phase = nil } }
                },
                onPhase: { [weak self] phase in
                    Task { @MainActor [weak self] in self?.updateCurrent { $0.phase = phase } }
                })
            // Read the log file, not the live array: step hops can still be
            // in flight when the run returns.
            let recorded = (try? RunReader.steps(in: logger.runDir)) ?? []
            var why: String?
            if report.status == .needsHuman,
               let hit = recorded.last(where: { $0.gate.hasPrefix("needsHuman") || $0.escalation?.to == "human" }) {
                var w = hit.escalation?.reason ?? hit.gate
                if w.hasPrefix("needsHuman("), w.hasSuffix(")") { w = String(w.dropFirst("needsHuman(".count).dropLast()) }
                why = w
            }
            finishCurrent(status: report.status, answer: report.answer, why: why, runDir: report.runDir)
            running = false
            saveConfig()
            if speakReply, !FileManager.default.fileExists(atPath: killPath) {
                let lang = SpokenLanguage.detect(goalText, among: SpokenLanguage.candidates(for: locale))?
                    .identifier ?? "en-US"
                let code = SpokenLanguage.code(Locale(identifier: lang))
                let spoken: String = if let a = report.answer { a } else {
                    switch report.status {
                    case .done: SpokenLanguage.reply(.done, languageCode: code)
                    case .needsHuman: SpokenLanguage.reply(.needsHuman, languageCode: code)
                    case .escalatedToS2: SpokenLanguage.reply(.couldNotWorkOut, languageCode: code)
                    default: SpokenLanguage.reply(.stopped, languageCode: code)
                    }
                }
                speaking = true
                await speaker.say(spoken, language: lang, voice: ttsVoice.isEmpty ? nil : ttsVoice)
                speaking = false
            }
        } catch {
            var why = error.localizedDescription
            if why.hasPrefix("aborted: ") { why = String(why.dropFirst("aborted: ".count)) }
            updateCurrent {
                $0.state = .failed
                $0.reply = why
                $0.finished = Date()
            }
            historyRevision += 1
        }
        running = false
        refreshPermissions()
    }

    func runAgain(_ text: String) {
        goal = text
        Task { await run() }
    }

    func stop() {
        try? "stop".write(toFile: killPath, atomically: true, encoding: .utf8)
        // An in-flight listen doesn't check the kill file — cancel it too.
        listenTask?.cancel()
        listenTask = nil
        listening = false
        speaker.stop()
        speaking = false
    }

    // MARK: - mic

    func toggleListen() {
        if listening {
            listenTask?.cancel()
            listenTask = nil
            listening = false
            return
        }
        listenTask = Task { await listenAndRun() }
    }

    private func listenAndRun() async {
        guard !listening, !running else { return }
        guard serve?.state == nil || serve?.state == .idle else {
            show(String(localized: "The companion is already listening — press ⇧⇧ to pause it first."))
            return
        }
        do { try S1Runner.claimMic() } catch {
            show(String(localized: "The microphone is in use by another s1 process."))
            return
        }
        defer { S1Runner.releaseMic() }
        listening = true
        defer { listening = false; listenTask = nil }
        do {
            let text = try await stt.transcribeMic(maxSeconds: 20) { p in
                Task { @MainActor in self.transcript = p }
            }
            guard !Task.isCancelled else { transcript = ""; return }
            transcript = text
            if text.isEmpty {
                show(String(localized: "I didn't hear anything."))
            } else {
                goal = text
                listening = false
                await run()
            }
        } catch {
            transcript = ""
            if !Task.isCancelled { show(String(localized: "Microphone: \(error.localizedDescription)")) }
        }
    }

    func pickAudioAndTranscribe() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            listening = true
            defer { listening = false }
            do {
                let text = try await stt.transcribe(file: url)
                if text.isEmpty { show(String(localized: "I didn't hear anything.")) } else { goal = text }
            } catch {
                show(String(localized: "Transcription failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - dictation (⌃⌥D): speech → text pasted into the focused app

    private var dictation: MicControl?
    private var dictationDownAt = Date.distantPast

    /// Hold ⌃⌥D to talk (release ends it); a quick tap starts a VAD-ended
    /// turn, and a second tap stops it early.
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
            show(String(localized: "Busy — stop the current command before dictating."))
            return
        }
        do { try S1Runner.claimMic() } catch {
            show(String(localized: "The microphone is in use by another s1 process."))
            return
        }
        defer { S1Runner.releaseMic() }
        listening = true
        transcript = ""
        defer { listening = false; transcript = "" }
        do {
            let text = try await stt.transcribeMic(maxSeconds: 120, control: control) { p in
                Task { @MainActor in self.transcript = p }
            }.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if AXIsProcessTrusted() {
                LauncherController.shared.paste(text, restore: true, into: target)
            } else {
                let pb = NSPasteboard.general
                pb.clearContents(); pb.setString(text, forType: .string)
                show(String(localized: "Dictation copied — press ⌘V. Grant Accessibility to paste automatically."))
            }
        } catch {
            show(String(localized: "Microphone: \(error.localizedDescription)"))
        }
    }

    // MARK: - permissions + setup

    func refreshPermissions() { permissions = Preflight.check(request: false) }

    func requestPermissions() {
        permissions = Preflight.check(request: true)
        if !permissions.accessibility { PermissionPane.accessibility.open() }
    }

    /// A toggle that's ON in System Settings but not honored belongs to a
    /// copy of s1 signed differently (TCC pins the signature it saw when you
    /// granted). Drop the stale entry and ask again.
    func resetAccessibility() {
        resetGrant("Accessibility")
        requestPermissions()
    }

    /// Same repair for Screen Recording. ScreenCaptureKit reads the grant at
    /// launch, so the new one applies after a restart.
    func resetScreenRecording() {
        resetGrant("ScreenCapture")
        _ = CGRequestScreenCaptureAccess()
        PermissionPane.screenRecording.open()
    }

    private func resetGrant(_ service: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", service, Bundle.main.bundleIdentifier ?? "com.mattheweuc.s1"]
        try? p.run(); p.waitUntilExit()
    }

    func markOnboarded() {
        needsOnboarding = false
        try? S1Config.update { $0.onboarded = true }
    }

    /// Install Cua Driver via CUA's own installer, streaming its log.
    func installCuaDriver() async {
        guard !cuaInstalling, !CuaInstaller.installed else { return }
        cuaInstalling = true
        cuaInstallLog = ""
        defer { cuaInstalling = false }
        do {
            try await CuaInstaller.install { [weak self] line in
                Task { @MainActor in
                    guard let self else { return }
                    if self.cuaInstallLog.count > 8000 { self.cuaInstallLog = String(self.cuaInstallLog.suffix(4000)) }
                    self.cuaInstallLog += line + "\n"
                }
            }
            cuaInstallLog += String(localized: "Installed — s1 will use it.") + "\n"
            // The driver has its own TCC identity; run CUA's grant flow detached.
            Task.detached { try? await CuaInstaller.grantPermissions { _ in } }
        } catch {
            cuaInstallLog += "✗ \(error.localizedDescription)\n"
        }
    }

    func revealRunDir(_ dir: String?) {
        guard let dir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: dir)])
    }

    // MARK: - notch HUD

    /// Priority: listening > running > a brief outcome flash > hidden.
    private func syncHUD() {
        guard notchHUD, !booting, !DemoContent.enabled else { return }
        if serveState == .listening || listening {
            hud.show(.listening(transcript))
            return
        }
        if let t = currentTurn {
            // The live phase ("Searching the web…") wins over the last finished step.
            hud.show(.working(t.phase ?? t.steps.last.map(StepPresentation.init)?.title ?? t.goal))
            return
        }
        // Speaking: the answer stays up for as long as the voice plays.
        if speaking, let last = turns.last {
            hud.show(.finished(last.state, last.reply ?? ""))
            return
        }
        if let last = turns.last, let f = last.finished, (0..<1).contains(Date().timeIntervalSince(f)) {
            hud.flash(.finished(last.state, last.reply ?? ""))
        } else {
            hud.hide()
        }
    }

    /// The pill's stop control: sleep the listener, or abort the run.
    func hudStopTapped() {
        if serveState == .listening { toggleServe(); return }
        if serveState == .running || running { stop() }
    }
}

/// System Settings privacy panes s1 deep-links to.
enum PermissionPane: String {
    case accessibility = "Privacy_Accessibility"
    case screenRecording = "Privacy_ScreenCapture"
    case microphone = "Privacy_Microphone"
    case inputMonitoring = "Privacy_ListenEvent"

    func open() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(rawValue)") {
            NSWorkspace.shared.open(url)
        }
    }
}
