import Testing
import Foundation
@testable import S1Core

// Confirm-and-continue for gated steps: which steps may be approved, the
// answer parser, and the loop's behavior on yes / no / stop.

private func tmp(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("s1-confirm-\(tag)-\(UUID().uuidString)")
}

private struct Spy: Actuator {
    let name = "spy"
    let done = Locked<[Action]>([])
    func perform(_ action: Action, frontmostPID: pid_t?) async throws -> String {
        done.withLock { $0.append(action) }
        return "did"
    }
}

private func run(_ steps: [Action], confirm: ConfirmHandler?, obs: Snapshot? = nil,
                 actuator: any Actuator, gate: SafetyGate = SafetyGate(),
                 kill: String? = nil) async throws -> (RunReport, [StepRecord]) {
    var cfg = LoopConfig()
    cfg.killSwitchPath = kill
    let logger = try RunLogger(goal: "t", root: tmp("run"), config: [:])
    let loop = AgentLoop(config: cfg, perceiver: NullPerceiver(observation: obs), actuator: actuator,
                         gate: gate, confirm: confirm)
    let plan = ScriptedPolicy(steps: steps.map { .init(action: $0, confidence: 1) })
    let report = try await loop.run(goal: "g", policy: plan, logger: logger)
    return (report, try RunReader.steps(in: logger.runDir))
}

@Test func onlySomeGatedStepsCanBeApproved() {
    let g = SafetyGate()
    #expect(g.confirmable(.keyCombo(keys: ["cmd", "q"])))
    #expect(g.confirmable(.keyCombo(keys: ["cmd", "delete"])))
    #expect(g.confirmable(.menuItem(path: ["File", "Move to Trash"])))
    // Credentials, payments, script, s1's own hotkeys, the lock screen: never.
    #expect(!g.confirmable(.typeText("my password is hunter2")))
    #expect(!g.confirmable(.typeText("click buy now")))
    #expect(!g.confirmable(.openURL("javascript:alert(1)")))
    #expect(!g.confirmable(.keyCombo(keys: ["ctrl", "opt", "space"])))
    #expect(!g.confirmable(.keyCombo(keys: ["ctrl", "cmd", "q"])))
    // Allowed and denied steps aren't questions at all.
    #expect(!g.confirmable(.click(x: 10, y: 10)))
    #expect(!g.confirmable(.shell(command: "ls")))                     // denied without --allow-irreversible
    #expect(SafetyGate(allowIrreversible: true).confirmable(.shell(command: "ls")))
    // Terminal: deleting a file can be approved; sudo can't.
    #expect(SafetyGate.assessTerminalPayload("rm notes.txt").confirmable)
    #expect(!SafetyGate.assessTerminalPayload("sudo reboot").confirmable)
}

@Test func answersAreReadSafely() {
    for yes in ["yes", "Yes please", "ya", "iya boleh", "go ahead", "do it", "lanjut", "y", "ok"] {
        #expect(Confirmation.answer(yes) == true, "\(yes)")
    }
    for no in ["no", "nope", "don't do it", "nggak usah", "jangan", "cancel", "tidak", "n", "ya jangan"] {
        #expect(Confirmation.answer(no) == false, "\(no)")
    }
    for unclear in ["", "what was that", "yes but also the other file", "hmm"] {
        #expect(Confirmation.answer(unclear) == nil, "\(unclear)")
    }
}

@Test func silenceIsNotAYes() async {
    let yes = await Confirmation.bounded(0.2) {
        try? await Task.sleep(for: .seconds(5))
        return true
    }
    #expect(!yes)
}

@Test func approvedStepRunsAndTheRunGoesOn() async throws {
    let asked = Locked<[ConfirmRequest]>([])
    let spy = Spy()
    let (report, recs) = try await run([.menuItem(path: ["File", "Move to Trash"]), .done(summary: "ok")],
                                       confirm: { req in asked.withLock { $0.append(req) }; return true },
                                       actuator: spy)
    #expect(report.status == .done)
    #expect(asked.value.count == 1)
    #expect(spy.done.value.filter { $0 == .menuItem(path: ["File", "Move to Trash"]) }.count == 1)
    #expect(recs.first?.gate.hasPrefix("allow(you approved") == true)
}

@Test func declinedStepNeverRuns() async throws {
    let spy = Spy()
    let (report, recs) = try await run([.keyCombo(keys: ["cmd", "q"])], confirm: { _ in false }, actuator: spy)
    #expect(report.status == .needsHuman)
    #expect(spy.done.value.isEmpty)
    #expect(recs.first?.outcome?.contains("you said no") == true)
}

@Test func humanOnlyStepsAreNeverAsked() async throws {
    var obs = Snapshot(timestamp: Date(), frontmostApp: "App", frontmostPID: 1, windows: [], axTree: nil, screenshotPath: nil)
    obs.secureTextFocused = true
    let asked = Locked(0)
    let spy = Spy()
    // Pasting into a password box, and typing a credential: no question, no action.
    for a: Action in [.keyCombo(keys: ["cmd", "v"]), .typeText("my password is hunter2")] {
        let (report, _) = try await run([a], confirm: { _ in asked.withLock { $0 += 1 }; return true },
                                        obs: obs, actuator: spy)
        #expect(report.status == .needsHuman)
    }
    #expect(asked.value == 0)
    #expect(spy.done.value.isEmpty)
}

@Test func dryRunsAskNothing() async throws {
    let asked = Locked(0)
    let (report, _) = try await run([.keyCombo(keys: ["cmd", "q"])],
                                    confirm: { _ in asked.withLock { $0 += 1 }; return true },
                                    actuator: DryRunActuator())
    #expect(report.status == .needsHuman)
    #expect(asked.value == 0)
}

@Test func stopWhileWaitingEndsTheRun() async throws {
    let kill = tmp("kill").path
    let spy = Spy()
    Task {
        try? await Task.sleep(for: .milliseconds(400))
        try? "stop".write(toFile: kill, atomically: true, encoding: .utf8)
    }
    let started = Date()
    let (report, recs) = try await run([.keyCombo(keys: ["cmd", "q"])],
                                       confirm: { _ in try? await Task.sleep(for: .seconds(20)); return true },
                                       actuator: spy, kill: kill)
    #expect(report.status == .aborted)
    #expect(Date().timeIntervalSince(started) < 5)
    #expect(spy.done.value.isEmpty)
    #expect(recs.last?.outcome == "stopped while waiting for you")
}

@Test func spokenQuestionsReadKeysAsWords() {
    #expect(Serve.speakable("⌘Q quits the app") == "command Q quits the app")
    #expect(Serve.speakable("“File › Move to Trash” can't be undone") == "File, Move to Trash can't be undone")
    let q = Serve.question(ConfirmRequest(action: .keyCombo(keys: ["cmd", "q"]), reason: "r"), code: "id")
    #expect(q.contains("ya atau tidak"))
}

@Test func stopPressedOnTheQuestionIsAStopNotANo() async throws {
    let kill = tmp("kill2").path
    let (report, recs) = try await run([.keyCombo(keys: ["cmd", "q"])],
                                       confirm: { _ in
                                           try? "stop".write(toFile: kill, atomically: true, encoding: .utf8)
                                           return false
                                       },
                                       actuator: Spy(), kill: kill)
    #expect(report.status == .aborted)
    #expect(recs.last?.outcome == "stopped while waiting for you")
}
