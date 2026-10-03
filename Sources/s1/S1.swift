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
        version: "0.2.0",
        subcommands: [PreflightCmd.self, RunCmd.self, DemoCmd.self, CaptureCmd.self,
                      AXCmd.self, TranscribeCmd.self, SayCmd.self, ListenCmd.self,
                      ServeCmd.self, MetricsCmd.self, ReplayCmd.self, ConfigCmd.self])
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
    var goal: String?
    @Option(help: "Task library name — reads tasks/<name>.txt as the goal.")
    var task: String?
    @Option(help: "Policy: scripted | dummy | ax | vlm")
    var policy: String = "ax"
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
    @Flag(inversion: .prefixedNo,
          help: "Attach a screenshot to each VLM decision (default: config vlmScreenshot, else on).")
    var vlmScreenshot: Bool? = nil
    @Flag(help: "Enable System 2 via S1_S2_* env or defaults (Ollama gemma3:4b).")
    var s2 = false

    func run() async throws {
        let pol: any Policy
        switch policy {
        case "dummy": pol = DummyPolicy()
        case "ax":    pol = AXPolicy()
        case "vlm":
            pol = VLMPolicy(endpoint: Endpoints.vlm(base: vlmBase, model: vlmModel),
                            useScreenshot: vlmScreenshot ?? S1Config.load().vlmScreenshot ?? true)
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
        } else if let goal { goalText = goal } else {
            throw ValidationError("pass --goal or --task")
        }
        guard !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("empty goal — pass --goal or --task")
        }
        let s2: (any Reasoner)? = s2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil
        let (report, _) = try await S1Runner.run(goal: goalText, policy: pol, artifacts: artifacts,
                               maxSteps: maxSteps, threshold: threshold, dryRun: dryRun,
                               allowIrreversible: allowIrreversible, killSwitch: killSwitch, s2: s2)
        if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
    }
}

struct ConfigCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config",
        abstract: "Show the resolved model config (file, env overrides) and where to edit it.")
    func run() async throws {
        let exists = FileManager.default.fileExists(atPath: S1Config.path)
        let vlm = Endpoints.vlm()
        let s2 = Endpoints.s2()
        print("config file: \(S1Config.path)\(exists ? "" : " (not found — defaults in use)")")
        print("vlm  → \(vlm.baseURL) model=\(vlm.model) numCtx=\(vlm.numCtx)")
        print("s2   → \(s2.baseURL) model=\(s2.model) numCtx=\(s2.numCtx)")
        print("env overrides: S1_VLM_BASE/S1_VLM_MODEL/S1_VLM_KEY, S1_S2_BASE/S1_S2_MODEL/S1_S2_KEY, S1_NUM_CTX")
        let vocab = S1Config.load().vocabulary ?? []
        print("vocabulary → \(vocab.count) custom words + installed app names (auto)")
        print("edit the JSON file to swap brains permanently — no rebuild needed")
    }
}

/// config.json vocabulary + a `--vocabulary a,b,c` flag → the full
/// contextual-strings list (installed app names added automatically).
func sttVocabulary(_ csv: String?) -> [String] {
    let flag = csv?.split(separator: ",").map { String($0) } ?? []
    return Vocabulary.assemble(custom: flag + (S1Config.load().vocabulary ?? []))
}

func validatedSTTPolicy(_ policy: String) throws -> String {
    guard ["ax", "vlm"].contains(policy) else {
        throw ValidationError("unknown policy \(policy) — use ax or vlm")
    }
    return policy
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
    @Option(help: "Comma-separated words the recognizer should bias toward.")
    var vocabulary: String?

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        let stt = SpeechToText(locale: Locale(identifier: locale),
                               vocabulary: sttVocabulary(vocabulary))
        let text: String
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("audio file not found: \(file)")
            }
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
    @Option(help: "VLM endpoint base URL (--policy vlm).")
    var vlmBase: String?
    @Option(help: "VLM model name (--policy vlm).")
    var vlmModel: String?
    @Option(help: "Comma-separated words the recognizer should bias toward.")
    var vocabulary: String?

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        let stt = SpeechToText(locale: Locale(identifier: locale),
                               vocabulary: sttVocabulary(vocabulary))
        let goal: String
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("audio file not found: \(file)")
            }
            goal = try await stt.transcribe(file: URL(fileURLWithPath: file))
        } else {
            print("listening... (speak a command)")
            goal = try await stt.transcribeMic(maxSeconds: 20)
        }
        print("heard: \(goal)")
        guard !goal.isEmpty else { throw ValidationError("nothing transcribed") }

        let pol: any Policy = try validatedSTTPolicy(policy) == "vlm"
            ? VLMPolicy(endpoint: Endpoints.vlm(base: vlmBase, model: vlmModel),
                        useScreenshot: S1Config.load().vlmScreenshot ?? true)
            : AXPolicy()
        let reasoner: (any Reasoner)? = s2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil
        // A fresh listen clears a stale kill switch — the user just asked for
        // a new run, so an old "stop" file must not silently abort step 0.
        let kill = NSTemporaryDirectory() + "s1-stop"
        try? FileManager.default.removeItem(atPath: kill)
        let (report, _) = try await S1Runner.run(goal: goal, policy: pol, artifacts: artifacts,
                               maxSteps: maxSteps, threshold: 0.6, dryRun: dryRun,
                               allowIrreversible: false,
                               killSwitch: kill, s2: reasoner)
        if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
        if speak {
            let done = locale.hasPrefix("id") ? "Selesai" : "Done"
            await Speaker().say("\(done). \(goal)", language: locale)
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
        let kill = NSTemporaryDirectory() + "s1-stop"
        try? FileManager.default.removeItem(atPath: kill)
        let (report, _) = try await S1Runner.run(goal: "p1-demo-textedit", policy: ScriptedPolicy(steps: steps),
                               artifacts: artifacts, maxSteps: 25, threshold: 0.6,
                               dryRun: dryRun, allowIrreversible: false,
                               killSwitch: kill)
        if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
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
        let flat = tree.flattened
        for n in flat.prefix(250) {
            let label = n.title ?? n.desc ?? n.value ?? ""
            print("  \(n.ref) [\(n.role)] \(label)")
        }
        if flat.count > 250 { print("  … \(flat.count - 250) more nodes") }
    }
}

struct ServeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve",
        abstract: "Always-on companion: hotkey toggles continuous listening (double-tap Shift or ⌃⌥Space).")
    @Option(help: "STT/TTS locale.")
    var locale: String = "id-ID"
    @Option(help: "Policy for runs (default ax — fast, local).")
    var policy: String = "ax"
    @Flag(help: "Enable System 2 escalation (LLM endpoint).")
    var s2 = false
    @Flag(help: "Speak results with TTS.")
    var speak = false
    @Option(help: "Silent turns before auto-sleep.")
    var idleTurns: Int = 3
    @Option(help: "Seconds per listening turn.")
    var listenSeconds: Double = 12
    @Option(help: "VLM endpoint base URL (--policy vlm).")
    var vlmBase: String?
    @Option(help: "VLM model name (--policy vlm).")
    var vlmModel: String?
    @Option(help: "Transcribe this audio file once, run it, exit (testing — no mic needed).")
    var file: String?
    @Option(help: "Comma-separated words the recognizer should bias toward.")
    var vocabulary: String?
    @Flag(help: "Start in listening state immediately (no hotkey press needed).")
    var wake = false

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        setbuf(stdout, nil)   // daemon: stream events unbuffered
        _ = try validatedSTTPolicy(policy)
        let stt = SpeechToText(locale: Locale(identifier: locale),
                               vocabulary: sttVocabulary(vocabulary))
        let reasoner: (any Reasoner)? = s2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil

        let makePol: @Sendable () -> any Policy = {
            guard policy == "vlm" else { return AXPolicy() }
            return VLMPolicy(endpoint: Endpoints.vlm(base: vlmBase, model: vlmModel),
                             useScreenshot: S1Config.load().vlmScreenshot ?? true)
        }

        // --file: one utterance through the same pipeline, then exit.
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("audio file not found: \(file)")
            }
            let text = try await stt.transcribe(file: URL(fileURLWithPath: file))
            print("heard: \(text)")
            guard !text.isEmpty else { throw ValidationError("nothing transcribed") }
            // A one-shot has no wake() to clear the daemon's kill switch —
            // remove the stale file or this run aborts at step 0.
            let kill = NSTemporaryDirectory() + "s1-serve-stop"
            try? FileManager.default.removeItem(atPath: kill)
            let (report, _) = try await S1Runner.run(goal: text, policy: makePol(),
                artifacts: "artifacts", maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: kill,
                s2: reasoner)
            if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
            if speak {
                let done = locale.hasPrefix("id") ? "Selesai" : "Done"
                await Speaker().say(done, language: locale)
            }
            return
        }

        let serve = Serve(
            config: .init(makePolicy: makePol, s2: reasoner, speak: speak,
                          listenSeconds: listenSeconds, maxSilentTurns: idleTurns,
                          transcribe: { try await stt.transcribeMic(maxSeconds: listenSeconds) }),
            locale: Locale(identifier: locale),
            hotkeyPatterns: [Hotkey.doubleShift, Hotkey.defaultChord]
        ) { ev in
            print("[\(ev.kind.rawValue)] \(ev.text)")
        }
        serve.armHotkey()
        print("serve armed — double-tap Shift or ⌃⌥Space toggles listening; Ctrl-C quits")
        if wake { serve.wake() }
        // The global hotkey monitor's handler is delivered through the
        // MAIN run loop, so main must actually spin — queue CFRunLoop there
        // (NSApplication touch first: NSEvent monitors in a CLI need the app
        // object; accessory policy = no dock icon), then park this task.
        DispatchQueue.main.async {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            CFRunLoopRun()
        }
        while true { try await Task.sleep(for: .seconds(3600)) }
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
