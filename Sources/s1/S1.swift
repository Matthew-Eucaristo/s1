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
                      TasksCmd.self, StatusCmd.self, StopCmd.self, CleanCmd.self,
                      ModelsCmd.self, PullCmd.self, GroundCmd.self, DecideCmd.self,
                      KeyCmd.self])
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
    @Option(help: "Task library name — reads tasks/<name>.txt (cwd) or ~/.s1/tasks/<name>.txt as the goal.")
    var task: String?
    @Option(help: "Policy: auto | scripted | dummy | ax | vlm (default: auto; --plan implies scripted)")
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
        case "auto":  pol = await resolveAutoPolicy(vlmBase: vlmBase, vlmModel: vlmModel,
                                                    screenshot: vlmScreenshot)
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
        default: throw ValidationError("unknown policy \(policyName) — use auto, ax, vlm, scripted or dummy")
        }
        let goalText: String
        if let task {
            // A bare name searches the task library: cwd's tasks/ first
            // (repo checkout — devs iterating on a task file), then
            // ~/.s1/tasks/ (a brew user's persistent library — the cask
            // ships no tasks/ and works from any directory). An explicit
            // path (contains "/" or ends .txt) is used as-is.
            let explicit = task.contains("/") || task.hasSuffix(".txt")
            let candidates = explicit
                ? [task]
                : ["tasks/\(task).txt", S1Home.path + "/tasks/\(task).txt"]
            var found: String?
            for p in candidates {
                if let g = try? String(contentsOfFile: p, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines), !g.isEmpty {
                    found = g; break
                }
            }
            guard let g = found else {
                throw ValidationError(
                    "task file not found or empty: \(candidates.joined(separator: " or "))")
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
        let (report, _) = try await S1Runner.run(goal: goalText, policy: JudgedPolicy.wrapIfConfigured(pol), artifacts: artifacts,
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
        let grounder = Endpoints.grounder()
        print("grounder → \(grounder.map { "\($0.baseURL) model=\($0.model)" } ?? "none (VLM grounds clicks itself)")")
        let decision = Endpoints.decision()
        print("decision → \(decision.map { "\($0.baseURL) model=\($0.model)" } ?? "none (no S1 decision judge)")")
        let keys = ModelRole.allCases.map { r in
            "\(r.rawValue)=\(SecretStore.has(account: r.rawValue) ? "keychain" : "-")" }
        print("api keys → \(keys.joined(separator: " ")) (set with `s1 key set <role>`)")
        print("env overrides: S1_DECISION_BASE/S1_DECISION_MODEL/S1_DECISION_KEY, S1_VLM_BASE/S1_VLM_MODEL/S1_VLM_KEY, S1_S2_BASE/S1_S2_MODEL/S1_S2_KEY, S1_GROUNDER_BASE/S1_GROUNDER_MODEL/S1_GROUNDER_KEY, S1_NUM_CTX")
        let cfg = S1Config.load()
        // The CLI honors these too — surface the values a flag-less run
        // will actually get (flag → config → default).
        print("locale → \(cfg.locale ?? "id-ID (default)") · speak → \(cfg.speak ?? false) · notchHUD → \(cfg.notchHUD ?? true)")
        let vocab = cfg.vocabulary ?? []
        print("vocabulary → \(vocab.count) custom words + installed app names (auto)")
        let assembled = Vocabulary.assemble(custom: vocab)
        print("  resolved: \(assembled.prefix(10).joined(separator: ", ").terminalSafe)\(assembled.count > 10 ? " … (\(assembled.count) total)" : "")")
        print("edit the JSON file to swap brains permanently — no rebuild needed")
        // Reachability: a misconfigured brain is the #1 user-facing failure —
        // say it plainly instead of failing mid-run.
        print("endpoints:")
        for (label, ep) in [("vlm", vlm), ("s2", s2)] + (grounder.map { [("grounder", $0)] } ?? []) {
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
                let hasModel = AutoPolicy.modelListed(ep.model, in: data)
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
    let flag = csv?.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces) } ?? []
    return Vocabulary.assemble(custom: flag + (S1Config.load().vocabulary ?? []))
}

func validatedSTTPolicy(_ policy: String) throws -> String {
    guard ["auto", "ax", "vlm"].contains(policy) else {
        throw ValidationError("unknown policy \(policy) — use auto, ax or vlm")
    }
    return policy
}

/// `--locale`/`--language` flags → config.json's `locale` → id-ID, in that
/// order. The app writes the same key, so the GUI language picker and the
/// CLI speak the same language without re-flagging every call.
func resolveLocale(_ flag: String?) -> String {
    flag ?? S1Config.load().locale ?? "id-ID"
}

/// Claim the mic for a foreground command — the lock file is atomic, so
/// a listening daemon, another foreground capture, or a daemon that wakes
/// mid-recording all resolve to one owner. The holder check is only for
/// a friendly error; the claim is what actually serializes.
func claimMicOrThrow() throws {
    if let pid = S1Runner.livePidHolder(of: S1Runner.micPidPath) {
        throw ValidationError(
            "the mic is already owned by s1 pid \(pid) — `s1 stop` a listening " +
            "daemon first, or wait for the other capture to finish")
    }
    try S1Runner.claimMic()
}

/// Shared `auto` resolution: probe the VLM endpoint once, log which brain
/// the run actually got, return the concrete policy.
func resolveAutoPolicy(vlmBase: String?, vlmModel: String?,
                       screenshot: Bool? = nil) async -> any Policy {
    let useShot = screenshot ?? S1Config.load().vlmScreenshot ?? true
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
    @Option(help: "Locale, e.g. id-ID, en-US (default: config locale, else id-ID).")
    var locale: String?
    @Option(help: "Max seconds of mic recording when --file is omitted.")
    var maxSeconds: Double = 15
    @Option(help: "Comma-separated words the recognizer should bias toward.")
    var vocabulary: String?

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        let stt = SpeechToText(locale: Locale(identifier: resolveLocale(locale)),
                               vocabulary: sttVocabulary(vocabulary))
        let text: String
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("audio file not found: \(file)")
            }
            text = try await stt.transcribe(file: URL(fileURLWithPath: file))
        } else {
            // The mic lock serializes against a listening daemon AND
            // another foreground capture — two engines fail cryptically.
            try claimMicOrThrow()
            defer { S1Runner.releaseMic() }
            // stderr, not stdout — piped output must be the transcript alone.
            FileHandle.standardError.write("listening... (speak)\n".data(using: .utf8)!)
            text = try await stt.transcribeMic(maxSeconds: maxSeconds)
        }
        // The transcript is model-derived — strip control chars before it
        // reaches the user's terminal (audio can smuggle ESC/OSC sequences).
        print(text.terminalSafe)
    }
}

struct SayCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "say",
        abstract: "On-device TTS (AVSpeechSynthesizer).")
    @Argument(help: "Text to speak.")
    var text: String
    @Option(help: "Voice language, e.g. id-ID, en-US (default: config locale, else id-ID).")
    var language: String?

    func run() async throws {
        await Speaker().say(text, language: resolveLocale(language))
    }
}

struct ListenCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "listen",
        abstract: "Voice-first: hear a command, run it, speak the result.")
    @Option(help: "Transcribe this audio file instead of the mic (testing).")
    var file: String?
    @Option(help: "STT/TTS locale (default: config locale, else id-ID).")
    var locale: String?
    @Option(help: "Policy for the run (default auto — model if reachable, else ax).")
    var policy: String = "auto"
    @Option(help: "Artifacts root directory.")
    var artifacts: String = S1Home.path + "/artifacts"
    @Flag(inversion: .prefixedNo,
          help: "Speak the result with TTS (default: config speak, else off).")
    var speak: Bool?
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
        let loc = resolveLocale(locale)
        let stt = SpeechToText(locale: Locale(identifier: loc),
                               vocabulary: sttVocabulary(vocabulary))
        let goal: String
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("audio file not found: \(file)")
            }
            goal = try await stt.transcribe(file: URL(fileURLWithPath: file))
        } else {
            // Same mic lock as `s1 transcribe` — daemon or peer capture,
            // one owner at a time.
            try claimMicOrThrow()
            defer { S1Runner.releaseMic() }
            FileHandle.standardError.write("listening... (speak a command)\n".data(using: .utf8)!)
            goal = try await stt.transcribeMic(maxSeconds: 20)
        }
        print("heard: \(goal.terminalSafe)")
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
        let (report, _) = try await S1Runner.run(goal: goal, policy: JudgedPolicy.wrapIfConfigured(pol), artifacts: artifacts,
                               maxSteps: maxSteps, threshold: 0.6, dryRun: dryRun,
                               allowIrreversible: false,
                               killSwitch: kill, s2: reasoner,
                               onStep: { rec in print(rec.digest) })
        if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
        if speak ?? S1Config.load().speak ?? false {
            await Speaker().say(loc.hasPrefix("id") ? "Selesai" : "Done", language: loc)
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
        // A parent that doesn't exist used to surface as a bare ExitCode(1)
        // with no message — create it, the user asked for this exact path.
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw ValidationError("cannot create image destination for \(out)")
        }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ValidationError("cannot write screenshot to \(out)")
        }
        print("wrote \(out) (\(img.width)x\(img.height))")
    }
}

struct GroundCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ground",
        abstract: "Ask the click grounder where a target is in an image (debug a grounding model).")
    @Argument(help: "Screenshot path (PNG/JPEG).") var image: String
    @Argument(help: "What to click, e.g. \"Save button\".") var target: String
    @Option(help: "Grounder model (default: configured grounder, else the VLM model).") var model: String?
    @Option(help: "OpenAI-compatible base URL (default: configured).") var base: String?

    func run() async throws {
        let cfgEp = Endpoints.grounder() ?? Endpoints.vlm()
        let ep = Endpoint(baseURL: base ?? cfgEp.baseURL, model: model ?? cfgEp.model,
                          apiKey: cfgEp.apiKey, numCtx: cfgEp.numCtx)
        guard FileManager.default.fileExists(atPath: image),
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: image) as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let b64 = VLMPolicy.downscaledJPEG(path: image) else {
            throw ValidationError("cannot read image \(image)")
        }
        let started = Date()
        let (p, reply) = try await Grounder(endpoint: ep).normalizedPoint(target, imageBase64: b64)
        let secs = String(format: "%.1f", Date().timeIntervalSince(started))
        print("model    \(ep.model) (\(secs)s)")
        print("reply    \(reply.trimmingCharacters(in: .whitespacesAndNewlines).terminalSafe)")
        guard let p else {
            print("point    none (unparseable or outside [0,1000])")
            throw ExitCode(2)
        }
        let px = Int(p.x / 1000 * Double(img.width)), py = Int(p.y / 1000 * Double(img.height))
        print("point    (\(Int(p.x)), \(Int(p.y))) /1000 → pixel (\(px), \(py)) in \(img.width)x\(img.height)")
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
            // App-controlled text straight to a terminal: strip escapes.
            let label = (n.title ?? n.desc ?? n.help ?? n.value ?? "").terminalSafe
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
        // Bundle id first — `s1 ax com.apple.Notes` is the developer-facing
        // spelling, and a name substring could hit the wrong sibling app.
        if let byId = running.first(where: {
            $0.bundleIdentifier?.caseInsensitiveCompare(target) == .orderedSame }) { return byId }
        if let exact = running.first(where: {
            $0.localizedName?.caseInsensitiveCompare(target) == .orderedSame }) { return exact }
        return running.first { $0.localizedName?.localizedCaseInsensitiveContains(target) ?? false }
    }
}

struct ServeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "serve",
        abstract: "Always-on companion: hotkey toggles continuous listening (double-tap Shift or ⌃⌥Space).")
    @Option(help: "STT/TTS locale (default: config locale, else id-ID).")
    var locale: String?
    @Option(help: "Policy for runs (default auto — model if reachable, else ax).")
    var policy: String = "auto"
    @Flag(help: "Enable System 2 escalation (LLM endpoint).")
    var s2 = false
    @Flag(inversion: .prefixedNo,
          help: "Speak results with TTS (default: config speak, else off).")
    var speak: Bool?
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
        let loc = resolveLocale(locale)
        let resolvedSpeak = speak ?? S1Config.load().speak ?? false
        setbuf(stdout, nil)   // daemon: stream events unbuffered
        _ = try validatedSTTPolicy(policy)
        let stt = SpeechToText(locale: Locale(identifier: loc),
                               vocabulary: sttVocabulary(vocabulary))
        let reasoner: (any Reasoner)? = s2 ? LLMReasoner(endpoint: Endpoints.s2()) : nil
        // Warm the speech model in the background — the first hotkey press
        // shouldn't pay the cold-load cost mid-conversation.
        Task { await stt.warmup() }

        // `auto` resolves once here — a daemon must not re-probe the
        // endpoint on every utterance (each probe is up to 3s). But the
        // daemon also outlives the endpoint: if Ollama comes up AFTER
        // `s1 serve` started, a once-probe pins it to `ax` forever. So the
        // flag lives in a box; while it's down a slow background re-probe
        // upgrades the brain when the endpoint answers (upgrade only — a
        // dead endpoint mid-run still fails per-step, which is honest).
        let vlmUp = LockedBox(false)
        if policy == "auto" {
            vlmUp.value = await AutoPolicy.endpointAlive(Endpoints.vlm(base: vlmBase, model: vlmModel))
            FileHandle.standardError.write(
                (vlmUp.value ? "policy auto → vlm (local decision model)\n"
                        : "policy auto → ax (model endpoint unreachable — deterministic grammar)\n")
                .data(using: .utf8)!)
            if !vlmUp.value {
                Task.detached {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .seconds(60))
                        if Task.isCancelled { return }
                        vlmUp.value = await AutoPolicy.endpointAlive(
                            Endpoints.vlm(base: vlmBase, model: vlmModel))
                        if vlmUp.value {
                            FileHandle.standardError.write(
                                "policy auto → vlm (endpoint came up — brain upgraded)\n"
                                    .data(using: .utf8)!)
                            return
                        }
                    }
                }
            }
        } else {
            vlmUp.value = policy == "vlm"
        }
        let decisionEp = Endpoints.decision()
        let makePol: @Sendable () -> any Policy = {
            let pol: any Policy = vlmUp.value
                ? VLMPolicy(endpoint: Endpoints.vlm(base: vlmBase, model: vlmModel),
                            useScreenshot: S1Config.load().vlmScreenshot ?? true)
                : AXPolicy()
            return JudgedPolicy.wrapIfConfigured(pol, endpoint: decisionEp)
        }

        // --file: one utterance through the same pipeline, then exit.
        if let file {
            guard FileManager.default.fileExists(atPath: file) else {
                throw ValidationError("audio file not found: \(file)")
            }
            let text = try await stt.transcribe(file: URL(fileURLWithPath: file))
            print("heard: \(text.terminalSafe)")
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
            if resolvedSpeak {
                let done = loc.hasPrefix("id") ? "Selesai" : "Done"
                await Speaker().say(done, language: loc)
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
            config: .init(makePolicy: makePol, s2: reasoner, speak: resolvedSpeak,
                          listenSeconds: listenSeconds, maxSilentTurns: idleTurns,
                          lockPath: pidPath,
                          transcribe: { onPartial in
                              try await stt.transcribeMic(maxSeconds: listenSeconds) { p in
                                  // Live best-guess on the tty — same
                                  // "words landing" feedback the app shows.
                                  FileHandle.standardError.write(Data("\r\(p)   ".utf8))
                              }
                          }),
            locale: Locale(identifier: loc),
            hotkeyPatterns: [Hotkey.doubleShift, Hotkey.defaultChord]
        ) { ev in
            // Event text carries transcripts/goal/error strings — same
            // derived-source rule as heard/digest: never raw to the tty.
            print("[\(ev.kind.rawValue)] \(ev.text.terminalSafe)")
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
        // Locale/speak forward their RESOLVED values — the plist pins the
        // daemon to the config the installer saw, not whatever config.json
        // says months later (a surprise voice/locale change on agent start).
        var args = [s1BinaryPath(), "serve",
                    "--locale", resolveLocale(locale), "--policy", policy,
                    "--idle-turns", "\(idleTurns)",
                    "--listen-seconds", "\(listenSeconds)",
                    (speak ?? S1Config.load().speak ?? false) ? "--speak" : "--no-speak"]
        if s2 { args.append("--s2") }
        if let v = vlmBase { args += ["--vlm-base", v] }
        if let v = vlmModel { args += ["--vlm-model", v] }
        if let v = vocabulary { args += ["--vocabulary", v] }
        try ServeLaunchd.plist(args: args)
            .write(toFile: plistPath, atomically: true, encoding: .utf8)
        guard launchctl(["bootstrap", domain, plistPath]) == 0 else {
            throw S1Error.aborted("launchctl bootstrap failed — plist at \(plistPath)")
        }
        _ = launchctl(["kickstart", "-k", "\(domain)/\(ServeLaunchd.label)"])
        // Don't just claim "started": the agent proves itself by claiming
        // ~/.s1/serve.pid. A job that never claims it (blocked in dyld,
        // a bad plist arg, a crash loop) leaves nothing listening — the
        // lock check above only guarded against a live holder, not a
        // dead-on-arrival agent. Poll briefly and report honestly.
        var claimed = false
        for _ in 0 ..< 50 {
            if S1Runner.livePidHolder(
                of: NSHomeDirectory() + "/.s1/serve.pid") != nil {
                claimed = true
                break
            }
            usleep(100_000)
        }
        print(claimed ? "installed + started: \(plistPath)"
                      : "installed: \(plistPath)")
        if !claimed {
            FileHandle.standardError.write(
                ("warning: listener hasn't come up within 5s — the agent " +
                 "is installed and will retry via launchd; check " +
                 "`s1 status` and ~/.s1/serve.log\n").data(using: .utf8)!)
        }
        print("logs: ~/.s1/serve.log · stop now: s1 stop · remove for good: s1 serve --uninstall")
    }

    /// Absolute path to this very binary (argv[0] may be a bare `s1` —
    /// resolve it through PATH so the agent survives PATH-less launchd).
    private func s1BinaryPath() -> String {
        let arg0 = CommandLine.arguments[0]
        // launchd execs without our cwd — a relative argv[0] like
        // `.build/debug/s1` must become absolute or the agent can't start.
        let found: String
        if arg0.contains("/") {
            found = URL(fileURLWithPath: arg0).path
        } else {
            found = (ProcessInfo.processInfo.environment["PATH"] ?? "")
                .split(separator: ":")
                .map { $0 + "/" + arg0 }
                .first { FileManager.default.isExecutableFile(atPath: $0) }
                ?? arg0
        }
        // Resolve the symlink: brew cask installs link `s1` → the app
        // bundle's Resources binary — the plist should point at the real
        // file, not at a link that can move with a reinstall.
        return URL(fileURLWithPath: found).resolvingSymlinksInPath().path
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

/// Lock-protected value readable from @Sendable closures (the auto brain's
/// upgrade probe lands off the serve loop's thread).
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var _v: Value
    init(_ v: Value) { _v = v }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return _v }
        set { lock.lock(); _v = newValue; lock.unlock() }
    }
}

struct TasksCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "tasks",
        abstract: "List the task library usable with --task.")
    @Option(help: "Task library directory to list instead of the defaults.")
    var dir: String?

    func run() async throws {
        // Same search order --task uses: cwd tasks/ (repo), then the
        // persistent per-user library under ~/.s1/tasks/.
        let dirs = dir.map { [$0] } ?? ["tasks", S1Home.path + "/tasks"]
        var listed = 0
        for d in dirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: d) else { continue }
            let txts = names.sorted().filter { $0.hasSuffix(".txt") }
            guard !txts.isEmpty else { continue }
            print("\(d)/")
            for n in txts {
                let name = String(n.dropLast(4))
                let first = (try? String(contentsOfFile: "\(d)/\(n)", encoding: .utf8))?
                    .components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
                print("  \(name)\(first.isEmpty ? "" : "  —  \(first)")")
            }
            listed += txts.count
        }
        if listed == 0 {
            print("no tasks — create tasks/<name>.txt (repo) or \(S1Home.path)/tasks/<name>.txt")
        }
    }
}

struct ModelsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "models",
        abstract: "List installed Ollama models and the downloadable catalog.")

    func run() async throws {
        guard ModelPull.ollamaBinary() != nil else {
            print("ollama not installed — \(ModelPull.installHint)")
            return
        }
        let installed = Set(ModelPull.installed())
        print("installed (ollama list):")
        if installed.isEmpty { print("  (none)") }
        for m in installed.sorted() { print("  \(m)") }
        print("\ncatalog — `s1 pull <name>`:")
        for e in ModelPull.catalog {
            let mark = installed.contains(e.name) ? "✓" : " "
            let kind = e.vision ? "vision" : "text  "
            print("  [\(mark)] \(e.name)\t\(e.size)\t\(kind)\t\(e.blurb)")
        }
    }
}

struct PullCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull",
        abstract: "Download a model with `ollama pull` (progress streams to stdout).")
    @Argument(help: "Model name, e.g. gemma3:4b — any model ollama can pull, not just the app catalog.")
    var model: String

    func run() async throws {
        let last = Locked()
        try await ModelPull.pull(model: model) { line in
            last.printOnce(line)
        }
        print("installed \(model)")
    }
}

/// Dedupes ollama's progress redraws before printing — the pull callback
/// is @Sendable and may fire on another queue.
private final class Locked: @unchecked Sendable {
    private let lock = NSLock()
    private var last = ""
    func printOnce(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        guard line != last else { return }
        last = line
        print(line)
    }
}

struct MetricsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "metrics",
        abstract: "Summarize a run's steps.jsonl: decisions, escalations, errors, verifies.")
    @Argument(help: "Run directory (contains steps.jsonl). Default: newest run.")
    var runDir: String?

    /// The explicit dir when given; otherwise the newest run under
    /// ~/.s1/artifacts (names start with an ISO timestamp, so the
    /// lexicographically last entry IS the newest). `s1 metrics` with no
    /// arg means "the run I just did" 95% of the time.
    static func resolveRunDir(_ dir: String?) throws -> String {
        if let dir {
            guard FileManager.default.fileExists(atPath: dir + "/steps.jsonl") else {
                throw ValidationError("not a run directory (no steps.jsonl): \(dir)")
            }
            return dir
        }
        let root = S1Home.path + "/artifacts"
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: root),
              // Walk backwards past stray files: an unrelated "zzz.txt"
              // dropped in artifacts/ must not shadow real run dirs.
              let latest = entries.sorted().last(where: {
                  FileManager.default.fileExists(atPath: root + "/" + $0 + "/steps.jsonl")
              }) else {
            throw ValidationError("no run dirs under \(root) — run something first")
        }
        return root + "/" + latest
    }

    func run() async throws {
        let dir = try Self.resolveRunDir(runDir)
        let m = try RunReader.metrics(in: URL(fileURLWithPath: dir))
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

struct CleanCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clean",
        abstract: "Delete run artifacts (~/.s1/artifacts). Runs auto-prune to the newest 50; this wipes all.")
    @Option(help: "Artifacts root directory.")
    var artifacts: String = S1Home.path + "/artifacts"

    func run() async throws {
        let n = ArtifactStore.cleanAll(root: URL(fileURLWithPath: artifacts))
        print("removed \(n) run dir\(n == 1 ? "" : "s") from \(artifacts)")
        // serve.log never rotates (launchd appends forever) — reclaim it
        // here too so `s1 clean` is the one-stop `~/.s1` reset. But only
        // when NO live daemon holds it: launchd's stdout fd keeps its own
        // offset, so truncating under a running agent leaves the next
        // write landing at the old offset — a sparse file of NULs.
        let log = S1Home.path + "/serve.log"
        let daemonAlive = S1Runner.livePidHolder(
            of: NSHomeDirectory() + "/.s1/serve.pid") != nil
        if daemonAlive {
            print("kept \(log) — a live listener holds it (`s1 stop` first)")
        } else if FileManager.default.fileExists(atPath: log),
           let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: log)) {
            try? h.truncate(atOffset: 0)
            try? h.close()
            print("truncated \(log)")
        }
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
            // `detail` carries transcript/model text — terminal-safe it.
            let detail = ((obj["detail"] as? String) ?? "").terminalSafe
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
            // The daemon only watches ITS kill file (the app watches
            // s1-app-stop, the CLI watches s1-serve-stop) — a stale file
            // for the other context must not claim "stopping".
            let isApp = S1Runner.pidExePath(pid)?.contains(".app/") ?? false
            let stopFile = NSTemporaryDirectory() + (isApp ? "s1-app-stop" : "s1-serve-stop")
            let stopPending = (daemonState == "listening" || daemonState == "runStart")
                && FileManager.default.fileExists(atPath: stopFile)
            let mode = stopPending ? "stopping"
                : daemonAlive && daemonState != nil ? "\(daemonState!)"
                : "running"
            print("listener     \(mode) (pid \(pid))")
        } else {
            // Nothing listening — but an installed launchd agent may be
            // mid-retry or dead-on-arrival. Surface it so "not running"
            // never reads as "nothing was ever set up".
            let la = NSHomeDirectory() + "/Library/LaunchAgents"
            let agentInstalled = FileManager.default.fileExists(
                atPath: ServeLaunchd.plistPath)
                || FileManager.default.fileExists(
                    atPath: la + "/sh.brew.s1.plist")
            print("listener     not running"
                + (agentInstalled ? " · launch agent installed" : ""))
        }
        // Active agent run (the screen-ownership lock).
        let runState = S1Runner.anotherRunActive() ? "in progress (other process)" : "none"
        print("run          \(runState)")
        // ~/.s1 footprint — the answer to "is s1 eating my disk" at a glance.
        if let bytes = dirSize(S1Home.path) {
            print("storage      \(formatBytes(bytes)) in \(S1Home.path) (s1 clean wipes artifacts)")
        }
    }

    private func dirSize(_ path: String) -> Int64? {
        guard let en = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]) else { return nil }
        var total: Int64 = 0
        for case let url as URL in en {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    private func formatBytes(_ b: Int64) -> String {
        if b < 1024 { return "\(b) B" }
        if b < 1024 * 1024 { return String(format: "%.0f KB", Double(b) / 1024) }
        if b < 1024 * 1024 * 1024 { return String(format: "%.1f MB", Double(b) / 1_048_576) }
        return String(format: "%.2f GB", Double(b) / 1_073_741_824)
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
    @Argument(help: "Run directory to replay (contains steps.jsonl). Default: newest run.")
    var runDir: String?
    @Option(help: "Artifacts root for the replay run.")
    var artifacts: String = S1Home.path + "/artifacts"
    @Flag(help: "Log everything, execute nothing.")
    var dryRun = false
    @Flag(help: "Queue irreversible actions for human confirmation.")
    var allowIrreversible = false

    func run() async throws {
        let dir = try MetricsCmd.resolveRunDir(runDir)
        let src = URL(fileURLWithPath: dir)
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
                                   config: ["mode": dryRun ? "dry-run" : "live", "source": dir],
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

struct DecideCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "decide",
        abstract: "Ask the S1 decision model one typed question (System One API: Ollama, Jev, Clef).")
    @Argument(help: "State text to judge.") var state: String
    @Argument(help: "The question, e.g. \"Is this urgent?\"") var question: String
    @Option(help: "Comma-separated options → a Choice question (default: yes/no Noul).") var options: String?
    @Option(help: "Decision model (default: configured, e.g. nimble, tev1, jev-latest, clef).") var model: String?
    @Option(help: "Server root (default: configured, else http://localhost:11434).") var base: String?

    func run() async throws {
        let cfg = Endpoints.decision()
        guard let name = model ?? cfg?.model else {
            throw ValidationError("no decision model — pass --model (e.g. tev1:0.8b) or set one in the app's Connections")
        }
        let ep = Endpoint(baseURL: base ?? cfg?.baseURL ?? "http://localhost:11434", model: name,
                          apiKey: cfg?.apiKey)
        let q: DecisionQuestion = options.map { o in
            .choice(question, options: Dictionary(uniqueKeysWithValues: o.split(separator: ",")
                .map { (String($0).trimmingCharacters(in: .whitespaces), String?.none) }))
        } ?? .noul(question)
        let started = Date()
        let r = try await SystemOneClient(endpoint: ep, timeout: 120)
            .evaluate(state: .string(state), questions: ["q": q])
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        print("model    \((r.model ?? name).terminalSafe) (\(ms) ms)")
        guard let a = r.answers["q"] else { print("answer   none"); throw ExitCode(2) }
        if let p = a.noul { print(String(format: "yes      %.3f", p)) }
        if let c = a.choice { print("choice   \(c.terminalSafe)") }
        if let s = a.score { print(String(format: "score    %.3f", s)) }
        for (k, v) in (a.probabilities ?? [:]).sorted(by: { $0.value > $1.value }) {
            print(String(format: "  %-12@ %.3f", k.terminalSafe, v))
        }
        if let c = a.confidence { print(String(format: "confidence %.3f", c)) }
    }
}

struct KeyCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "key",
        abstract: "Store API keys in the macOS Keychain (never in config.json).",
        subcommands: [Set.self, Remove.self, List.self])

    static func role(_ s: String) throws -> ModelRole {
        guard let r = ModelRole(rawValue: s) else {
            throw ValidationError("role must be one of: \(ModelRole.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return r
    }

    struct Set: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set",
            abstract: "Read a key from stdin (hidden when interactive) into the Keychain.")
        @Argument(help: "decision | vlm | grounder | s2") var role: String
        func run() async throws {
            let r = try KeyCmd.role(role)
            let raw: String?
            if isatty(STDIN_FILENO) != 0 {
                var buf = [CChar](repeating: 0, count: 4096)
                raw = readpassphrase("\(r.rawValue) API key: ", &buf, buf.count, 0).map { String(cString: $0) }
                buf.withUnsafeMutableBytes { memset_s($0.baseAddress, $0.count, 0, $0.count) }
            } else {
                raw = readLine(strippingNewline: true)
            }
            guard let key = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else {
                throw ValidationError("empty key")
            }
            try SecretStore.set(key, account: r.rawValue)
            try S1Config.stripPlaintextKey(r)
            print("saved \(r.rawValue) key to Keychain (\(SecretStore.defaultService))")
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Delete a role's key.")
        @Argument(help: "decision | vlm | grounder | s2") var role: String
        func run() async throws {
            let r = try KeyCmd.role(role)
            SecretStore.delete(account: r.rawValue)
            try S1Config.stripPlaintextKey(r)
            print("removed \(r.rawValue) key")
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "ls", abstract: "Which roles have a key (values never shown).")
        func run() async throws {
            for r in ModelRole.allCases {
                print("\(r.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0)) \(SecretStore.has(account: r.rawValue) ? "keychain ✓" : "—")")
            }
        }
    }
}
