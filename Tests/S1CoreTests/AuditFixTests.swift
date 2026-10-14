import Testing
import Foundation
import AppKit
import ApplicationServices
@testable import S1Core

// Regression tests for the full-repo audit fixes, grouped by area.

private func tempDir(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("s1-\(tag)-\(UUID().uuidString)")
}

private func node(_ ref: String, _ role: String, _ title: String? = nil,
                  frame: CGRect? = nil, children: [AXNode] = []) -> AXNode {
    AXNode(ref: ref, role: role, title: title, desc: nil, value: nil,
           frame: frame.map(CGRectCodable.init), children: children)
}

// MARK: - secure fields are a subrole

@Test func passwordSubroleCountsAsSecure() {
    #expect(AXReader.secureRole("AXTextField", subrole: "AXSecureTextField") == "AXSecureTextField")
    #expect(AXReader.secureRole("AXTextField", subrole: nil) == "AXTextField")
    #expect(AXReader.secureRole("AXTextField", subrole: "AXSearchField") == "AXTextField")
}

@Test func menuCommandIntoPasswordBoxNeedsUser() async throws {
    var obs = Snapshot(timestamp: Date(), frontmostApp: "App", frontmostPID: 1,
                       windows: [], axTree: nil, screenshotPath: nil)
    obs.secureTextFocused = true
    let logger = try RunLogger(goal: "t", root: tempDir("menu-secure"), config: [:])
    let loop = AgentLoop(config: LoopConfig(), perceiver: NullPerceiver(observation: obs),
                         actuator: DryRunActuator(), gate: SafetyGate())
    let plan = ScriptedPolicy(steps: [.init(action: .menuItem(path: ["Edit", "Paste"]), confidence: 1)])
    let report = try await loop.run(goal: "paste", policy: plan, logger: logger)
    #expect(report.status == .needsHuman)
}

// MARK: - gate

@Test func terminalNamesMatchCaseBlind() {
    #expect(SafetyGate.isTerminal("Ghostty"))
    #expect(SafetyGate.isTerminal("Alacritty"))
    #expect(SafetyGate.isTerminal("Terminal"))
    #expect(!SafetyGate.isTerminal("TextEdit"))
    #expect(!SafetyGate.isTerminal(nil))
}

@Test func ghosttyTypingGetsCommandScan() async throws {
    let obs = Snapshot(timestamp: Date(), frontmostApp: "Ghostty", frontmostPID: 1,
                       windows: [], axTree: nil, screenshotPath: nil)
    let logger = try RunLogger(goal: "t", root: tempDir("ghostty"), config: [:])
    let loop = AgentLoop(config: LoopConfig(), perceiver: NullPerceiver(observation: obs),
                         actuator: DryRunActuator(), gate: SafetyGate())
    // Only the terminal list catches a flagless `rm`; the generic deny list doesn't.
    let plan = ScriptedPolicy(steps: [.init(action: .typeText("rm notes.txt"), confidence: 1)])
    let report = try await loop.run(goal: "x", policy: plan, logger: logger)
    #expect(report.status == .needsHuman)
}

@Test func deleteShortcutsAndLockNeedUser() {
    let g = SafetyGate()
    for keys in [["cmd", "delete"], ["cmd", "backspace"], ["cmd", "opt", "shift", "delete"], [" cmd ", "delete"]] {
        if case .needsHuman = g.evaluate(.keyCombo(keys: keys)) {} else { Issue.record("\(keys) should need the user") }
    }
    #expect(g.evaluate(.keyCombo(keys: ["delete"])) == .allow)
    guard case .needsHuman(let why) = g.evaluate(.keyCombo(keys: ["ctrl", "cmd", "q"])) else {
        Issue.record("⌃⌘Q should need the user"); return
    }
    #expect(why.contains("locks the screen"))
}

@Test func localizedDestructiveMenusNeedUser() {
    let g = SafetyGate()
    for path in [["File", "Pindahkan ke Tong Sampah"], ["Edit", "Hapus"], ["File", "Move to Bin"],
                 ["Finder", "Kosongkan Tong Sampah"]] {
        if case .needsHuman = g.evaluate(.menuItem(path: path)) {} else { Issue.record("\(path) should need the user") }
    }
    #expect(g.evaluate(.menuItem(path: ["File", "New Window"])) == .allow)
}

// MARK: - keys

@Test func mediaKeyEventCarriesKeyAndState() {
    #expect(CGEventActuator.mediaKeyData(0, down: true) == 0x0000_0a00)
    #expect(CGEventActuator.mediaKeyData(16, down: false) == (16 << 16) | 0xb00)
}

@Test func comboKeysAreTrimmed() {
    #expect(CGEventActuator.comboKeys("cmd + s") == ["cmd", "s"])
    #expect(CGEventActuator.comboKeys("Cmd+Shift+T") == ["cmd", "shift", "t"])
    #expect(CGEventActuator.comboKeys("cmd+,") == ["cmd", ","])
    #expect(CGEventActuator.keyCode(for: "comma") == 43)
    #expect(CGEventActuator.keyCode(for: "Return") == 36)
}

@Test func llmKeyComboStringIsSplitCleanly() throws {
    let json = #"{"action":{"type":"keyCombo","keys":"cmd + shift + t"},"confidence":0.9}"#
    let d = try #require(LLMDecisionCodec.parse(json))
    #expect(d.action == .keyCombo(keys: ["cmd", "shift", "t"]))
}

// MARK: - untrusted numbers never trap

@Test func cuaScrollSurvivesHugeAndNonFiniteDeltas() {
    #expect(CuaDriver.scrollCall(dx: 0, dy: .nan, pid: 1) == nil)
    #expect(CuaDriver.scrollCall(dx: .infinity, dy: 0, pid: 1) == nil)
    #expect(CuaDriver.scrollCall(dx: 0, dy: 1e300, pid: 1)?.args.contains(#""amount":10"#) == true)
    #expect(CuaDriver.json(["x": Double.nan]) == nil)
    #expect(CuaDriver.json(["x": 1.0]) == #"{"x":1}"#)
}

@Test func dragWithHugeCoordinatesDoesNotTrap() async throws {
    // Dry-run never posts; the outcome string must still format.
    let a = Action.drag(fromX: 1e300, fromY: 0, toX: 0, toY: 0)
    let out = try await DryRunActuator().perform(a, frontmostPID: nil)
    #expect(out.contains("drag"))
}

// MARK: - shell working directory

@Test func shellWorkingDirectoryNeverTheRoot() {
    #expect(Sandbox.workingDirectory(sandboxed: true, cwd: "/", home: "/Users/x")
            == "/Users/x/Library/Caches/s1/shell")
    #expect(Sandbox.workingDirectory(sandboxed: false, cwd: "/", home: "/Users/x") == "/Users/x")
    #expect(Sandbox.workingDirectory(sandboxed: true, cwd: "/Users/x/proj", home: "/Users/x") == "/Users/x/proj")
}

// MARK: - openURL / app names

@Test func openURLRefusesBundlesHoweverSpelled() throws {
    #expect(CGEventActuator.opensSafely(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension")!))
    #expect(CGEventActuator.opensSafely(URL(fileURLWithPath: NSTemporaryDirectory())))
    #expect(!CGEventActuator.opensSafely(URL(fileURLWithPath: "/System/Applications/Calculator.APP")))
    #expect(!CGEventActuator.opensSafely(URL(string: "https://example.com")!))
    let dir = tempDir("link")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let link = dir.appendingPathComponent("innocent")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
    #expect(!CGEventActuator.opensSafely(link))
}

@Test func appNamesCantBePaths() {
    // Resolves to a real app through the old path join — must be refused.
    #expect(AppResolver.resolve("../../System/Applications/Calculator") == nil)
    #expect(AppResolver.resolve("../../tmp/x") == nil)
    #expect(AppResolver.resolve("..") == nil)
}

// MARK: - refs re-found by identity

@Test func targetResolvesNearestOfDuplicateLabels() {
    let before = node("e0", "AXWindow", children: [
        node("e1", "AXButton", "Reply", frame: CGRect(x: 0, y: 100, width: 40, height: 20)),
        node("e2", "AXButton", "Reply", frame: CGRect(x: 0, y: 200, width: 40, height: 20)),
    ])
    let t = try! #require(StepRecord.Target.of("e2", in: before))
    // A row inserted above shifts everything down by 30 pt and adds a node.
    let after = node("e0", "AXWindow", children: [
        node("e1", "AXButton", "Reply", frame: CGRect(x: 0, y: 70, width: 40, height: 20)),
        node("e2", "AXButton", "Reply", frame: CGRect(x: 0, y: 130, width: 40, height: 20)),
        node("e3", "AXButton", "Reply", frame: CGRect(x: 0, y: 230, width: 40, height: 20)),
    ])
    #expect(t.resolve(in: after) == "e3")
    // Unlabeled: only the same role close to where it was.
    let field = try! #require(StepRecord.Target.of("e1", in: node("e0", "AXWindow", children: [
        node("e1", "AXTextField", frame: CGRect(x: 10, y: 10, width: 100, height: 20))])))
    #expect(field.resolve(in: node("e0", "AXWindow", children: [
        node("e1", "AXTextField", frame: CGRect(x: 10, y: 300, width: 100, height: 20))])) == nil)
    #expect(field.resolve(in: node("e0", "AXWindow", children: [
        node("e5", "AXTextField", frame: CGRect(x: 12, y: 14, width: 100, height: 20))])) == "e5")
}

@Test func loopRecordsTheTargetOfAnAXAction() async throws {
    let tree = node("e0", "AXWindow", children: [node("e1", "AXButton", "Send", frame: CGRect(x: 1, y: 2, width: 3, height: 4))])
    let obs = Snapshot(timestamp: Date(), frontmostApp: "App", frontmostPID: 1,
                       windows: [], axTree: tree, screenshotPath: nil)
    let logger = try RunLogger(goal: "t", root: tempDir("target"), config: [:])
    let loop = AgentLoop(config: LoopConfig(), perceiver: NullPerceiver(observation: obs),
                         actuator: DryRunActuator(), gate: SafetyGate())
    let plan = ScriptedPolicy(steps: [.init(action: .axPress(ref: "e1"), confidence: 1),
                                      .init(action: .done(summary: "ok"), confidence: 1)])
    _ = try await loop.run(goal: "press send", policy: plan, logger: logger)
    let recs = try RunReader.steps(in: logger.runDir)
    #expect(recs.first?.target?.label == "Send")
    #expect(recs.first?.target?.role == "AXButton")
}

// MARK: - replay

private struct SpyActuator2: Actuator {
    let name = "spy"
    let actions = Locked<[Action]>([])
    func perform(_ action: Action, frontmostPID: pid_t?) async throws -> String {
        actions.withLock { $0.append(action) }
        return "did"
    }
}

private func recording(_ recs: [StepRecord]) throws -> URL {
    let src = tempDir("replay-src")
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let lines = try recs.map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n")
    try lines.write(to: src.appendingPathComponent("steps.jsonl"), atomically: true, encoding: .utf8)
    return src
}

private func step(_ a: Action, target: StepRecord.Target? = nil) -> StepRecord {
    var r = StepRecord(index: 0, time: Date(), observation: "x", decidedBy: "s1:ax", confidence: 1,
                       rationale: "", modelReply: nil, action: a, gate: "allow", outcome: "ok",
                       verified: nil, escalation: nil)
    r.target = target
    return r
}

@Test func replayStopsAtAStepThatNeedsTheUser() async throws {
    // Typing into a password box is blocked; the Return after it must not run.
    var obs = Snapshot(timestamp: Date(), frontmostApp: "App", frontmostPID: 1,
                       windows: [], axTree: nil, screenshotPath: nil)
    obs.secureTextFocused = true
    let src = try recording([step(.typeText("hunter2")), step(.keyCombo(keys: ["return"]))])
    let logger = try RunLogger(goal: "replay", root: tempDir("replay-dst"), config: [:])
    let spy = SpyActuator2()
    _ = try await RunReader.replay(runDir: src, into: logger, actuator: spy, gate: SafetyGate(),
                                   perceiver: NullPerceiver(observation: obs))
    #expect(spy.actions.value.isEmpty)
    #expect(try RunReader.steps(in: logger.runDir).count == 1)
}

@Test func replayRefindsRecordedElementsOrAsks() async throws {
    let live = node("e0", "AXWindow", children: [
        node("e1", "AXButton", "Delete"),
        node("e2", "AXButton", "Send", frame: CGRect(x: 0, y: 0, width: 10, height: 10)),
    ])
    let obs = Snapshot(timestamp: Date(), frontmostApp: "App", frontmostPID: 1,
                       windows: [], axTree: live, screenshotPath: nil)
    let send = StepRecord.Target(role: "AXButton", label: "Send", frame: nil)
    let src = try recording([step(.axPress(ref: "e1"), target: send)])
    let logger = try RunLogger(goal: "replay", root: tempDir("replay-ref"), config: [:])
    let spy = SpyActuator2()
    _ = try await RunReader.replay(runDir: src, into: logger, actuator: spy, gate: SafetyGate(),
                                   perceiver: NullPerceiver(observation: obs))
    #expect(spy.actions.value == [.axPress(ref: "e2")])

    // A recording without identities can't say which element e1 was.
    let old = try recording([step(.axPress(ref: "e1"))])
    let spy2 = SpyActuator2()
    _ = try await RunReader.replay(runDir: old, into: try RunLogger(goal: "r", root: tempDir("replay-old"), config: [:]),
                                   actuator: spy2, gate: SafetyGate(), perceiver: NullPerceiver(observation: obs))
    #expect(spy2.actions.value.isEmpty)
}

// MARK: - focus

@Test func setValueFallbackDependsOnFocus() {
    #expect(FocusGuard.depth(.axSetValue(ref: "e1", value: "x")) == true)
}

// MARK: - Reasoner wire format

@Test func openAIReasoningModelsGetNoTemperature() {
    #expect(ChatClient.isReasoningModel("gpt-5-mini"))
    #expect(ChatClient.isReasoningModel("openai/gpt-5"))
    #expect(ChatClient.isReasoningModel("o3-mini"))
    #expect(!ChatClient.isReasoningModel("gpt-5-chat-latest"))
    #expect(!ChatClient.isReasoningModel("gpt-4o-mini"))
    #expect(!ChatClient.isReasoningModel("ollama-model"))
    let msgs = [ChatMessage(role: "user", content: "hi")]
    let r = ChatClient.requestBody(endpoint: Endpoint(baseURL: "https://api.openai.com/v1", model: "gpt-5-mini", apiKey: "k"),
                                   messages: msgs, maxTokens: 2048, temperature: 0)
    #expect(r["temperature"] == nil)
    #expect((r["max_completion_tokens"] as? Int ?? 0) >= 8192)
    let c = ChatClient.requestBody(endpoint: Endpoint(baseURL: "https://api.openai.com/v1", model: "gpt-4o", apiKey: "k"),
                                   messages: msgs, maxTokens: 2048, temperature: 0)
    #expect(c["temperature"] as? Double == 0)
    #expect(c["max_completion_tokens"] as? Int == 2048)
}

// MARK: - grammar

private func screen(_ app: String = "App", tree: AXNode? = nil, menus: [MenuCommand] = []) -> Snapshot {
    var s = Snapshot(timestamp: Date(), frontmostApp: app, frontmostPID: 1, windows: [], axTree: tree, screenshotPath: nil)
    s.menus = menus
    return s
}

private func decide(_ goal: String, _ obs: Snapshot = screen()) async throws -> Decision {
    try await AXPolicy().decide(observation: obs, goal: goal, history: [])
}

@Test func macSkillsOnlyForVerbsThatAskForThem() async throws {
    if case .typeText? = try await decide("type check your wifi settings").action {} else { Issue.record("should type") }
    let close = try await decide("close bluetooth settings").action
    if case .openURL? = close { Issue.record("closing must not open the pane") }
    #expect(try await decide("mission control").action == .keyCombo(keys: ["ctrl", "up"]))
    #expect(try await decide("brightness up").action == .keyCombo(keys: ["brightnessup"]))
    if case .dismissNotification? = try await decide("close my notifications").action {} else {
        Issue.record("close my notifications is a skill")
    }
}

@Test func waitUnderstandsDictatedUnits() {
    #expect(AXPolicy.parseWaitSeconds("500 ms.") == 0.5)
    #expect(AXPolicy.parseWaitSeconds("500ms.") == 0.5)
    #expect(AXPolicy.parseWaitSeconds("3 menit.") == 180)
    #expect(AXPolicy.parseWaitSeconds("2 min") == 120)
    #expect(AXPolicy.parseWaitSeconds("for 2 seconds") == 2)
    #expect(AXPolicy.parseWaitSeconds("2 secs") == 2)
}

@Test func politeTailIsTextAfterATypeVerb() {
    #expect(AXPolicy.stripFillers("type thank you") == "type thank you")
    #expect(AXPolicy.stripFillers("balas ya") == "balas ya")
    #expect(AXPolicy.stripFillers("buka notes ya") == "buka notes")
}

@Test func pressKeyNameIsTheKeyNotTheMenu() async throws {
    let obs = screen(menus: [MenuCommand(path: ["Edit", "Delete"])])
    #expect(try await decide("press delete", obs).action == .keyCombo(keys: ["delete"]))
}

@Test func lastTabAndAmbiguousTitles() async throws {
    let tabs = node("e0", "AXWindow", children: [node("e1", "AXTabGroup", children: [
        node("e2", "AXRadioButton", "Gmail – Inbox"),
        node("e3", "AXRadioButton", "Gmail – Compose"),
        node("e4", "AXRadioButton", "Notes"),
    ])])
    let obs = screen("Finder", tree: tabs)
    #expect(try await decide("go to the last tab", obs).action == .axPress(ref: "e4"))
    let g = try await decide("go to the gmail tab", obs)
    #expect(g.confidence < 0.9)
    #expect(g.options?.count == 2)
}

@Test func scrollDirectionIsWholeWords() async throws {
    guard case .scroll(_, let dy)? = try await decide("scroll down to supplies").action else {
        Issue.record("expected scroll"); return
    }
    #expect(dy > 0)
    let deals = try await decide("scroll down to the laptop deals").action
    #expect(deals != .keyCombo(keys: ["cmd", "up"]))
}

@Test func closeThisWindowClosesIt() async throws {
    #expect(try await decide("close this window").action == .keyCombo(keys: ["cmd", "w"]))
}

@Test func clickPicksAClickableCandidateAndAsksAboutALoneGuess() async throws {
    let tree = node("e0", "AXWindow", children: [
        node("e1", "AXStaticText", "Save draft"),                       // best match, no frame
        node("e2", "AXStaticText", "Save draft copy", frame: CGRect(x: 0, y: 0, width: 50, height: 10)),
    ])
    let d = try await decide("click save draft", screen(tree: tree))
    #expect(d.action == .click(x: 25, y: 5))
    #expect(d.options?.count == 1)
}

// MARK: - Reasoner replies

@Test func setValueTakesNumbersAndNeverInventsEmpty() throws {
    let n = try #require(LLMDecisionCodec.parse(#"{"action":{"type":"axSetValue","ref":"e12","value":5},"confidence":0.9}"#))
    #expect(n.action == .axSetValue(ref: "e12", value: "5"))
    let missing = LLMDecisionCodec.parse(#"{"action":{"type":"axSetValue","ref":"e12"},"confidence":0.9}"#)
    #expect(missing?.action == nil)
}

// MARK: - Judge privacy

@Test func fieldContentsStayOutOfJudgeLabels() {
    let area = AXNode(ref: "e3", role: "AXTextArea", title: nil, desc: nil, value: "Dear Bob, my PIN is 1234",
                      frame: nil, children: [])
    #expect(!AXPolicy.label(area).contains("PIN"))
    let text = AXNode(ref: "e4", role: "AXStaticText", title: nil, desc: nil, value: "Inbox", frame: nil, children: [])
    #expect(AXPolicy.label(text).contains("Inbox"))
}

// MARK: - memory

@Test func recallDoesntHijackRequests() {
    #expect(Memory.recall("remind me to call my wife at 5", facts: ["my wife is Sarah"]) == nil)
    #expect(Memory.recall("what's my IP address", facts: ["my address is Jl. Sudirman 1"]) == nil)
    #expect(Memory.recall("what's my editor", facts: ["my editor is Zed"]) != nil)
    #expect(Memory.recall("remind me about the wifi password", facts: ["the wifi password is hunter2"]) != nil)
}

// MARK: - config

@Test func unreadableConfigIsNeverOverwritten() throws {
    let dir = tempDir("cfg")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent("config.json").path
    let broken = #"{"providers":[{"id":"groq"}],"vision":"off",}"#
    try broken.write(toFile: path, atomically: true, encoding: .utf8)
    #expect(throws: (any Error).self) { try S1Config.update(at: path) { $0.speak = true } }
    #expect(try String(contentsOfFile: path, encoding: .utf8) == broken)
    // Blank counts as missing.
    try "  \n".write(toFile: path, atomically: true, encoding: .utf8)
    try S1Config.update(at: path) { $0.speak = true }
    #expect(S1Config.load(from: path).speak == true)
}

@Test func doctorKnowsEveryConfigKey() {
    #expect(Doctor.knownConfigKeys.contains("webSearch"))
}

@Test func groqCatalogHasOnlyRealOrpheusModels() {
    let ids = ProviderCatalog.template("groq")?.models.map(\.id) ?? []
    #expect(!ids.contains("canopylabs/orpheus-v1-indonesian"))
    #expect(CloudSpeech.ttsSpeaks(model: "canopylabs/orpheus-arabic-saudi", language: "ar-SA"))
    #expect(!CloudSpeech.ttsSpeaks(model: "canopylabs/orpheus-v1-english", language: "id-ID"))
}

// MARK: - launcher

@Test func conversionCopiesAPlainNumberInEveryLocale() {
    #expect(Convert.format(3.10686, locale: Locale(identifier: "id_ID")) == "3,1069")
    #expect(Convert.plain(3.10686) == "3.1069")
    #expect(Convert.plain(1_650_000.25) == "1650000.25")
}

@Test func isoDateIsLocal() {
    var cal = Calendar(identifier: .gregorian); cal.timeZone = .current
    let now = Date()
    let expected = String(format: "%04d-%02d-%02d", cal.component(.year, from: now),
                          cal.component(.month, from: now), cal.component(.day, from: now))
    #expect(Snippets.expand("{isodate}", now: now) == expected)
}

@Test func calcLeavesDatesAndPhonesAlone() {
    #expect(Calc.evaluate("2026-10-15") == nil)
    #expect(Calc.evaluate("0812-3456-7890") == nil)
    #expect(Calc.evaluate("10 - 5 - 2") == 3)
    #expect(Calc.evaluate("10-5") == 5)
}

// MARK: - voice

@Test func whisperPromptFitsItsWindow() {
    let many = (0..<400).map { "Word\($0)" }
    let p = CloudSpeech.prompt(vocabulary: many) ?? ""
    #expect(p.count <= 500)
    #expect(p.hasPrefix("Word0, Word1"))
}

@Test func endpointerTimesOutInANoisyRoomNobodySpeaksIn() {
    let e = Endpointer()
    for _ in 0 ..< 3 { e.feed(dB: -120, seconds: 0.085) }   // engine warm-up zeros
    for _ in 0 ..< 120 { e.feed(dB: -46, seconds: 0.085) }  // room noise only, ~10 s
    #expect(e.state == .timedOut)
}

// MARK: - companion stop file and run lock

/// Writes the stop file mid-decision, the way `s1 stop` lands mid-run.
private struct StopsMidRun: Policy {
    let name = "stops"
    let kill: String
    func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        try? "stop".write(toFile: kill, atomically: true, encoding: .utf8)
        return Decision(action: .wait(seconds: 0.1), confidence: 1, rationale: "x")
    }
}

extension ServeTests {
@Test func listenerSleepingWithoutARunLeavesTheStopFileAlone() async throws {
    let kill = tempDir("ks-quiet").path
    let serve = Serve(config: .init(speak: false, maxSilentTurns: 1, artifacts: NSTemporaryDirectory(),
                                    killSwitch: kill, transcribe: { _ in "" }),
                      locale: Locale(identifier: "en-US"), hotkeyPatterns: nil) { _ in }
    serve.wake()
    for _ in 0 ..< 100 where serve.state != .idle { try await Task.sleep(nanoseconds: 30_000_000) }
    #expect(serve.state == .idle)
    // A shared stop file must not be written: it would abort someone else's run.
    #expect(!FileManager.default.fileExists(atPath: kill))
}

@Test func companionDoesNotWakeWhileTheMicIsBusy() {
    let serve = Serve(config: .init(speak: false, transcribe: { _ in "" }, micBusy: { true }),
                      locale: Locale(identifier: "en-US"), hotkeyPatterns: nil) { _ in }
    serve.wake()
    #expect(serve.state == .idle)
}

@Test(.enabled(if: AXIsProcessTrusted())) func stoppedRunPutsTheListenerToSleep() async throws {
    let dir = tempDir("ks-run")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let kill = dir.appendingPathComponent("stop").path
    let turns = Locked(0)
    let events = Locked<[ServeEvent.Kind]>([])
    let serve = Serve(config: .init(makePolicy: { StopsMidRun(kill: kill) }, speak: false, artifacts: dir.path,
                                    killSwitch: kill,
                                    transcribe: { _ in turns.withLock { $0 += 1 }; return "do the thing" }),
                      locale: Locale(identifier: "en-US"), hotkeyPatterns: nil) { ev in events.withLock { $0.append(ev.kind) } }
    serve.wake()
    for _ in 0 ..< 200 where serve.state != .idle { try await Task.sleep(nanoseconds: 50_000_000) }
    #expect(serve.state == .idle)
    #expect(events.value.contains(.runDone))
    #expect(turns.value == 1)   // no second turn whose words the stop file would swallow
}

@Test func runLockIsNotReentrant() throws {
    try S1Runner.acquireRunLock()
    defer { S1Runner.releaseRunLock() }
    #expect(throws: (any Error).self) { try S1Runner.acquireRunLock() }
}
}

// MARK: - launch agent

@Test func launchAgentLogsAndRunsWhereTheInstallerLooks() throws {
    let xml = ServeLaunchd.plist(args: ["/bin/s1", "serve"], home: "/tmp/h & co", env: ["S1_HOME": "/tmp/h & co"])
    let obj = try PropertyListSerialization.propertyList(from: Data(xml.utf8), format: nil) as? [String: Any]
    #expect(obj?["StandardOutPath"] as? String == "/tmp/h & co/serve.log")
    #expect((obj?["EnvironmentVariables"] as? [String: String])?["S1_HOME"] == "/tmp/h & co")
    let plain = ServeLaunchd.plist(args: ["/bin/s1"], home: "/Users/x/.s1", env: [:])
    let o2 = try PropertyListSerialization.propertyList(from: Data(plain.utf8), format: nil) as? [String: Any]
    #expect(o2?["EnvironmentVariables"] == nil)
}

// MARK: - round 2 repairs

@Test func describingHugeCoordinatesNeverTraps() {
    #expect(LLMDecisionCodec.describe(.click(x: 1e20, y: .nan)) == "click(?,?)")
    #expect(LLMDecisionCodec.describe(.drag(fromX: 1, fromY: 2, toX: 3e30, toY: 4)) == "drag(1,2->?,4)")
    #expect(AgentLoop.unusable(.click(x: 1e20, y: 5), confidence: 0.9))
    #expect(AgentLoop.unusable(.scroll(dx: 0, dy: .infinity), confidence: 0.9))
    #expect(!AgentLoop.unusable(.click(x: 300, y: 200), confidence: 0.9))
}

@Test func politeTailStaysTextAfterAnyTypingCommand() {
    #expect(AXPolicy.stripFillers("open notes and type thank you").hasSuffix("thank you"))
    #expect(AXPolicy.stripFillers("buka notes, balas ya").hasSuffix("balas ya"))
    #expect(AXPolicy.stripFillers("type hello and open notes please") == "type hello and open notes")
    #expect(AXPolicy.stripFillers("type see you, thanks").hasSuffix("thanks"))
    #expect(AXPolicy.stripFillers("type I will check it please").hasSuffix("please"))
    #expect(AXPolicy.stripFillers("balas oke, makasih ya").hasSuffix("ya"))
}

@Test func dryRunIgnoresAStopFileFromBefore() async throws {
    let kill = tempDir("stale-stop").path
    try "stop".write(toFile: kill, atomically: true, encoding: .utf8)
    let plan = ScriptedPolicy(steps: [.init(action: .done(summary: "ok"), confidence: 1)])
    let (report, _) = try await S1Runner.run(goal: "g", policy: plan, artifacts: tempDir("dry").path,
                                             maxSteps: 3, threshold: 0.6, dryRun: true, allowIrreversible: false,
                                             killSwitch: kill, clearStaleStop: true)
    #expect(report.status == .done)
    // …and leaves it for the live run it may be meant for.
    #expect(FileManager.default.fileExists(atPath: kill))
}

@Test func replayKeepsTheTargetForTheNextReplay() async throws {
    let live = node("e0", "AXWindow", children: [node("e2", "AXButton", "Send")])
    let obs = Snapshot(timestamp: Date(), frontmostApp: "App", frontmostPID: 1,
                       windows: [], axTree: live, screenshotPath: nil)
    let src = try recording([step(.axPress(ref: "e9"), target: StepRecord.Target(role: "AXButton", label: "Send", frame: nil))])
    let logger = try RunLogger(goal: "replay", root: tempDir("replay-keep"), config: [:])
    _ = try await RunReader.replay(runDir: src, into: logger, actuator: SpyActuator2(), gate: SafetyGate(),
                                   perceiver: NullPerceiver(observation: obs))
    #expect(try RunReader.steps(in: logger.runDir).first?.target?.label == "Send")
}

extension ServeTests {
@Test func sleepWhileWordsAreHeardMeansNoRun() async throws {
    let box = Locked<Serve?>(nil)
    let events = Locked<[ServeEvent.Kind]>([])
    let serve = Serve(config: .init(speak: false, artifacts: NSTemporaryDirectory(), killSwitch: tempDir("ks-r4").path,
                                    transcribe: { _ in box.value?.sleep(); return "open notes" }),
                      locale: Locale(identifier: "en-US"), hotkeyPatterns: nil) { ev in events.withLock { $0.append(ev.kind) } }
    box.value = serve
    serve.wake()
    for _ in 0 ..< 100 where serve.state != .idle { try await Task.sleep(nanoseconds: 30_000_000) }
    try await Task.sleep(nanoseconds: 200_000_000)
    #expect(serve.state == .idle)
    #expect(!events.value.contains(.runStart))
}
}
