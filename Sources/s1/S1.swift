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
        version: S1Info.version,
        subcommands: [PreflightCmd.self, RunCmd.self, DemoCmd.self, CaptureCmd.self,
                      AXCmd.self, TranscribeCmd.self, SayCmd.self, ListenCmd.self,
                      ServeCmd.self, MetricsCmd.self, ReplayCmd.self, ConfigCmd.self,
                      TasksCmd.self, StatusCmd.self, StopCmd.self])
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
    @Option(help: "Policy: scripted | dummy | ax | vlm (default: ax; --plan implies scripted)")
    var policy: String?
    @Option(help: "JSON plan file for the scripted policy.")
    var plan: String?
    @Option(help: "Artifacts root directory.")
    var artifacts: String = S1Home.path + "/artifacts"
    @Option(help: "Max loop steps.")
    var maxSteps: Int = 25
    @Option(help: "Confidence threshold below which steps escalate to S2.")
    var threshold: Double = 0.6
    @Flag(help: "Log everything, execute nothing.")
    var dryRun = false
    @Flag(help: "Queue irreversible actions for human confirmation.")
    var allowIrreversible = false
    @Option(help: "Kill-switch file path (abort if it appears). Default: the shared s1-stop file `s1 stop` writes.")
    var killSwitch: String = NSTemporaryDirectory() + "s1-stop"
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
        // --plan is a program to replay: scripted is the only policy that
        // consumes it. Resolve it implicitly so `s1 run --plan` just works.
        let policyName = policy ?? (plan != nil ? "scripted" : "auto")
        if plan != nil, policyName != "scripted" {
            FileHandle.standardError.write(
                "note: --plan given but --policy \(policyName) ignores the file\n".data(using: .utf8)!)
        }
        let pol: any Policy
        switch policyName {
        case "dummy": pol = DummyPolicy()
        case "ax":    pol = AXPolicy()
        case "auto":  pol = await resolveAutoPolicy(vlmBase: vlmBase, vlmModel: vlmModel)
        case "vlm":
            pol = VLMPolicy(endpoint: Endpoints.vlm(base: vlmBase, model: vlmModel),
                            useScreenshot: vlmScreenshot ?? S1Config.load().vlmScreenshot ?? true)
        case "scripted":
            guard let plan else { throw ValidationError("--plan required for scripted policy") }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: plan)) else {
                throw ValidationError("cannot read plan file: \(plan)")
            }
            do {
                pol = try ScriptedPolicy(planJSON: data)
            } catch {
                throw ValidationError("""
                    plan file is not valid s1 JSON — expected an array of \
                    {"action":{"<case>":{params}},"rationale":"…"} entries; \
                    single-payload actions wrap their value as "_0". Example: \
                    [{"action":{"openApp":{"name":"TextEdit"}},"rationale":"open"},\
                    {"action":{"typeText":{"_0":"halo"}},"rationale":"type"},\
                    {"action":{"done":{"summary":"ok"}},"confidence":0.9,"rationale":"end"}]
                    """)
            }
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
        } else if let goal { goalText = goal } else if plan != nil {
            // A scripted plan IS the program — the filename is its label.
            goalText = "plan:\(URL(fileURLWithPath: plan ?? "").deletingPathExtension().lastPathComponent)"
        } else {
            throw ValidationError("pass --goal or --task")
        }
        guard !goalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError("empty goal — pass --goal or --task")
        }
        let s2: (any Reasoner)? = s2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil
        // A stale switch from an earlier `s1 stop` would abort this run at
        // step 0 — disarm it now that a run is genuinely starting.
        try? FileManager.default.removeItem(atPath: killSwitch)
        // Live step feed — a 25-step run is otherwise silent for minutes and
        // reads as hung. Same digest format the app feed shows.
        let (report, _) = try await S1Runner.run(goal: goalText, policy: pol, artifacts: artifacts,
                               maxSteps: maxSteps, threshold: threshold, dryRun: dryRun,
                               allowIrreversible: allowIrreversible, killSwitch: killSwitch, s2: s2,
                               onStep: { rec in print(rec.digest) })
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
        if exists {
            let malformed = (try? Data(contentsOf: URL(fileURLWithPath: S1Config.path)))
                .flatMap { try? JSONDecoder().decode(S1Config.self, from: $0) } == nil
            if malformed {
                print("  ⚠ malformed JSON — falling back to defaults; fix or delete the file")
            }
        }
        print("vlm  → \(vlm.baseURL) model=\(vlm.model) numCtx=\(vlm.numCtx)")
        print("s2   → \(s2.baseURL) model=\(s2.model) numCtx=\(s2.numCtx)")
        print("env overrides: S1_VLM_BASE/S1_VLM_MODEL/S1_VLM_KEY, S1_S2_BASE/S1_S2_MODEL/S1_S2_KEY, S1_NUM_CTX")
        let vocab = S1Config.load().vocabulary ?? []
        print("vocabulary → \(vocab.count) custom words + installed app names (auto)")
        let assembled = Vocabulary.assemble(custom: vocab)
        print("  resolved: \(assembled.prefix(10).joined(separator: ", "))\(assembled.count > 10 ? " … (\(assembled.count) total)" : "")")
        print("edit the JSON file to swap brains permanently — no rebuild needed")
        // Reachability: a misconfigured brain is the #1 user-facing failure —
        // say it plainly instead of failing mid-run.
        print("endpoints:")
        for (label, ep) in [("vlm", vlm), ("s2", s2)] {
            print("  \(label) \(await endpointStatus(ep))")
        }
    }

    /// Ping an OpenAI-compatible endpoint: /models (OpenAI) then /api/tags
    /// (Ollama) — 3s budget each, answer is human-readable either way.
    private func endpointStatus(_ ep: Endpoint) async -> String {
        for path in ["/models", "/api/tags"] {
            guard let url = URL(string: ep.baseURL + path) else { break }
            var req = URLRequest(url: url)
            req.timeoutInterval = 3
            if let key = ep.apiKey {
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            }
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  let http = resp as? HTTPURLResponse else { continue }
            if http.statusCode == 200 {
                let body = String(decoding: data, as: UTF8.self)
                let hasModel = (try? JSONSerialization.jsonObject(with: data)) != nil
                    && body.contains(ep.model)
                return "\(ep.baseURL) reachable ✓\(hasModel ? " · \(ep.model) present" : " · WARNING: '\(ep.model)' not listed")"
            }
            if http.statusCode != 404 { return "\(ep.baseURL) → HTTP \(http.statusCode)" }
        }
        return "\(ep.baseURL) unreachable — start the server (e.g. `ollama serve`)"
    }
}

/// config.json vocabulary + a `--vocabulary a,b,c` flag → the full
/// contextual-strings list (installed app names added automatically).
func sttVocabulary(_ csv: String?) -> [String] {
    let flag = csv?.split(separator: ",").map { String($0) } ?? []
    return Vocabulary.assemble(custom: flag + (S1Config.load().vocabulary ?? []))
}

func validatedSTTPolicy(_ policy: String) throws -> String {
    guard ["auto", "ax", "vlm"].contains(policy) else {
        throw ValidationError("unknown policy \(policy) — use auto, ax or vlm")
    }
    return policy
}

/// Shared `auto` resolution: probe the VLM endpoint once, log which brain
/// the run actually got, return the concrete policy.
func resolveAutoPolicy(vlmBase: String?, vlmModel: String?) async -> any Policy {
    let useShot = S1Config.load().vlmScreenshot ?? true
    let (pol, name) = await AutoPolicy.resolve(vlmBase: vlmBase, vlmModel: vlmModel,
                                              useScreenshot: useShot)
    let note = name == "vlm"
        ? "policy auto → vlm (local decision model)\n"
        : "policy auto → ax (model endpoint unreachable — deterministic grammar)\n"
    FileHandle.standardError.write(note.data(using: .utf8)!)
    return pol
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
    @Option(help: "Policy for the run (default auto — model if reachable, else ax).")
    var policy: String = "auto"
    @Option(help: "Artifacts root directory.")
    var artifacts: String = S1Home.path + "/artifacts"
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
        let polName = try validatedSTTPolicy(policy)   // fail fast, before the mic turn
        let stt = SpeechToText(locale: Locale(identifier: locale),
                               vocabulary: sttVocabulary(vocabulary))
        let goal: String
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("audio file not found: \(file)")
            }
            goal = try await stt.transcribe(file: URL(fileURLWithPath: file))
        } else {
            // A live LISTENING daemon owns the mic — two audio engines
            // grabbing it at once fails cryptically. Refuse only when the
            // daemon is actually listening (idle = mic free).
            if let data = FileManager.default.contents(atPath: Serve.statePath),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["state"] as? String) == "listening",
               let pid = (obj["pid"] as? Int).map(pid_t.init),
               S1Runner.pidLooksLikeS1(pid) {
                throw ValidationError(
                    "the s1 listener is actively listening (pid \(pid)) — it owns the mic; " +
                    "say your command to it, or `s1 stop` first")
            }
            print("listening... (speak a command)")
            goal = try await stt.transcribeMic(maxSeconds: 20)
        }
        print("heard: \(goal)")
        guard !goal.isEmpty else { throw ValidationError("nothing transcribed") }

        let pol: any Policy
        switch polName {
        case "vlm":
            pol = VLMPolicy(endpoint: Endpoints.vlm(base: vlmBase, model: vlmModel),
                            useScreenshot: S1Config.load().vlmScreenshot ?? true)
        case "auto":
            pol = await resolveAutoPolicy(vlmBase: vlmBase, vlmModel: vlmModel)
        default:
            pol = AXPolicy()
        }
        let reasoner: (any Reasoner)? = s2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil
        // A fresh listen clears a stale kill switch — the user just asked for
        // a new run, so an old "stop" file must not silently abort step 0.
        let kill = NSTemporaryDirectory() + "s1-stop"
        try? FileManager.default.removeItem(atPath: kill)
        let (report, _) = try await S1Runner.run(goal: goal, policy: pol, artifacts: artifacts,
                               maxSteps: maxSteps, threshold: 0.6, dryRun: dryRun,
                               allowIrreversible: false,
                               killSwitch: kill, s2: reasoner,
                               onStep: { rec in print(rec.digest) })
        if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
        if speak {
            await Speaker().say(locale.hasPrefix("id") ? "Selesai" : "Done", language: locale)
        }
    }
}

struct DemoCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "demo",
        abstract: "Canned P1 demo: open TextEdit, type, verify on-screen.")
    @Option var artifacts: String = S1Home.path + "/artifacts"
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
                               killSwitch: kill,
                               onStep: { rec in print(rec.digest) })
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
        abstract: "Dump an app's accessibility tree (default: frontmost).")
    @Argument(help: "App name or pid to inspect (default: frontmost app).")
    var target: String?

    func run() async throws {
        let app = resolveTarget(target)
        guard let app else { print("no such app running"); throw ExitCode(1) }
        print("\(app.localizedName ?? "?") pid \(app.processIdentifier)")
        guard let tree = AXReader.snapshotTree(pid: app.processIdentifier) else {
            print("no AX tree (check Accessibility permission)"); throw ExitCode(1)
        }
        let flat = tree.flattened
        for n in flat.prefix(250) {
            let label = n.title ?? n.desc ?? n.help ?? n.value ?? ""
            var loc = ""
            if let f = n.frame {
                loc = String(format: "  @(%.0f,%.0f %.0fx%.0f)", f.x, f.y, f.w, f.h)
            }
            print("  \(n.ref) [\(n.role)]\(AXSemantics.markers(for: n.role)) \(label)\(loc)")
        }
        if flat.count > 250 { print("  … \(flat.count - 250) more nodes") }
    }

    /// Frontmost by default; else a running app by pid, exact name, or
    /// case-insensitive substring match (first hit wins).
    private func resolveTarget(_ target: String?) -> NSRunningApplication? {
        let ws = NSWorkspace.shared
        guard let target, !target.isEmpty else { return ws.frontmostApplication }
        if let pid = pid_t(target),
           let app = NSRunningApplication(processIdentifier: pid) { return app }
        let running = ws.runningApplications.filter { $0.localizedName != nil }
        if let exact = running.first(where: {
            $0.localizedName?.caseInsensitiveCompare(target) == .orderedSame }) { return exact }
        return running.first { $0.localizedName?.localizedCaseInsensitiveContains(target) ?? false }
    }
}

struct ServeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve",
        abstract: "Always-on companion: hotkey toggles continuous listening (double-tap Shift or ⌃⌥Space).")
    @Option(help: "STT/TTS locale.")
    var locale: String = "id-ID"
    @Option(help: "Policy for runs (default auto — model if reachable, else ax).")
    var policy: String = "auto"
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
    @Flag(help: "Install as a launchd agent — starts at login, restarts on crash.")
    var install = false
    @Flag(help: "Remove the launchd agent.")
    var uninstall = false


    func run() async throws {
        if uninstall { try manageLaunchAgent(install: false); return }
        if install { try manageLaunchAgent(install: true); return }
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        setbuf(stdout, nil)   // daemon: stream events unbuffered
        _ = try validatedSTTPolicy(policy)
        let stt = SpeechToText(locale: Locale(identifier: locale),
                               vocabulary: sttVocabulary(vocabulary))
        let reasoner: (any Reasoner)? = s2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil
        // Warm the speech model in the background — the first hotkey press
        // shouldn't pay the cold-load cost mid-conversation.
        Task { await stt.warmup() }

        // `auto` resolves ONCE here — a daemon must not re-probe the
        // endpoint on every utterance (each probe is up to 3s).
        let useVLM: Bool
        if policy == "auto" {
            useVLM = await AutoPolicy.endpointAlive(Endpoints.vlm(base: vlmBase, model: vlmModel))
            FileHandle.standardError.write(
                (useVLM ? "policy auto → vlm (local decision model)\n"
                        : "policy auto → ax (model endpoint unreachable — deterministic grammar)\n")
                .data(using: .utf8)!)
        } else {
            useVLM = policy == "vlm"
        }
        let makePol: @Sendable () -> any Policy = {
            guard useVLM else { return AXPolicy() }
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
                artifacts: S1Home.path + "/artifacts", maxSteps: 25, threshold: 0.6, dryRun: false,
                allowIrreversible: false, killSwitch: kill,
                s2: reasoner,
                onStep: { rec in print(rec.digest) })
            if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
            if speak {
                let done = locale.hasPrefix("id") ? "Selesai" : "Done"
                await Speaker().say(done, language: locale)
            }
            return
        }

        // One listener per machine: a second daemon would double-trigger on
        // the same hotkey and compete for the mic. The app writes the same
        // pid file, so `s1 serve` next to S1.app is refused too. Atomic
        // (O_EXCL): two serves launched at the same instant can't both win.
        let pidPath = NSHomeDirectory() + "/.s1/serve.pid"
        try S1Runner.claimPidFile(pidPath, what: "s1 listener")
        // Pid-checked release: if the file was stolen and re-claimed by a
        // competitor daemon, our exit must not delete THEIR lock.
        defer { S1Runner.releasePidFile(pidPath) }

        // `s1 stop` sends SIGTERM and Ctrl-C sends SIGINT — neither runs
        // `defer`, so the pid file would linger as a stale artifact. Take
        // them via GCD: ignore the default disposition, clean up, exit.
        // A global queue, not .main — dispatch signal sources only deliver
        // on .main while the main thread sits in dispatchMain(), and this
        // CLI's main is parked in a CFRunLoop instead.
        // The sources must stay retained or they cancel on dealloc (which
        // would leave the signals ignored with no handler at all).
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            src.setEventHandler {
                // `_exit`, not `exit`: stdio locks held by a print on another
                // thread would deadlock atexit processing.
                S1Runner.releasePidFile(pidPath)
                _exit(0)
            }
            src.resume()
            KeepAlive.signalSources.append(src)
        }

        let serve = Serve(
            config: .init(makePolicy: makePol, s2: reasoner, speak: speak,
                          listenSeconds: listenSeconds, maxSilentTurns: idleTurns,
                          lockPath: pidPath,
                          transcribe: { try await stt.transcribeMic(maxSeconds: listenSeconds) }),
            locale: Locale(identifier: locale),
            hotkeyPatterns: [Hotkey.doubleShift, Hotkey.defaultChord]
        ) { ev in
            print("[\(ev.kind.rawValue)] \(ev.text)")
        }
        serve.armHotkey()
        print("serve armed — double-tap Shift or ⌃⌥Space toggles listening")
        print("say \"stop\"/\"berhenti\" to sleep · Ctrl-C quits")
        if wake { serve.wake() }
        // The global hotkey monitor's handler is delivered through the
        // MAIN run loop, so main must actually spin — queue CFRunLoop there
        // (NSApplication touch first: NSEvent monitors in a CLI need the app
        // object; accessory policy = no dock icon), then park this task.
        DispatchQueue.main.async {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            // CFRunLoopRun exits when every source is gone — if the tap is
            // ever invalidated (TCC change, transient failure) the daemon
            // must not silently die; re-enter (with a beat, so a sourceless
            // loop doesn't spin) so `s1 stop`/the pid file stay
            // authoritative.
            while true {
                CFRunLoopRun()
                Thread.sleep(forTimeInterval: 0.5)
            }
        }
        while true { try await Task.sleep(for: .seconds(3600)) }
    }

    /// `s1 serve --install` / `--uninstall` — a real launchd agent so the
    /// listener is always on: launches at login, relaunches after a crash
    /// (KeepAlive on non-successful exit — a clean `s1 stop`/Ctrl-C is a
    /// successful exit and stays authoritative).
    func manageLaunchAgent(install: Bool) throws {
        let fm = FileManager.default
        let domain = "gui/\(getuid())"
        let plistPath = ServeLaunchd.plistPath
        if !install {
            _ = launchctl(["bootout", "\(domain)/\(ServeLaunchd.label)"], quiet: true)
            try? fm.removeItem(atPath: plistPath)
            print("launch agent removed: \(plistPath)")
            return
        }
        try fm.createDirectory(
            atPath: (plistPath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        _ = launchctl(["bootout", "\(domain)/\(ServeLaunchd.label)"], quiet: true)  // replace cleanly
        // launchd does NOT create StandardOutPath parent dirs — a fresh
        // machine without ~/.s1 would run the agent with its log lost.
        try fm.createDirectory(atPath: S1Home.path, withIntermediateDirectories: true)
        // Refuse while a listener that ISN'T our agent holds the lock —
        // the agent would fail claimPidFile, exit non-zero, and KeepAlive
        // would respawn-churn against it forever. Our own agent was already
        // booted out above, so any live holder here is a manual serve/app.
        if let live = S1Runner.livePidHolder(
            of: NSHomeDirectory() + "/.s1/serve.pid") {
            throw S1Error.aborted(
                "a listener is already running (pid \(live)) — `s1 stop` it first, " +
                "then re-run `s1 serve --install`")
        }
        // Armed, not --wake: "always on" means the hotkey is ready at
        // login — not a mic that comes up live before anyone asks.
        var args = [s1BinaryPath(), "serve",
                    "--locale", locale, "--policy", policy,
                    "--idle-turns", "\(idleTurns)",
                    "--listen-seconds", "\(listenSeconds)"]
        if s2 { args.append("--s2") }
        if speak { args.append("--speak") }
        if let v = vlmBase { args += ["--vlm-base", v] }
        if let v = vlmModel { args += ["--vlm-model", v] }
        if let v = vocabulary { args += ["--vocabulary", v] }
        try ServeLaunchd.plist(args: args)
            .write(toFile: plistPath, atomically: true, encoding: .utf8)
        guard launchctl(["bootstrap", domain, plistPath]) == 0 else {
            throw S1Error.aborted("launchctl bootstrap failed — plist at \(plistPath)")
        }
        _ = launchctl(["kickstart", "-k", "\(domain)/\(ServeLaunchd.label)"])
        print("installed + started: \(plistPath)")
        print("logs: ~/.s1/serve.log · stop now: s1 stop · remove for good: s1 serve --uninstall")
    }

    /// Absolute path to this very binary (argv[0] may be a bare `s1` —
    /// resolve it through PATH so the agent survives PATH-less launchd).
    private func s1BinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        // launchd execs without our cwd — a relative argv[0] like
        // `.build/debug/s1` must become absolute or the agent can't start.
        if arg0.contains("/") { return URL(fileURLWithPath: arg0).path }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = dir + "/" + arg0
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return arg0
    }

    private func launchctl(_ args: [String], quiet: Bool = false) -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        if quiet { p.standardError = FileHandle.nullDevice }
        try? p.run()
        p.waitUntilExit()
        return p.terminationStatus
    }
}

/// Lifetime holder for the serve command's signal sources — released sources
/// cancel on dealloc, which would leave SIGTERM/SIGINT ignored with no
/// handler at all.
private enum KeepAlive {
    /// Filled once before the daemon parks; never touched concurrently.
    nonisolated(unsafe) static var signalSources: [DispatchSourceSignal] = []
}

struct TasksCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tasks",
        abstract: "List the task library (tasks/*.txt) usable with --task.")
    @Option(help: "Task library directory.")
    var dir: String = "tasks"

    func run() async throws {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else {
            print("no task library at \(dir)/ — create tasks/<name>.txt files")
            return
        }
        for n in names.sorted() where n.hasSuffix(".txt") {
            let name = String(n.dropLast(4))
            let first = (try? String(contentsOfFile: "\(dir)/\(n)", encoding: .utf8))?
                .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
            print("\(name)\(first.isEmpty ? "" : "  —  \(first)")")
        }
    }
}

struct MetricsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "metrics",
        abstract: "Summarize a run's steps.jsonl: decisions, escalations, errors, verifies.")
    @Argument(help: "Run directory (contains steps.jsonl).")
    var runDir: String

    func run() async throws {
        guard FileManager.default.fileExists(
            atPath: runDir + "/steps.jsonl") else {
            throw ValidationError("not a run directory (no steps.jsonl): \(runDir)")
        }
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

struct StatusCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status",
        abstract: "Is a listener daemon alive, what state is it in, and is a run active?")

    func run() async throws {
        // Listener daemon — pid file + liveness. The daemon's published
        // state tells the richer story (armed-idle vs listening vs working).
        var daemonState: String?
        var daemonAlive = false
        if let data = FileManager.default.contents(atPath: Serve.statePath),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let pid = (obj["pid"] as? Int).map({ pid_t($0) }),
           S1Runner.pidLooksLikeS1(pid) {
            daemonAlive = true
            daemonState = obj["state"] as? String
            let ev = (obj["event"] as? String) ?? "?"
            let detail = (obj["detail"] as? String) ?? ""
            let st = daemonState ?? "?"
            print("state        \(st) · \(ev)\(detail.isEmpty ? "" : " · \(detail)")")
            if let at = obj["updated"] as? String { print("updated      \(at)") }
        }
        let servePid = NSHomeDirectory() + "/.s1/serve.pid"
        if let txt = try? String(contentsOfFile: servePid, encoding: .utf8),
           let pid = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
           S1Runner.pidLooksLikeS1(pid) {
            // `s1 stop` lands the kill file but an active listener only sees
            // it at the next turn — "stopping" until then. An idle companion
            // ignores the file entirely (wake() clears it), so don't claim
            // it's about to stop.
            let stopPending = (daemonState == "listening" || daemonState == "running")
                && (FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "s1-serve-stop")
                    || FileManager.default.fileExists(atPath: NSTemporaryDirectory() + "s1-app-stop"))
            let mode = stopPending ? "stopping"
                : daemonAlive && daemonState != nil ? "\(daemonState!)"
                : "running"
            print("listener     \(mode) (pid \(pid))")
        } else {
            print("listener     not running")
        }
        // Active agent run (the screen-ownership lock).
        let runState = S1Runner.anotherRunActive() ? "in progress (other process)" : "none"
        print("run          \(runState)")
    }
}

struct StopCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop",
        abstract: "Stop everything: abort any in-flight run and put the listener to sleep.")

    func run() async throws {
        var did = false
        // Land every kill switch — an in-flight run aborts at its next step.
        for f in ["s1-stop", "s1-serve-stop", "s1-app-stop"] {
            try? "stop".write(toFile: NSTemporaryDirectory() + f,
                             atomically: true, encoding: .utf8)
        }
        // Ask a live CLI listener daemon to quit entirely. The GUI app gets
        // the kill-switch treatment instead: its serve loop sleeps on the
        // stop file, its runs abort — SIGTERM would kill the app window
        // outright (no cleanup, stale pid file).
        let servePid = NSHomeDirectory() + "/.s1/serve.pid"
        if let txt = try? String(contentsOfFile: servePid, encoding: .utf8),
           let pid = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
           S1Runner.pidLooksLikeS1(pid) {
            let isApp = S1Runner.pidExePath(pid)?.contains(".app/") ?? false
            if isApp {
                print("app listener pid \(pid): stop file sent (sleeps the listener)")
            } else {
                kill(pid, SIGTERM)
                print("listener pid \(pid): SIGTERM sent")
            }
            did = true
        }
        if S1Runner.anotherRunActive() {
            print("run abort queued (kill switch lands at the next step)")
            did = true
        }
        print(did ? "stopped" : "nothing running — kill switches armed anyway")
    }
}

struct ReplayCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "replay",
        abstract: "Re-execute a run's recorded actions against the live screen.")
    @Argument(help: "Run directory to replay (contains steps.jsonl).")
    var runDir: String
    @Option(help: "Artifacts root for the replay run.")
    var artifacts: String = S1Home.path + "/artifacts"
    @Flag(help: "Log everything, execute nothing.")
    var dryRun = false
    @Flag(help: "Queue irreversible actions for human confirmation.")
    var allowIrreversible = false

    func run() async throws {
        guard FileManager.default.fileExists(
            atPath: runDir + "/steps.jsonl") else {
            throw ValidationError("not a run directory (no steps.jsonl): \(runDir)")
        }
        let src = URL(fileURLWithPath: runDir)
        let kill = NSTemporaryDirectory() + "s1-stop"
        if !dryRun {
            // Same gate as a live run — replayed clicks/types need trust
            // or they land nowhere while the log claims they happened.
            try S1Runner.requireAccessibility()
            try? FileManager.default.removeItem(atPath: kill)  // don't inherit a stale stop
            try S1Runner.acquireRunLock()   // live replay types/clicks — same lock as a run
        }
        defer { if !dryRun { S1Runner.releaseRunLock() } }
        let logger = try RunLogger(goal: "replay:\(src.lastPathComponent)",
                                   root: URL(fileURLWithPath: artifacts),
                                   config: ["mode": dryRun ? "dry-run" : "live", "source": runDir],
                                   onStep: { rec in print(rec.digest) })
        let actuator: any Actuator = dryRun ? DryRunActuator() : CGEventActuator()
        let gate = SafetyGate(allowIrreversible: allowIrreversible)
        let n = try await RunReader.replay(runDir: src, into: logger,
                                           actuator: actuator, gate: gate,
                                           killSwitchPath: dryRun ? nil : kill)
        print("replay run dir: \(logger.runDir.path)")
        print("replayed \(n) steps")
    }
}
