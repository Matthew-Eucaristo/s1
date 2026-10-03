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
        if let s = cfg.speak { speakReply = s }
        if let v = cfg.vocabulary { vocabulary = v.joined(separator: ", ") }

        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startServe()
    }

    /// Arm the companion: installs the global hotkey (double-tap Shift and
    /// ⌃⌥Space both work). Idle = zero mic, zero model — battery stays flat.
    private func startServe() {
        let loc = locale
        let brainKind = brain
        let s2On = useS2
        let speakOn = speakReply
        let base = vlmBase
        let model = vlmModel
        let s = Serve(
            config: .init(
                makePolicy: {
                    if brainKind == .vlm {
                        return VLMPolicy(endpoint: Endpoint(baseURL: base, model: model))
                    }
                    return AXPolicy()
                },
                s2: s2On ? LLMReasoner(endpoint: Endpoints.s2()) : nil,
                speak: speakOn,
                artifacts: artifactsRoot,
                transcribe: { [weak self] in
                    guard let self else { return "" }
                    return try await self.stt.transcribeMic(maxSeconds: 12)
                }),
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
        cfg.vlm = .init(base: vlmBase, model: vlmModel)
        cfg.vocabulary = parsedVocab
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
        guard serveState != .listening else {
            status = "companion is listening — press ⇧⇧ / ⌃⌥Space to pause it first"
            return
        }
        guard serveState != .running else {
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
        guard serveState != .running else {
            status = "companion is running — wait or sleep it first"
            return
        }
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goalText.isEmpty else { status = "nothing to run"; return }
        try? FileManager.default.removeItem(atPath: killPath)
        running = true
        steps = []
        runDir = nil
        status = "running"

        let pol: any Policy = brain == .vlm
            ? VLMPolicy(endpoint: Endpoints.vlm(base: vlmBase, model: vlmModel))
            : AXPolicy()
        let reasoner: (any Reasoner)? = useS2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil

        do {
            let (report, _) = try await S1Runner.run(
                goal: goalText, policy: pol, artifacts: artifactsRoot,
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: killPath, s2: reasoner,
                onStep: { [weak self] rec in
                    Task { @MainActor [weak self] in self?.steps.append(rec) }
                })
            runDir = report.runDir
            status = report.status.rawValue
            recentGoals.removeAll { $0 == goalText }
            recentGoals.insert(goalText, at: 0)
            if recentGoals.count > 8 { recentGoals.removeLast() }
            running = false
            if speakReply {
                let reply = locale.hasPrefix("id") ? "Selesai" : "Done"
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
