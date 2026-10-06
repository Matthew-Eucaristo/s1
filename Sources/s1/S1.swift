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
                      ProvidersCmd.self, ConnectCmd.self, DisconnectCmd.self, UseCmd.self,
                      ModelsCmd.self, PullCmd.self, DecideCmd.self,
                      UsageCmd.self, SetupCmd.self, DoctorCmd.self])
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
    @Option(help: "Policy: auto (grammar + your Judge, System 1) | ax (grammar only) | scripted | dummy (default auto; --plan implies scripted)")
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
    @Flag(inversion: .prefixedNo, help: "Escalate hard steps to the assigned Reasoner (System 2).")
    var s2 = true

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
        case "auto", "ax": pol = try makePolicy(policyName)
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
        default: throw ValidationError("unknown policy \(policyName) — use auto, ax, scripted or dummy")
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
        let s2: (any Reasoner)? = cliReasoner(s2)
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

/// config.json vocabulary + a `--vocabulary a,b,c` flag → the full
/// contextual-strings list (installed app names added automatically).
func sttVocabulary(_ csv: String?) -> [String] {
    let flag = csv?.split(separator: ",").map {
        $0.trimmingCharacters(in: .whitespaces) } ?? []
    return Vocabulary.assemble(custom: flag + (S1Config.load().vocabulary ?? []))
}

/// `--locale`/`--language` flags → config.json's `locale` → auto, in that
/// order. The app writes the same key, so the GUI language picker and the
/// CLI speak the same language without re-flagging every call.
func resolveLocale(_ flag: String?) -> String {
    flag ?? S1Config.load().locale ?? SpokenLanguage.auto
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


struct TranscribeCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "transcribe",
        abstract: "On-device STT: transcribe an audio file (or the mic).")
    @Option(help: "Audio file to transcribe (.aiff/.wav).")
    var file: String?
    @Option(help: "Locale, e.g. id-ID, en-US, or auto (default: config locale, else auto-detect).")
    var locale: String?
    @Option(help: "Max seconds of mic recording when --file is omitted.")
    var maxSeconds: Double = 15
    @Option(help: "Comma-separated words the recognizer should bias toward.")
    var vocabulary: String?

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        let stt = SpeechToText(locales: SpokenLanguage.candidates(for: resolveLocale(locale)),
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
    @Option(help: "Voice language, e.g. id-ID, en-US (default: config locale, else auto-detect).")
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
    @Option(help: "STT/TTS locale (default: config locale, else auto-detect).")
    var locale: String?
    @Option(help: "Policy: auto (grammar + your Judge, System 1) | ax (grammar only).")
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
    @Flag(inversion: .prefixedNo, help: "Escalate hard steps to the assigned Reasoner (System 2).")
    var s2 = true
    @Option(help: "Comma-separated words the recognizer should bias toward.")
    var vocabulary: String?

    func run() async throws {
        guard #available(macOS 26, *) else {
            throw ValidationError("SpeechAnalyzer needs macOS 26+")
        }
        let pol = try makePolicy(policy)   // fail fast, before the mic turn
        let loc = resolveLocale(locale)
        let stt = SpeechToText(locales: SpokenLanguage.candidates(for: loc),
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

        let reasoner: (any Reasoner)? = cliReasoner(s2)
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
    @Option(help: "STT/TTS locale (default: config locale, else auto-detect).")
    var locale: String?
    @Option(help: "Policy: auto (grammar + your Judge, System 1) | ax (grammar only).")
    var policy: String = "auto"
    @Flag(inversion: .prefixedNo, help: "Escalate hard steps to the assigned Reasoner (System 2).")
    var s2 = true
    @Flag(inversion: .prefixedNo,
          help: "Speak results with TTS (default: config speak, else off).")
    var speak: Bool?
    @Option(help: "Silent turns before auto-sleep.")
    var idleTurns: Int = 3
    @Option(help: "Seconds per listening turn.")
    var listenSeconds: Double = 12
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
        let polName = policy
        _ = try makePolicy(polName)   // fail fast on a bad policy name
        let stt = SpeechToText(locales: SpokenLanguage.candidates(for: loc),
                               vocabulary: sttVocabulary(vocabulary))
        let reasoner: (any Reasoner)? = cliReasoner(s2)
        // Warm the speech model in the background — the first hotkey press
        // shouldn't pay the cold-load cost mid-conversation.
        Task { await stt.warmup() }
        FileHandle.standardError.write(Data("brain: \(Brain.describe())\n".utf8))
        // Rebuilt per utterance: a model assigned in the app (or with
        // `s1 use`) while the daemon runs applies to the next command.
        let makePol: @Sendable () -> any Policy = { (try? makePolicy(polName)) ?? AXPolicy() }

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
                          },
                          languages: SpokenLanguage.candidates(for: loc),
                          voice: S1Config.load().voice,
                          voiceInterrupt: S1Config.voiceInterruptEnabled()),
            locale: SpokenLanguage.candidates(for: loc)[0],
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
        args.append(s2 ? "--s2" : "--no-s2")
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

struct PullCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "pull",
        abstract: "Download a model with `ollama pull` (progress streams to stdout).")
    @Argument(help: "Model name, e.g. gemma3:4b — any model ollama can pull (`s1 models ollama` lists picks).")
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
        abstract: "Ask the Judge (System 1) one typed question (System One API: Jev, d1, Clef, Ollama).")
    @Argument(help: "State text to judge.") var state: String
    @Argument(help: "The question, e.g. \"Is this urgent?\"") var question: String
    @Option(help: "Comma-separated options → a Choice question (default: yes/no Noul).") var options: String?
    @Option(help: "provider/model to ask (default: the judge role), e.g. ollama/tev1:0.8b.") var model: String?

    func run() async throws {
        let ep: Endpoint
        if let model {
            guard let ref = ModelRef(model), let p = Models.provider(ref.provider),
                  let base = p.base(.systemOne, model: ref.model) else {
                throw ValidationError("expected a provider/model whose provider speaks the System One API, got \(model)")
            }
            ep = Endpoint(baseURL: base, model: ref.model, apiKey: Models.keychain(p))
        } else if let e = Models.endpoint(.judge) {
            ep = e
        } else {
            throw ValidationError("no judge assigned — pass --model (e.g. ollama/tev1:0.8b) or `s1 use judge …`")
        }
        let name = ep.model
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

struct UsageCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "usage",
        abstract: "Model usage per role/model: calls, tokens, prompt-cache hits (from ~/.s1/usage.jsonl).")
    @Option(help: "Only the last N days.") var days: Int = 30
    @Flag(help: "Print raw JSONL records instead of the summary.") var raw = false

    func run() async throws {
        let recs = UsageLog.load(since: Date().addingTimeInterval(-Double(days) * 86_400))
        if raw {
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = .sortedKeys
            for r in recs { if let d = try? enc.encode(r) { print(String(decoding: d, as: UTF8.self)) } }
            return
        }
        guard !recs.isEmpty else { print("no model calls logged in the last \(days) days"); return }
        print("role          model                         calls  fail  input     output   cached  hit%  avg ms")
        for s in UsageLog.summarize(recs) {
            let hit = s.cacheHitRate.map { String(format: "%4.0f", $0 * 100) } ?? "   -"
            print(String(format: "%@ %@ %5d %5d %9d %9d %8d  %@ %7d",
                         s.role.padding(toLength: 13, withPad: " ", startingAt: 0),
                         s.model.padding(toLength: 29, withPad: " ", startingAt: 0),
                         s.calls, s.failures, s.input, s.output, s.cached, hit, s.avgMs))
        }
        print("log: \(UsageLog.path)")
    }
}

/// `s1 doctor` — every standardized file under ~/.s1 checked at once, plus
/// the moving parts outside it (keychain keys, cua-driver, srt). Exit 1
/// when anything fails so scripts can gate on it.
struct DoctorCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "doctor",
        abstract: "Check every ~/.s1 file (config, providers + roles, snippets, convert, skills, memory, tasks), cua-driver, sandbox.")
    @Flag(help: "Also fix what's fixable: write missing default files, rebuild the memory index.")
    var fix = false

    func run() async throws {
        if fix {
            if !FileManager.default.fileExists(atPath: Convert.extensionsPath.path) {
                try? "{\n  \"units\": { },\n  \"currencies\": { }\n}\n"
                    .write(to: Convert.extensionsPath, atomically: true, encoding: .utf8)
            }
            try? Memory.rebuildIndex()
            print("wrote missing defaults + rebuilt the memory index\n")
        }
        var fails = 0, warns = 0
        for item in Doctor.run() {
            let mark = switch item.level {
            case .ok: " \u{2713}"
            case .warn: " \u{26A0}"; case .fail: " \u{2717}"
            }
            if item.level == .fail { fails += 1 } else if item.level == .warn { warns += 1 }
            print("\(mark) \(item.what)\(item.detail.isEmpty ? "" : " — \(item.detail)")")
        }
        print("\n\(fails == 0 ? "all good" : "\(fails) failing")"
            + (warns == 0 ? "" : ", \(warns) warning\(warns == 1 ? "" : "s")")
            + " — files live in ~/.s1, edit them like any config")
        if fails > 0 { throw ExitCode(1) }
    }
}

/// `s1 setup` — the first-run flow in one command: permissions, a config
/// file with the recommended hosted defaults, cua-driver via CUA's own
/// installer, API keys into the Keychain, then a doctor pass. Mirrors the
/// app's onboarding wizard so a brew/CLI user gets the same start.
struct SetupCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "setup",
        abstract: "First-run setup: permissions, defaults, Cua Driver, API keys — the same flow the app's onboarding runs.")
    @Flag(help: "Install Cua Driver (default on; CUA's official installer).")
    var installCua = false
    @Flag(help: "Skip the Cua Driver step entirely.")
    var noCua = false
    @Flag(help: "Answer no prompts — write defaults and stop (for scripts).")
    var nonInteractive = false

    func run() async throws {
        let interactive = !nonInteractive && isatty(STDIN_FILENO) != 0
        print("s1 setup — everything lands in ~/.s1 as plain files you can edit\n")

        // 1 · Permissions — the one thing a CLI can't grant for you.
        let r = Preflight.check(request: interactive)
        print(Preflight.describe(r))
        if !r.accessibility {
            print("→ grant Accessibility, then re-run `s1 setup` — everything below still ran.")
        }

        // 2 · Config defaults — write config.json only when absent so a
        // re-run never stomps the user's edits. `ensureFile` helpers do
        // the same for the standardized data files.
        let fresh = !FileManager.default.fileExists(atPath: S1Config.path)
        try S1Config.update { $0.onboarded = true }
        print(fresh ? "✓ wrote \(S1Config.path)" : "✓ config.json already yours — marked onboarded, nothing overwritten")

        // 3 · Cua Driver — recommended, via CUA's own installer.
        if CuaInstaller.installed {
            print("✓ cua-driver already installed")
            if interactive {
                // The driver carries its own TCC identity — without its own
                // AX/Screen Recording grants every call falls back to CGEvent.
                do { try await CuaInstaller.grantPermissions { print("  " + $0) } }
                catch { print("- cua permissions grant skipped: \(error.localizedDescription)") }
            }
        } else if noCua {
            print("- cua-driver skipped (--no-cua); CGEvent executor stays active")
        } else if installCua || (interactive && askYes("Install Cua Driver? (recommended — CUA's official installer) [Y/n] ")) {
            do {
                print("  running: \(CuaInstaller.officialCommand)")
                try await CuaInstaller.install { print("  " + $0) }
                print("✓ cua-driver installed — s1's executor will use it")
                // Same again: the driver needs its own TCC grants (its own
                // identity), so run CUA's grant flow right after install.
                try await CuaInstaller.grantPermissions { print("  " + $0) }
            } catch {
                FileHandle.standardError.write(
                    "✗ \(error.localizedDescription)\n  s1 still works — CGEvent is the fallback.\n".data(using: .utf8)!)
            }
        } else {
            print("- cua-driver not installed (run `s1 setup --install-cua` anytime);")
            print("  recommended for the most faithful typing/keys — CGEvent is the fallback")
        }

        // 4 · Models — optional; the grammar works without any. The
        // recommended pair: TypeSafe Jev judges steps, OpenCode Go reasons.
        if interactive {
            for id in ["typesafe", "opencode"] {
                guard let t = ProviderCatalog.template(id) else { continue }
                if S1Config.load().providers?.contains(where: { $0.id == id }) == true {
                    print("✓ \(t.name) already connected")
                    continue
                }
                guard askYes("Connect \(t.name)? (\(t.summary) — key at \(t.keyURL ?? "")) [Y/n] ") else { continue }
                guard let key = readSecret("\(t.name) API key: ") else {
                    print("- empty — skipped (`s1 connect \(id)` later)")
                    continue
                }
                try SecretStore.set(key, account: id)
                var cfg = S1Config.load()
                let took = Models.connect(ProviderConfig(id: id), in: &cfg)
                try cfg.save()
                print("✓ \(t.name) connected" + (took.isEmpty ? "" : " — \(took.map(\.rawValue).joined(separator: ", "))"))
            }
        } else {
            print("- model prompts skipped (non-interactive) — `s1 connect typesafe` / `s1 connect opencode`")
        }

        // 5 · Doctor — prove the whole layout is sane before saying done.
        print("\n── doctor ───────────────────────────")
        var fails = 0
        for item in Doctor.run() {
            if item.level == .fail { fails += 1 }
            let mark = item.level == .ok ? " ✓" : item.level == .warn ? " ⚠" : " ✗"
            print("\(mark) \(item.what)\(item.detail.isEmpty ? "" : " — \(item.detail)")")
        }
        print("\ns1 is ready. Try: s1 run --goal \"open Notes\" — or say things like")
        print("  \"remember that apps: my editor is Zed\" · \"list my tasks\" · s1 serve")
        if fails > 0 { throw ExitCode(1) }
    }

    /// y/N prompt — Enter means yes (the recommended path is one keypress).
    private func askYes(_ prompt: String) -> Bool {
        FileHandle.standardOutput.write(prompt.data(using: .utf8)!)
        guard let line = readLine() else { return false }
        let a = line.trimmingCharacters(in: .whitespaces).lowercased()
        return a.isEmpty || a.hasPrefix("y")
    }
}
