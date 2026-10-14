import Testing
import Foundation
@testable import S1Core

// Skills keep the run's own actions: saying the name replays them; a screen
// that isn't the recorded one falls back to planning the skill's steps.

private func tmp(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("s1-skill-\(tag)-\(UUID().uuidString)")
}

private func rec(_ a: Action?, gate: String = "allow", outcome: String? = "did", by: String = "s1:ax",
                 target: StepRecord.Target? = nil) -> StepRecord {
    var r = StepRecord(index: 0, time: Date(), observation: "x", decidedBy: by, confidence: 1, rationale: nil,
                       modelReply: nil, action: a, gate: gate, outcome: outcome, verified: nil, escalation: nil)
    r.target = target
    return r
}

@Test func recordingKeepsOnlyWhatRan() {
    let send = StepRecord.Target(role: "AXButton", label: "Send", frame: nil)
    let recs = [
        rec(.openApp(name: "Mail")),
        rec(.axPress(ref: "e4"), target: send),
        rec(.menuItem(path: ["File", "Move to Trash"]), gate: "allow(you approved: can't be undone)"),
        rec(.typeText("oops"), outcome: "error: didn't land"),
        rec(.keyCombo(keys: ["cmd", "q"]), gate: "needsHuman(⌘Q)", outcome: "blocked: ⌘Q"),
        rec(.verify(expectation: "sent")),
        rec(.done(summary: "ok")),
        rec(.click(x: 1, y: 2), outcome: "[dry-run] click"),
        rec(nil, by: "system"),
    ]
    let r = Skill.recording(from: recs)
    #expect(r?.map(\.action) == [.openApp(name: "Mail"), .axPress(ref: "e4"), .menuItem(path: ["File", "Move to Trash"])])
    #expect(r?[1].target == send)
    #expect(Skill.recording(from: [rec(.done(summary: "ok"))]) == nil)
    // A skill file never holds a password.
    #expect(Skill.recording(from: [rec(.typeText("my password is hunter2"))]) == nil)
}

@Test func skillsWithAndWithoutRecordingsRoundTrip() throws {
    let d = tmp("files")
    let s = Skill(name: "Weekly Report", steps: ["open Mail"],
                  recording: [.init(action: .openApp(name: "Mail"))])
    try Skills.save(s, to: d)
    let old = #"{"name":"pagi","steps":["open Notes"],"triggers":[]}"#
    try old.write(to: d.appendingPathComponent("pagi.json"), atomically: true, encoding: .utf8)
    let all = Skills.load(from: d)
    #expect(all.first { $0.name == "Weekly Report" }?.recording?.count == 1)
    #expect(all.first { $0.name == "pagi" }?.recording == nil)
    let perms = try FileManager.default.attributesOfItem(atPath: Skills.file(for: "Weekly Report", in: d).path)[.posixPermissions] as? Int
    #expect(perms == 0o600)
    #expect(try Skills.delete("weekly report", in: d) == "Weekly Report")
    #expect(try Skills.delete("nope", in: d) == nil)
    #expect(Skills.load(from: d).map(\.name) == ["pagi"])
}

@Test func skillPhrases() {
    #expect(MetaCommand.parse("save that as a command called weekly report") == .saveSkill("weekly report"))
    #expect(MetaCommand.parse("simpan itu sebagai perintah laporan") == .saveSkill("laporan"))
    #expect(MetaCommand.parse("list my skills") == .listSkills)
    #expect(MetaCommand.parse("daftar skill") == .listSkills)
    #expect(MetaCommand.parse("what skills do I have?") == .listSkills)
    #expect(MetaCommand.parse("delete the skill weekly report") == .deleteSkill("weekly report"))
    #expect(MetaCommand.parse("hapus skill pagi") == .deleteSkill("pagi"))
    // "save it as PDF" is the app's Save As, not a skill.
    #expect(MetaCommand.parse("save it as pdf") == nil)
}

@Test func savingASkillKeepsTheRunsActions() throws {
    let run = tmp("run")
    try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
    let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
    let lines = try [rec(.openApp(name: "Notes")), rec(.typeText("hello")), rec(.done(summary: "ok"))]
        .map { String(decoding: try enc.encode($0), as: UTF8.self) }.joined(separator: "\n")
    try lines.write(to: run.appendingPathComponent("steps.jsonl"), atomically: true, encoding: .utf8)
    let convo = Conversation()
    convo.record(goal: "open notes and type hello", outcome: "done", runDir: run.path)
    let name = "notes hello \(UUID().uuidString.prefix(6))"
    let reply = MetaCommand.saveSkill(name).perform(conversation: convo)
    defer { _ = try? Skills.delete(name) }
    #expect(reply.contains("2 recorded actions"))
    #expect(Skills.match(name, in: Skills.load())?.recording?.map(\.action) == [.openApp(name: "Notes"), .typeText("hello")])
}

@Test func sayingARecordedSkillReplaysIt() async throws {
    let name = "replay me \(UUID().uuidString.prefix(6))"
    try Skills.save(Skill(name: name, steps: ["open Notes"],
                          recording: [.init(action: .openApp(name: "Notes")), .init(action: .wait(seconds: 0.01))]))
    defer { _ = try? Skills.delete(name) }
    // The policy would only abstain: a replay never asks it.
    let (report, logger) = try await S1Runner.run(goal: name, policy: ScriptedPolicy(steps: []),
                                                  artifacts: tmp("art").path, maxSteps: 5, threshold: 0.6,
                                                  dryRun: true, allowIrreversible: false, killSwitch: nil)
    #expect(report.status == .done)
    let recs = try RunReader.steps(in: logger.runDir)
    #expect(recs.map(\.decidedBy).allSatisfy { $0 == "replay" })
    #expect(recs.first?.action == .openApp(name: "Notes"))
}

@Test func aScreenThatChangedFallsBackToPlanning() async throws {
    let name = "fallback \(UUID().uuidString.prefix(6))"
    let gone = StepRecord.Target(role: "AXButton", label: "A button no app has \(UUID().uuidString)", frame: nil)
    try Skills.save(Skill(name: name, steps: ["open Notes"],
                          recording: [.init(action: .axPress(ref: "e3"), target: gone)]))
    defer { _ = try? Skills.delete(name) }
    let plan = ScriptedPolicy(steps: [.init(action: .done(summary: "planned"), confidence: 1)])
    let (report, logger) = try await S1Runner.run(goal: name, policy: plan, artifacts: tmp("art2").path,
                                                  maxSteps: 5, threshold: 0.6, dryRun: true,
                                                  allowIrreversible: false, killSwitch: nil)
    #expect(report.status == .done)
    let recs = try RunReader.steps(in: logger.runDir)
    #expect(recs.first?.decidedBy == "replay")       // tried the recording first
    #expect(recs.contains { $0.decidedBy.hasPrefix("s1:") })   // then planned
}
