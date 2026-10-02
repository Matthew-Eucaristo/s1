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
            if r.decidedBy.hasPrefix("s2") { m.s2Decisions += 1 } else { m.s1Decisions += 1 }
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
    public static func replay(runDir: URL, into logger: RunLogger,
                              actuator: any Actuator, gate: SafetyGate) async throws -> Int {
        let recs = try steps(in: runDir)
        var i = 0
        for rec in recs {
            guard let action = rec.action else { continue }
            switch action {
            case .done, .verify, .captureScreenshot:
                try await logger.log(StepRecord(index: i, time: Date(),
                    observation: "replay (read-only)", decidedBy: "replay",
                    confidence: nil, rationale: rec.rationale, action: action,
                    gate: "allow", outcome: "skipped (read-only)",
                    verified: nil, escalation: nil))
            default:
                let verdict = gate.evaluate(action)
                var outcome = "blocked"
                if case .allow = verdict {
                    do {
                        outcome = try await actuator.perform(action, frontmostPID: nil)
                    } catch {
                        outcome = "error: \(error.localizedDescription)"
                    }
                }
                try await logger.log(StepRecord(index: i, time: Date(),
                    observation: "replay", decidedBy: "replay",
                    confidence: nil, rationale: rec.rationale, action: action,
                    gate: verdict.label, outcome: outcome,
                    verified: nil, escalation: nil))
            }
            i += 1
        }
        return i
    }
}
