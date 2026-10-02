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
                       modelReply: nil, action: .typeText("hi"), gate: "allow",
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
                       confidence: 0.1, rationale: "unsure", modelReply: nil, action: nil, gate: "-",
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

// MARK: - AXPolicy (deterministic S1)

@Test func axPolicyParsesIntentList() {
    let intents = AXPolicy.intents(of: "open TextEdit, type halo, done")
    #expect(intents.count == 3)
    #expect(intents[0].verb == "open" && intents[0].arg == "TextEdit")
    #expect(intents[1].verb == "type" && intents[1].arg == "halo")
    #expect(intents[2].verb == "done")
}

@Test func axPolicyConsumesIntentsByHistory() async throws {
    let pol = AXPolicy()
    let obs = Observation(timestamp: Date(), frontmostApp: nil, frontmostPID: nil,
                          windows: [], axTree: nil, screenshotPath: nil)
    let d1 = try await pol.decide(observation: obs, goal: "open Safari, done", history: [])
    if case .openApp(let name)? = d1.action { #expect(name == "Safari") } else { Issue.record("expected openApp") }
    let fake = StepRecord(index: 0, time: Date(), observation: "x", decidedBy: "s1:ax",
                          confidence: 1, rationale: "", modelReply: nil, action: .openApp(name: "Safari"),
                          gate: "allow", outcome: "", verified: nil, escalation: nil)
    let d2 = try await pol.decide(observation: obs, goal: "open Safari, done", history: [fake])
    if case .done? = d2.action {} else { Issue.record("expected done") }
}

@Test func axPolicyMatchesAXElementAndClickUnknownVerbAbstains() async throws {
    let pol = AXPolicy()
    let node = AXNode(ref: "e5", role: "AXButton", title: "Save", value: nil,
                      frame: CGRectCodable(CGRect(x: 10, y: 20, width: 40, height: 20)), children: [])
    let tree = AXNode(ref: "e0", role: "AXApplication", title: "App", value: nil,
                      frame: nil, children: [node])
    let obs = Observation(timestamp: Date(), frontmostApp: "App", frontmostPID: 1,
                          windows: [], axTree: tree, screenshotPath: nil)
    let d = try await pol.decide(observation: obs, goal: "click Save", history: [])
    if case .axPress(let ref)? = d.action { #expect(ref == "e5") } else { Issue.record("expected axPress e5") }
    #expect(d.confidence > 0.6)

    // Unknown verb → abstains at low confidence → loop escalates to S2.
    let d2 = try await pol.decide(observation: obs, goal: "teleport home", history: [])
    #expect(d2.action == nil && d2.confidence < 0.6)
}

// MARK: - LLM decision codec

@Test func llmCodecParsesJSONInsideProse() throws {
    let reply = """
        Sure! Here's my decision:
        {"action":{"type":"axPress","ref":"e7"},"confidence":0.8,"rationale":"press save"}
        hope that helps
        """
    let d = LLMDecisionCodec.parse(reply)
    #expect(d?.confidence == 0.8)
    if case .axPress(let ref)?? = d?.action { #expect(ref == "e7") } else { Issue.record("expected axPress") }
}

@Test func llmCodecConvertsClickWithRefToAxPress() {
    let d = LLMDecisionCodec.parse("""
        {"action":{"type":"click","ref":"e3"},"confidence":0.9,"rationale":"x"}
        """)
    if case .axPress(let ref)?? = d?.action { #expect(ref == "e3") } else { Issue.record("click+ref should become axPress") }
    let d2 = LLMDecisionCodec.parse("""
        {"action":{"type":"click","x":50,"y":60},"confidence":0.9,"rationale":"x"}
        """)
    if case .click(let x, let y)?? = d2?.action { #expect(x == 50 && y == 60) } else { Issue.record("expected click") }
}

@Test func llmCodecGarbageAbstains() {
    #expect(LLMDecisionCodec.parse("no json at all") == nil)
}

// MARK: - S2 escalation end-to-end

private struct StubReasoner: Reasoner {
    let name = "stub"
    func decide(observation: Observation, goal: String, history: [StepRecord], reason: String) async throws -> Decision {
        Decision(action: .done(summary: "s2 decided"), confidence: 0.9, rationale: "stub: \(reason)")
    }
}

@Test func lowConfidenceHandsOffToS2AndLogsReason() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s1test-\(UUID().uuidString)")
    let logger = try RunLogger(goal: "test", root: dir, config: [:])
    var cfg = LoopConfig(); cfg.confidenceThreshold = 0.6
    let loop = AgentLoop(config: cfg, perceiver: NullPerceiver(),
                         actuator: DryRunActuator(), gate: SafetyGate(), s2: StubReasoner())
    let report = try await loop.run(goal: "g", policy: DummyPolicy(confidence: 0.1), logger: logger)
    #expect(report.status == .done)
    #expect(report.escalations == 1)
    let text = try String(contentsOf: logger.runDir.appendingPathComponent("steps.jsonl"), encoding: .utf8)
    #expect(text.contains("s2:stub"))          // escalation logged with target
    #expect(text.contains("decidedBy\":\"s2:stub"))
}

@Test func appResolverSimilarityHandlesDictationMangles() {
    // "teks edit" is what Dictation returns for TextEdit
    #expect(AppResolver.similarity("teks edit", "TextEdit") >= 0.5)
    #expect(AppResolver.similarity("teks edit", "Photo Booth") < 0.5)
    #expect(AppResolver.similarity("sistem seting", "System Settings") >= 0.5)
}

@Test func llmCodecSalvagesTruncatedReply() {
    // Real llama3.2:3b output: truncated mid-rationale
    let d = LLMDecisionCodec.parse(#"{"action":{"type":"openApp","app":"TextEdit","x":0,"ref":"e0","keys":"cmd+t","ms":1000,"confidence":0.9,"rationale:"#)
    #expect(d != nil)
    #expect(d?.confidence == 0.9)
    if case .openApp(let n)? = d?.action { #expect(n == "TextEdit") } else { Issue.record() }
    let t = LLMDecisionCodec.parse(#"{"action":{"type":"typeText","text":"hello world","confidence":0.8}}"#)
    if case .typeText(let s)? = t?.action { #expect(s == "hello world") } else { Issue.record() }
}

@Test func identicalActionThreeTimesAbortsWithStuckLoop() async throws {
    // A policy that keeps deciding the same action must not spin forever.
    struct LoopingPolicy: Policy {
        let name = "looping"
        func decide(observation: Observation, goal: String, history: [StepRecord]) async throws -> Decision {
            Decision(action: .wait(seconds: 0), confidence: 0.9, rationale: "repeat")
        }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s1test-\(UUID().uuidString)")
    let logger = try RunLogger(goal: "stuck", root: dir, config: [:])
    var cfg = LoopConfig(); cfg.maxSteps = 10
    let loop = AgentLoop(config: cfg, perceiver: NullPerceiver(), actuator: DryRunActuator(), gate: SafetyGate())
    let rep = try await loop.run(goal: "stuck", policy: LoopingPolicy(), logger: logger)
    #expect(rep.status == .stuckLoop)
    #expect(rep.steps == 3)
}

// MARK: - hotkey

@Test func chordMatcherRequiresExactFlags() {
    let chord = Hotkey.defaultChord
    // ⌃⌥Space
    #expect(ChordMatcher.matches(keyCode: 49, flags: [.control, .option], pattern: chord))
    // Spotlight (⌘Space) must NOT trigger
    #expect(!ChordMatcher.matches(keyCode: 49, flags: [.command], pattern: chord))
    // extra modifier must NOT trigger
    #expect(!ChordMatcher.matches(keyCode: 49, flags: [.control, .option, .shift], pattern: chord))
    // wrong key must NOT trigger
    #expect(!ChordMatcher.matches(keyCode: 48, flags: [.control, .option], pattern: chord))
}

@Test func modifierTapTrackerDetectsDoubleTap() {
    var t = ModifierTapTracker(keyCodes: [56, 60], within: 0.35)
    var fired = t.feed(keyCode: 56, isDown: true, at: 0.0)   // first press
    #expect(!fired)
    fired = t.feed(keyCode: 56, isDown: false, at: 0.1)      // release
    #expect(!fired)
    fired = t.feed(keyCode: 56, isDown: true, at: 0.3)       // second press in window
    #expect(fired)
    var slow = ModifierTapTracker(keyCodes: [56, 60], within: 0.35)
    fired = slow.feed(keyCode: 56, isDown: true, at: 0.0)
    fired = slow.feed(keyCode: 56, isDown: false, at: 0.1)
    fired = slow.feed(keyCode: 56, isDown: true, at: 0.9)    // too slow
    #expect(!fired)
    var other = ModifierTapTracker(keyCodes: [56, 60], within: 0.35)
    fired = other.feed(keyCode: 55, isDown: true, at: 0.0)   // cmd isn't a target
    #expect(!fired)
}

// MARK: - serve

/// Lock-protected box so tests can capture values inside @Sendable closures.
private final class Locked<T>: @unchecked Sendable {
    private var v: T
    private let lock = NSLock()
    init(_ v: T) { self.v = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return v }
    func mutate(_ f: (inout T) -> Void) { lock.lock(); defer { lock.unlock() }; f(&v) }
}

@Test func serveStopPhraseDetection() {
    let phrases = ["stop", "berhenti", "matikan"]
    #expect(Serve.isStop("stop", phrases: phrases))
    #expect(Serve.isStop("Berhenti.", phrases: phrases))
    #expect(Serve.isStop("stop dong", phrases: phrases))
    #expect(Serve.isStop("matikan sekarang", phrases: phrases))
    #expect(!Serve.isStop("buka stopwatch", phrases: phrases))
    #expect(!Serve.isStop("stopwatch launch", phrases: phrases))
    #expect(!Serve.isStop("", phrases: phrases))
}

@Test func serveRunUsesConfiguredPolicy() async throws {
    // Prove an utterance becomes a goal and reaches the agent loop:
    // feed one command, then a stop phrase — both via injected transcribe.
    let feed = Locked<[String]>(["buka test, done", "stop"])
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("s1test-\(UUID().uuidString)")
    let events = Locked<[ServeEvent.Kind]>([])
    let serve = Serve(
        config: .init(
            makePolicy: { AXPolicy() },
            speak: false,
            artifacts: dir.path,
            killSwitch: dir.appendingPathComponent("ks").path,
            transcribe: {
                var out = "stop"
                feed.mutate { f in out = f.isEmpty ? "stop" : f.removeFirst() }
                return out
            }),
        locale: Locale(identifier: "en-US"),
        hotkeyPatterns: nil
    ) { ev in events.mutate { $0.append(ev.kind) } }
    serve.wake()
    for _ in 0 ..< 200 where serve.state != .idle {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(serve.state == .idle)
    let kinds = events.get()
    #expect(kinds.contains(.heard))
    #expect(kinds.contains(.runStart))
    #expect(kinds.contains(.stopped))
    // A run dir proves the agent loop really ran for the utterance.
    let runs = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    #expect(runs.contains { $0.contains("buka-test-done") })
}

@Test func serveAutoSleepsAfterSilentTurns() async throws {
    let events = Locked<[ServeEvent.Kind]>([])
    let serve = Serve(
        config: .init(
            speak: false,
            maxSilentTurns: 2,
            artifacts: FileManager.default.temporaryDirectory.path,
            killSwitch: FileManager.default.temporaryDirectory.appendingPathComponent("s1test-ks2").path,
            transcribe: { "" }),
        locale: Locale(identifier: "en-US"),
        hotkeyPatterns: nil
    ) { ev in events.mutate { $0.append(ev.kind) } }
    serve.wake()
    for _ in 0 ..< 100 where serve.state != .idle {
        try await Task.sleep(nanoseconds: 30_000_000)
    }
    #expect(serve.state == .idle)
    #expect(events.get().contains(.sleeping))
}

@Test func serveSttErrorsAutoSleep() async throws {
    struct Boom: Error {}
    let calls = Locked(0)
    let serve = Serve(
        config: .init(
            speak: false,
            maxListenErrors: 2,
            artifacts: FileManager.default.temporaryDirectory.path,
            killSwitch: FileManager.default.temporaryDirectory.appendingPathComponent("s1test-ks3").path,
            transcribe: { calls.mutate { $0 += 1 }; throw Boom() }),
        locale: Locale(identifier: "en-US"),
        hotkeyPatterns: nil
    ) { _ in }
    serve.wake()
    for _ in 0 ..< 100 where serve.state != .idle {
        try await Task.sleep(nanoseconds: 30_000_000)
    }
    #expect(serve.state == .idle)
    #expect(calls.get() >= 2)
}

// MARK: - all-app perception

@Test func appStatesJoinsWorkspaceAndWindowTitles() {
    let apps: [(name: String, pid: Int32)] = [("TextEdit", 10), ("Safari", 20), ("Finder", 30)]
    let wins = [
        WindowInfo(pid: 20, owner: "Safari", title: "Apple", bounds: CGRectCodable(.zero)),
        WindowInfo(pid: 20, owner: "Safari", title: "GitHub", bounds: CGRectCodable(.zero)),
        WindowInfo(pid: 30, owner: "Finder", title: nil, bounds: CGRectCodable(.zero)),
        WindowInfo(pid: 10, owner: "TextEdit", title: "notes.txt", bounds: CGRectCodable(.zero)),
    ]
    let states = SystemPerceiver.joinAppStates(apps: apps, windows: wins,
                                             frontmostPID: 10, maxApps: 20, maxTitlesPerApp: 4)
    #expect(states.count == 3)
    #expect(states[0].name == "TextEdit" && states[0].isActive)
    #expect(states[0].windowTitles == ["notes.txt"])
    let safari = states.first { $0.name == "Safari" }
    #expect(safari?.windowTitles == ["Apple", "GitHub"])
    // untitled windows don't pollute titles
    #expect(states.first { $0.name == "Finder" }?.windowTitles.isEmpty == true)
    // maxApps caps
    let capped = SystemPerceiver.joinAppStates(apps: apps, windows: wins,
                                              frontmostPID: nil, maxApps: 2, maxTitlesPerApp: 4)
    #expect(capped.count == 2)
}
