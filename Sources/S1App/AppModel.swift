import AppKit
import Foundation
import S1Core
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

    private let speaker = Speaker()
    private let killPath = NSTemporaryDirectory() + "s1-app-stop"
    private var stt: SpeechToText { SpeechToText(locale: Locale(identifier: locale)) }

    init() { refreshPermissions() }

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
