import Testing
import Foundation
@testable import S1Core

private func jsonlDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}

// MARK: - Gate

@Test func gateAllowsReadOnly() {
    let g = SafetyGate()
    #expect(g.evaluate(.captureScreenshot(reason: "x")) == .allow)
    #expect(g.evaluate(.verify(expectation: "x")) == .allow)
    #expect(g.evaluate(.done(summary: "x")) == .allow)
}

@Test func gateAllowsReversibleWhenEnabled() {
    #expect(SafetyGate(allowReversible: true).evaluate(.click(x: 1, y: 1)) == .allow)
    #expect(SafetyGate(allowReversible: false).evaluate(.click(x: 1, y: 1)) != .allow)
}

@Test func gateRejectsIrreversibleByDefault() {
    let g = SafetyGate()
    if case .deny = g.evaluate(.shell(command: "ls")) {} else { Issue.record("shell should be denied") }
    if case .needsHuman = SafetyGate(allowIrreversible: true).evaluate(.shell(command: "ls")) {} else {
        Issue.record("irreversible should queue for human")
    }
}

@Test func gateDenyListAlwaysWins() {
    // Credentials never execute, even with --allow-irreversible.
    for g in [SafetyGate(), SafetyGate(allowIrreversible: true)] {
        if case .needsHuman = g.evaluate(.typeText("enter your password here")) {} else {
            Issue.record("password text must escalate")
        }
        if case .needsHuman = g.evaluate(.typeText("CVV: 123")) {} else {
            Issue.record("CVV must escalate")
        }
        if case .needsHuman = g.evaluate(.shell(command: "rm -rf /")) {} else {
            Issue.record("rm -rf must escalate")
        }
    }
    // Innocent text still types fine.
    #expect(SafetyGate().evaluate(.typeText("hello world")) == .allow)
}

// MARK: - steps.jsonl format

@Test func stepRecordSerializesToSingleJSONLine() throws {
    let r = StepRecord(index: 3, time: Date(timeIntervalSince1970: 0),
                       observation: "App | windows:2", decidedBy: "s1:scripted",
                       confidence: 0.9, rationale: "test",
                       action: .typeText("hi"), gate: "allow",
                       outcome: "typed 2 chars", verified: nil, escalation: nil)
    let line = try r.jsonLine()
    #expect(!line.contains("\n"))
    let back = try jsonlDecoder().decode(StepRecord.self, from: Data(line.utf8))
    #expect(back.index == 3)
    #expect(back.decidedBy == "s1:scripted")
    #expect(back.confidence == 0.9)
    if case .typeText(let t)? = back.action { #expect(t == "hi") } else { Issue.record("action lost") }
}

@Test func escalationRoundTripsInJSONL() throws {
    let r = StepRecord(index: 0, time: Date(), observation: "x", decidedBy: "s1:dummy",
                       confidence: 0.1, rationale: "unsure", action: nil, gate: "-",
                       outcome: nil, verified: nil,
                       escalation: .init(to: "s2:none", reason: "conf 0.1 < 0.6"))
    let back = try jsonlDecoder().decode(StepRecord.self, from: Data(try r.jsonLine().utf8))
    #expect(back.escalation?.to == "s2:none")
    #expect(back.escalation?.reason.contains("0.1") == true)
}

// MARK: - Dry run never acts

@Test func dryRunActuatorTouchesNothing() async throws {
    let a = DryRunActuator()
    let out = try await a.perform(.typeText("never typed"), frontmostPID: nil)
    #expect(out.contains("[dry-run]"))
    #expect(a.name == "dry-run")
}

// MARK: - Loop behavior

@Test func lowConfidenceEscalatesAndStopsWithoutS2() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s1test-\(UUID().uuidString)")
    let logger = try RunLogger(goal: "test", root: dir, config: [:])
    var cfg = LoopConfig(); cfg.confidenceThreshold = 0.6
    let loop = AgentLoop(config: cfg, perceiver: NullPerceiver(),
                         actuator: DryRunActuator(), gate: SafetyGate())
    let report = try await loop.run(goal: "g", policy: DummyPolicy(confidence: 0.1), logger: logger)
    #expect(report.status == .escalatedToS2)
    #expect(report.escalations == 1)
    let lines = try String(contentsOf: logger.runDir.appendingPathComponent("steps.jsonl"), encoding: .utf8)
        .split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines[0].contains("\"escalation\""))
}

@Test func scriptedRunCompletesAndLogsEveryStep() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s1test-\(UUID().uuidString)")
    let logger = try RunLogger(goal: "test", root: dir, config: [:])
    var cfg = LoopConfig(); cfg.confidenceThreshold = 0.6
    let loop = AgentLoop(config: cfg, perceiver: NullPerceiver(),
                         actuator: DryRunActuator(), gate: SafetyGate())
    let plan = ScriptedPolicy(steps: [
        .init(action: .moveMouse(x: 1, y: 2)),
        .init(action: .typeText("hello")),
        .init(action: .done(summary: "fin")),
    ])
    let report = try await loop.run(goal: "g", policy: plan, logger: logger)
    #expect(report.status == .done)
    #expect(report.steps == 3)
    let lines = try String(contentsOf: logger.runDir.appendingPathComponent("steps.jsonl"), encoding: .utf8)
        .split(separator: "\n")
    #expect(lines.count == 3)
    for line in lines {
        _ = try jsonlDecoder().decode(StepRecord.self, from: Data(line.utf8))
    }
}

@Test func killSwitchFileAbortsRun() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s1test-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let stop = dir.appendingPathComponent("stop")
    try "x".write(to: stop, atomically: true, encoding: .utf8)
    let logger = try RunLogger(goal: "test", root: dir, config: [:])
    var cfg = LoopConfig(); cfg.killSwitchPath = stop.path
    let loop = AgentLoop(config: cfg, perceiver: NullPerceiver(),
                         actuator: DryRunActuator(), gate: SafetyGate())
    let report = try await loop.run(goal: "g",
                                    policy: ScriptedPolicy(steps: [.init(action: .wait(seconds: 0.01))]),
                                    logger: logger)
    #expect(report.status == .aborted)
}

@Test func denylistedActionNeverReachesActuator() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s1test-\(UUID().uuidString)")
    let logger = try RunLogger(goal: "test", root: dir, config: [:])
    let loop = AgentLoop(config: LoopConfig(), perceiver: NullPerceiver(),
                         actuator: DryRunActuator(), gate: SafetyGate())
    let plan = ScriptedPolicy(steps: [
        .init(action: .typeText("my password is x"), confidence: 1.0),
    ])
    let report = try await loop.run(goal: "g", policy: plan, logger: logger)
    #expect(report.status == .needsHuman)
    let lines = try String(contentsOf: logger.runDir.appendingPathComponent("steps.jsonl"), encoding: .utf8)
    #expect(lines.contains("needsHuman"))
    #expect(!lines.contains("typed"))   // outcome is "blocked", never "typed"
}
