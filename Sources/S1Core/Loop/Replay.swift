import Foundation

/// P6: reload a run's evidence and either summarize it (metrics) or
/// re-execute its actions against the live screen (replay).
public enum RunReader {
    public static func steps(in runDir: URL) throws -> [StepRecord] {
        let url = runDir.appendingPathComponent("steps.jsonl")
        let text = try String(contentsOf: url, encoding: .utf8)
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            try? dec.decode(StepRecord.self, from: Data(line.utf8))
        }
    }

    public struct Metrics: Sendable {
        public var steps: Int = 0
        public var s1Decisions: Int = 0
        public var s2Decisions: Int = 0
        public var escalations: [(to: String, reason: String)] = []
        public var errors: Int = 0
        public var blocked: Int = 0
        public var verifiedOK: Int = 0
        public var verifiedFail: Int = 0
        public var screenshots: Int = 0
        public var durationSeconds: Double = 0
    }

    public static func metrics(in runDir: URL) throws -> Metrics {
        let recs = try steps(in: runDir)
        var m = Metrics(steps: recs.count)
        var screens = 0
        if let items = try? FileManager.default.contentsOfDirectory(
            atPath: runDir.appendingPathComponent("screens").path) {
            screens = items.filter { $0.hasSuffix(".png") }.count
        }
        m.screenshots = screens
        var first: Date?, last: Date?
        for r in recs {
            // System records (kill switch, stuck-loop guard) are neither S1
            // nor S2 decisions — counting them as S1 skews the split.
            if r.decidedBy.hasPrefix("s1") { m.s1Decisions += 1 }
            else if r.decidedBy.hasPrefix("s2") { m.s2Decisions += 1 }
            if let e = r.escalation { m.escalations.append((e.to, e.reason)) }
            if let o = r.outcome {
                if o.hasPrefix("error:") { m.errors += 1 }
                if o.hasPrefix("blocked:") { m.blocked += 1 }
            }
            if let v = r.verified { v ? (m.verifiedOK += 1) : (m.verifiedFail += 1) }
            if first == nil { first = r.time }
            last = r.time
        }
        if let f = first, let l = last { m.durationSeconds = l.timeIntervalSince(f) }
        return m
    }

    /// Re-execute the recorded actions through the real actuator + gate.
    /// Read-only steps are logged and skipped. Returns the new run dir.
    /// The kill switch and task cancellation are honored per step — a
    /// replayed run must be as interruptible as a live one.
    public static func replay(runDir: URL, into logger: RunLogger,
                              actuator: any Actuator, gate: SafetyGate,
                              killSwitchPath: String? = nil) async throws -> Int {
        let recs = try steps(in: runDir)
        var i = 0
        for rec in recs {
            if Task.isCancelled || (killSwitchPath.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
                try await logger.log(StepRecord(index: i, time: Date(),
                    observation: "replay", decidedBy: "system",
                    confidence: nil, rationale: Task.isCancelled ? "task cancelled" : "kill switch",
                    modelReply: nil, action: nil, gate: "-", outcome: "aborted",
                    verified: nil, escalation: nil))
                break
            }
            guard let action = rec.action else { continue }
            switch action {
            case .done, .verify, .captureScreenshot:
                try await logger.log(StepRecord(index: i, time: Date(),
                    observation: "replay (read-only)", decidedBy: "replay",
                    confidence: nil, rationale: rec.rationale, modelReply: nil, action: action,
                    gate: "allow", outcome: "skipped (read-only)",
                    verified: nil, escalation: nil))
            default:
                // AX refs are only meaningful inside a fresh tree — re-observe
                // so replayed presses land on the live pid instead of failing
                // on a nil one. The same observation feeds the secure-field
                // guards, replaying the loop's password-box protection.
                let needsObs: Bool = switch action {
                case .axPress, .axSetValue, .typeText: true
                default: false
                }
                let liveObs = needsObs
                    ? try? await SystemPerceiver().observe(wantScreenshot: false)
                    : nil
                var verdict = gate.evaluate(action)
                if case .typeText = action, liveObs?.secureTextFocused == true {
                    verdict = .needsHuman(reason: "focused field is a secure text field")
                }
                if case .axSetValue(let ref, _) = action,
                   S1SecureField.isSecure(ref, in: liveObs?.axTree) {
                    verdict = .needsHuman(reason: "target is a secure text field")
                }
                var outcome = "blocked"
                if case .allow = verdict {
                    do {
                        outcome = try await actuator.perform(action, frontmostPID: liveObs?.frontmostPID)
                    } catch {
                        outcome = "error: \(error.localizedDescription)"
                    }
                }
                try await logger.log(StepRecord(index: i, time: Date(),
                    observation: "replay", decidedBy: "replay",
                    confidence: nil, rationale: rec.rationale, modelReply: nil, action: action,
                    gate: verdict.label, outcome: outcome,
                    verified: nil, escalation: nil))
            }
            i += 1
        }
        return i
    }
}
