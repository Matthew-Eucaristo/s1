import ArgumentParser
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import S1Core

@main
struct S1: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "s1",
        abstract: "Voice-first macOS agent — see, decide, act, verify, log.",
        subcommands: [PreflightCmd.self, RunCmd.self, DemoCmd.self, CaptureCmd.self,
                      AXCmd.self, TranscribeCmd.self, SayCmd.self, ListenCmd.self,
                      MetricsCmd.self, ReplayCmd.self])
}

struct PreflightCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "preflight",
        abstract: "Check macOS permissions (Accessibility, Screen Recording, Mic).")
    @Flag(help: "Trigger the system permission prompts.")
    var request = false

    func run() async throws {
        let r = Preflight.check(request: request)
        print(Preflight.describe(r))
        if !r.ready { throw ExitCode(1) }
    }
}

struct RunCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run",
        abstract: "Run the agent loop on a goal or a scripted plan.")

    @Option(help: "Goal text (logged; policies see it).")
    var goal: String = "demo"
    @Option(help: "Task library name — reads tasks/<name>.txt as the goal.")
    var task: String?
    @Option(help: "Policy: scripted | dummy | ax | vlm")
    var policy: String = "scripted"
    @Option(help: "JSON plan file for the scripted policy.")
    var plan: String?
    @Option(help: "Artifacts root directory.")
    var artifacts: String = "artifacts"
    @Option(help: "Max loop steps.")
    var maxSteps: Int = 25
    @Option(help: "Confidence threshold below which steps escalate to S2.")
    var threshold: Double = 0.6
    @Flag(help: "Log everything, execute nothing.")
    var dryRun = false
    @Flag(help: "Queue irreversible actions for human confirmation.")
    var allowIrreversible = false
    @Option(help: "Kill-switch file path (abort if it appears).")
    var killSwitch: String? = nil
    @Option(help: "VLM endpoint base URL for --policy vlm (OpenAI-compatible).")
    var vlmBase: String?
    @Option(help: "VLM model name for --policy vlm.")
    var vlmModel: String?
    @Flag(help: "Attach a screenshot to each VLM decision.")
    var vlmScreenshot = false
    @Flag(help: "Enable System 2 via S1_S2_* env or defaults (Ollama gemma3:4b).")
    var s2 = false

    func run() async throws {
        let pol: any Policy
        switch policy {
        case "dummy": pol = DummyPolicy()
        case "ax":    pol = AXPolicy()
        case "vlm":
            pol = VLMPolicy(endpoint: Endpoint(
                baseURL: vlmBase ?? ProcessInfo.processInfo.environment["S1_VLM_BASE"] ?? "http://localhost:11434/v1",
                model: vlmModel ?? ProcessInfo.processInfo.environment["S1_VLM_MODEL"] ?? "gemma3:4b",
                apiKey: ProcessInfo.processInfo.environment["S1_VLM_KEY"]),
                useScreenshot: vlmScreenshot)
        case "scripted":
            guard let plan else { throw ValidationError("--plan required for scripted policy") }
            pol = try ScriptedPolicy(planJSON: Data(contentsOf: URL(fileURLWithPath: plan)))
        default: throw ValidationError("unknown policy \(policy)")
        }
        let goalText: String
        if let task {
            let p = "tasks/\(task).txt"
            guard let g = try? String(contentsOfFile: p, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty else {
                throw ValidationError("task file not found or empty: \(p)")
            }
            goalText = g
        } else { goalText = goal }
        let s2: (any Reasoner)? = s2 ? LLMReasoner(endpoint: .s2Default()) : nil
        try await S1Runner.run(goal: goalText, policy: pol, artifacts: artifacts,
                               maxSteps: maxSteps, threshold: threshold, dryRun: dryRun,
                               allowIrreversible: allowIrreversible, killSwitch: killSwitch, s2: s2)
    }
}

struct TranscribeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcribe",
        abstract: "On-device STT: transcribe an audio file (or the mic).")
    @Option(help: "Audio file to transcribe (.aiff/.wav).")
    var file: String?
    @Option(help: "Locale, e.g. id-ID, en-US.")
    var locale: String = "id-ID"
    @Option(help: "Max seconds of mic recording when --file is omitted.")
    var maxSeconds: Double = 15

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        let stt = SpeechToText(locale: Locale(identifier: locale))
        let text: String
        if let file {
            text = try await stt.transcribe(file: URL(fileURLWithPath: file))
        } else {
            text = try await stt.transcribeMic(maxSeconds: maxSeconds)
        }
        print(text)
    }
}

struct SayCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "say",
        abstract: "On-device TTS (AVSpeechSynthesizer).")
    @Argument(help: "Text to speak.")
    var text: String
    @Option(help: "Voice language, e.g. id-ID, en-US.")
    var language: String = "id-ID"

    func run() async throws {
        await Speaker().say(text, language: language)
    }
}

struct ListenCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "listen",
        abstract: "Voice-first: hear a command, run it, speak the result.")
    @Option(help: "Transcribe this audio file instead of the mic (testing).")
    var file: String?
    @Option(help: "STT/TTS locale.")
    var locale: String = "id-ID"
    @Option(help: "Policy for the run (default ax — fast, local).")
    var policy: String = "ax"
    @Option(help: "Artifacts root directory.")
    var artifacts: String = "artifacts"
    @Flag(help: "Speak the result with TTS.")
    var speak = false
    @Option(help: "Max loop steps.")
    var maxSteps: Int = 25
    @Flag(help: "Log everything, execute nothing.")
    var dryRun = false
    @Flag(help: "Enable System 2 escalation (LLM endpoint).")
    var s2 = false

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        let stt = SpeechToText(locale: Locale(identifier: locale))
        let goal: String
        if let file {
            goal = try await stt.transcribe(file: URL(fileURLWithPath: file))
        } else {
            print("listening... (speak a command)")
            goal = try await stt.transcribeMic(maxSeconds: 20)
        }
        print("heard: \(goal)")
        guard !goal.isEmpty else { throw ValidationError("nothing transcribed") }

        let pol: any Policy = policy == "vlm"
            ? VLMPolicy(endpoint: Endpoint(baseURL: "http://localhost:11434/v1", model: "gemma3:4b"))
            : AXPolicy()
        let reasoner: (any Reasoner)? = s2 ? LLMReasoner(endpoint: .s2Default()) : nil
        try await S1Runner.run(goal: goal, policy: pol, artifacts: artifacts,
                               maxSteps: maxSteps, threshold: 0.6, dryRun: dryRun,
                               allowIrreversible: false,
                               killSwitch: NSTemporaryDirectory() + "s1-stop", s2: reasoner)
        if speak {
            await Speaker().say("Selesai. \(goal)", language: locale)
        }
    }
}

struct DemoCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "demo",
        abstract: "Canned P1 demo: open TextEdit, type, verify on-screen.")
    @Option var artifacts: String = "artifacts"
    @Flag(help: "Log everything, execute nothing.")
    var dryRun = false

    func run() async throws {
        let steps: [ScriptedPolicy.Step] = [
            .init(action: .openApp(name: "TextEdit"), rationale: "open editor"),
            .init(action: .wait(seconds: 1.5), rationale: "let it launch"),
            .init(action: .keyCombo(keys: ["cmd", "n"]), rationale: "new document"),
            .init(action: .wait(seconds: 0.8), rationale: "doc ready"),
            .init(action: .captureScreenshot(reason: "baseline before typing"), rationale: "evidence"),
            .init(action: .typeText("s1 P1 real run — halo dari Devin"), rationale: "write text"),
            .init(action: .wait(seconds: 0.5), rationale: "settle"),
            .init(action: .verify(expectation: "P1 real run"), rationale: "verify text landed"),
            .init(action: .moveMouse(x: 100, y: 100), rationale: "cursor control"),
            .init(action: .moveMouse(x: 640, y: 400), rationale: "cursor control 2"),
            .init(action: .captureScreenshot(reason: "final state"), rationale: "evidence"),
            .init(action: .done(summary: "demo complete"), rationale: "finish"),
        ]
        try await S1Runner.run(goal: "p1-demo-textedit", policy: ScriptedPolicy(steps: steps),
                               artifacts: artifacts, maxSteps: 25, threshold: 0.6,
                               dryRun: dryRun, allowIrreversible: false,
                               killSwitch: NSTemporaryDirectory() + "s1-stop")
    }
}

struct CaptureCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "capture",
        abstract: "Take one screenshot (checks Screen Recording permission).")
    @Option var out: String = "capture.png"

    func run() async throws {
        let img = try await SystemPerceiver.captureScreen()
        let url = URL(fileURLWithPath: out)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ExitCode(1)
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExitCode(1) }
        print("wrote \(out) (\(img.width)x\(img.height))")
    }
}

struct AXCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ax",
        abstract: "Dump the frontmost app's accessibility tree.")
    func run() async throws {
        guard let app = NSWorkspace.shared.frontmostApplication else {
            print("no frontmost app"); return
        }
        print("\(app.localizedName ?? "?") pid \(app.processIdentifier)")
        guard let tree = AXReader.snapshotTree(pid: app.processIdentifier) else {
            print("no AX tree (check Accessibility permission)"); throw ExitCode(1)
        }
        for n in tree.flattened {
            print("  \(n.ref) [\(n.role)] \(n.title ?? n.value ?? "")")
        }
    }
}

struct MetricsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "metrics",
        abstract: "Summarize a run's steps.jsonl: decisions, escalations, errors, verifies.")
    @Argument(help: "Run directory (contains steps.jsonl).")
    var runDir: String

    func run() async throws {
        let m = try RunReader.metrics(in: URL(fileURLWithPath: runDir))
        print("steps        \(m.steps)")
        print("decidedBy    s1: \(m.s1Decisions) · s2: \(m.s2Decisions)")
        print("escalations  \(m.escalations.count)")
        for e in m.escalations { print("  -> \(e.to): \(e.reason)") }
        print("errors       \(m.errors)")
        print("blocked      \(m.blocked)")
        print("verified     ok: \(m.verifiedOK) · fail: \(m.verifiedFail)")
        print("screenshots  \(m.screenshots)")
        print(String(format: "duration     %.1fs", m.durationSeconds))
    }
}

struct ReplayCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replay",
        abstract: "Re-execute a run's recorded actions against the live screen.")
    @Argument(help: "Run directory to replay (contains steps.jsonl).")
    var runDir: String
    @Option(help: "Artifacts root for the replay run.")
    var artifacts: String = "artifacts"
    @Flag(help: "Log everything, execute nothing.")
    var dryRun = false
    @Flag(help: "Queue irreversible actions for human confirmation.")
    var allowIrreversible = false

    func run() async throws {
        let src = URL(fileURLWithPath: runDir)
        let logger = try RunLogger(goal: "replay:\(src.lastPathComponent)",
                                   root: URL(fileURLWithPath: artifacts),
                                   config: ["mode": dryRun ? "dry-run" : "live", "source": runDir])
        let actuator: any Actuator = dryRun ? DryRunActuator() : CGEventActuator()
        let gate = SafetyGate(allowIrreversible: allowIrreversible)
        let n = try await RunReader.replay(runDir: src, into: logger,
                                           actuator: actuator, gate: gate)
        print("replay run dir: \(logger.runDir.path)")
        print("replayed \(n) steps")
    }
}
