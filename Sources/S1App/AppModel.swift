import AppKit
import Combine
import Foundation
import S1Core
import ServiceManagement
import UniformTypeIdentifiers

/// Observable bridge between the SwiftUI shell and the S1Core agent loop.
@available(macOS 26, *)
@MainActor
final class AppModel: ObservableObject {
    enum Brain: String, CaseIterable, Identifiable {
        case ax, vlm
        var id: String { rawValue }
        var title: String { self == .ax ? "AX (instant, no model)" : "VLM (model)" }
    }

    @Published var goal = ""
    @Published var transcript = ""
    @Published var brain: Brain = .ax
    @Published var locale = "id-ID"
    @Published var useS2 = false
    @Published var speakReply = true
    @Published var vlmBase = "http://localhost:11434/v1"
    @Published var vlmModel = "gemma3:4b"

    @Published private(set) var steps: [StepRecord] = []
    @Published private(set) var status = "idle"
    @Published private(set) var running = false
    @Published private(set) var listening = false
    @Published private(set) var runDir: String?
    @Published private(set) var permissions = PermissionReport(accessibility: false,
                                                               screenRecording: false,
                                                               microphone: false, notes: [])

    // ---- always-on companion (hotkey -> continuous listening -> run -> listen) ----
    @Published private(set) var serveState: Serve.State = .idle
    @Published private(set) var serveStatus = "hotkey armed: ⇧⇧ or ⌃⌥Space"
    @Published var launchAtLogin = false

    private let speaker = Speaker()
    private let killPath = NSTemporaryDirectory() + "s1-app-stop"
    private var stt: SpeechToText { SpeechToText(locale: Locale(identifier: locale)) }
    private var serve: Serve?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        refreshPermissions()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        startServe()
        // Changing brain/locale/S2/speak rebuilds the companion config
        // (disarm → arm) so the hotkey always runs current settings.
        for pub in [
            $brain.map { _ in () }.eraseToAnyPublisher(),
            $locale.map { _ in () }.eraseToAnyPublisher(),
            $useS2.map { _ in () }.eraseToAnyPublisher(),
            $speakReply.map { _ in () }.eraseToAnyPublisher(),
            $vlmModel.map { _ in () }.eraseToAnyPublisher(),
        ] {
            pub.dropFirst().sink { [weak self] in self?.rearmServe() }
                .store(in: &cancellables)
        }
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
                s2: s2On ? LLMReasoner(endpoint: .s2Default()) : nil,
                speak: speakOn,
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

    /// Rebuild the serve config when brain/locale/s2/speak settings change.
    func rearmServe() {
        serve?.disarm()
        startServe()
    }

    /// Hotkey-equivalent toggle for menu/UI buttons.
    func toggleServe() { serve?.toggle() }

    func toggleLoginItem() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.unregister()
                launchAtLogin = false
            } else {
                try SMAppService.mainApp.register()
                launchAtLogin = true
            }
        } catch {
            status = "login item: \(error.localizedDescription)"
        }
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

    /// Mic → transcript → run. The voice-first path.
    func listenAndRun() async {
        guard !running, !listening else { return }
        listening = true
        status = "listening…"
        do {
            let text = try await stt.transcribeMic(maxSeconds: 20)
            transcript = text
            if text.isEmpty {
                status = "heard nothing"
            } else {
                goal = text
                status = "heard: \(text)"
                listening = false
                await run()
                return
            }
        } catch {
            status = "mic: \(error.localizedDescription)"
        }
        listening = false
    }

    func run() async {
        guard !running else { return }
        let goalText = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !goalText.isEmpty else { status = "nothing to run"; return }
        try? FileManager.default.removeItem(atPath: killPath)
        running = true
        steps = []
        runDir = nil
        status = "running"

        let pol: any Policy = brain == .vlm
            ? VLMPolicy(endpoint: Endpoint(baseURL: vlmBase, model: vlmModel))
            : AXPolicy()
        let reasoner: (any Reasoner)? = useS2 ? LLMReasoner(endpoint: .s2Default()) : nil

        do {
            let (report, _) = try await S1Runner.run(
                goal: goalText, policy: pol, artifacts: "artifacts",
                maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: killPath, s2: reasoner,
                onStep: { [weak self] rec in
                    Task { @MainActor [weak self] in self?.steps.append(rec) }
                })
            runDir = report.runDir
            status = report.status.rawValue
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
        status = "stopping…"
    }

    func revealRunDir() {
        guard let runDir else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: runDir)])
    }
}
