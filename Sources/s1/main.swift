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
        subcommands: [PreflightCmd.self, RunCmd.self, DemoCmd.self, CaptureCmd.self, AXCmd.self])
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
    @Option(help: "Policy: scripted | dummy")
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

    func run() async throws {
        let pol: any Policy
        switch policy {
        case "dummy": pol = DummyPolicy()
        case "scripted":
            guard let plan else { throw ValidationError("--plan required for scripted policy") }
            pol = try ScriptedPolicy(planJSON: Data(contentsOf: URL(fileURLWithPath: plan)))
        default: throw ValidationError("unknown policy \(policy)")
        }
        try await S1Runner.run(goal: goal, policy: pol, artifacts: artifacts,
                               maxSteps: maxSteps, threshold: threshold, dryRun: dryRun,
                               allowIrreversible: allowIrreversible, killSwitch: killSwitch)
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
