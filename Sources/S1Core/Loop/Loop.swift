import Foundation

public struct LoopConfig: Sendable {
    public var maxSteps = 25
    public var confidenceThreshold = 0.6
    public var dryRun = false
    /// File that aborts the run if it appears — checked every step.
    public var killSwitchPath: String?

    public init() {}
}

public enum RunStatus: String, Sendable {
    case done, aborted, escalatedToS2, needsHuman, maxStepsReached, stuckLoop
}

public struct RunReport: Sendable {
    public var status: RunStatus
    public var steps: Int
    public var runDir: String
    public var escalations: Int
}

/// The see → decide → gate → act → verify → log cycle. S1 decides; below the
/// confidence threshold the step goes to S2 (or stops, logged, if S2 is absent).
public struct AgentLoop {
    public var config: LoopConfig
    public var perceiver: any Perceiver
    public var actuator: any Actuator
    public var gate: SafetyGate
    public var s2: (any Reasoner)?

    public init(config: LoopConfig, perceiver: any Perceiver, actuator: any Actuator,
                gate: SafetyGate, s2: (any Reasoner)? = nil) {
        self.config = config
        self.perceiver = perceiver
        self.actuator = actuator
        self.gate = gate
        self.s2 = s2
    }

    public func run(goal: String, policy: any Policy, logger: RunLogger) async throws -> RunReport {
        var history: [StepRecord] = []
        var escalations = 0
        var status: RunStatus = .maxStepsReached

        for i in 0..<config.maxSteps {
            if let k = config.killSwitchPath, FileManager.default.fileExists(atPath: k) {
                status = .aborted
                try await logger.log(record(i, obs: nil, by: "system", conf: nil,
                                            rat: "kill switch", action: nil,
                                            gate: "-", out: "stop file present", ver: nil, esc: nil))
                break
            }

            let obs = try await perceiver.observe(wantScreenshot: policy.wantsScreenshot)
            let rec = try await step(i, goal: goal, policy: policy, obs: obs,
                                     history: history, logger: logger)
            history.append(rec)

            if rec.escalation != nil { escalations += 1 }

            switch rec.action {
            case .done(let summary)?: status = .done; _ = summary; return RunReport(status: status, steps: i + 1, runDir: logger.runDir.path, escalations: escalations)
            default: break
            }
            if case .needsHuman = gateVerdict(rec.gate) { status = .needsHuman; break }
            if case .deny = gateVerdict(rec.gate) { status = .aborted; break }
            if rec.escalation != nil, s2 == nil { status = .escalatedToS2; break }
            // S2 was consulted and still couldn't decide — stop instead of
            // burning steps on an unrecoverable abstention.
            if rec.action == nil, rec.escalation != nil { status = .escalatedToS2; break }
            // Stuck-loop guard: identical action 3× in a row never converges.
            if history.suffix(3).count == 3,
               let a0 = history[history.count - 1].action,
               history.suffix(3).allSatisfy({ $0.action == a0 }) {
                try await logger.log(record(history.count, obs: nil, by: "system", conf: nil,
                                            rat: "stuck loop: same action 3x", action: nil,
                                            gate: "-", out: "aborted", ver: nil, esc: nil))
                status = .stuckLoop
                break
            }
        }
        return RunReport(status: status, steps: history.count, runDir: logger.runDir.path, escalations: escalations)
    }

    private func step(_ i: Int, goal: String, policy: any Policy, obs input: Snapshot,
                      history: [StepRecord], logger: RunLogger) async throws -> StepRecord {
        var obs = input
        // A throwing policy counts as abstention — logged like any other
        // low-confidence step instead of crashing the run.
        var decision: Decision
        do {
            decision = try await policy.decide(observation: obs, goal: goal, history: history)
        } catch {
            decision = Decision(action: nil, confidence: 0,
                                rationale: "policy error: \(error.localizedDescription)")
        }
        var decidedBy = "s1:\(policy.name)"
        var esc: StepRecord.Escalation?

        let lowConf = decision.confidence < config.confidenceThreshold || decision.action == nil
        if lowConf, case .done = decision.action { /* done is always final */ }
        else if lowConf {
            if let s2 {
                let reason = decision.action == nil
                    ? "s1 abstained (conf \(decision.confidence))"
                    : "s1 conf \(decision.confidence) < \(config.confidenceThreshold)"
                esc = StepRecord.Escalation(to: "s2:\(s2.name)", reason: reason)
                do {
                    decision = try await s2.decide(observation: obs, goal: goal,
                                                   history: history, reason: reason)
                } catch {
                    decision = Decision(action: nil, confidence: 0,
                                        rationale: "s2 error: \(error.localizedDescription)")
                }
                decidedBy = "s2:\(s2.name)"
            } else {
                esc = StepRecord.Escalation(to: "s2:none", reason: "no S2 configured; conf \(decision.confidence)")
            }
        }

        guard let action = decision.action else {
            let r = record(i, obs: obs, by: decidedBy, conf: decision.confidence,
                           rat: decision.rationale, action: nil,
                           gate: "-", out: "no action", ver: nil, esc: esc,
                           reply: decision.rawReply)
            try await logger.log(r)
            return r
        }

        // Screenshot on demand: the reason comes from the decision payload.
        // The re-observe lands the image via the sink before the actuator's
        // no-op outcome is recorded, so the record reads "captured", not
        // "we did something unspecified".
        if case .captureScreenshot = action {
            obs = try await perceiver.observe(wantScreenshot: true)
        }

        var verdict = gate.evaluate(action)
        // Secure-field guard: a password box must never be filled by an
        // agent — not by raw keystrokes (focus check) nor a targeted AX
        // write (ref's role check). Escalates to a human, same as the
        // deny list.
        if case .typeText = action, obs.secureTextFocused {
            verdict = .needsHuman(reason: "focused field is a secure text field")
        }
        if case .axSetValue(let ref, _) = action, isSecureField(ref, in: obs.axTree) {
            verdict = .needsHuman(reason: "target is a secure text field")
        }
        var outcome = "blocked"
        var verified: Bool?

        switch verdict {
        case .allow:
            do {
                outcome = try await actuator.perform(action, frontmostPID: obs.frontmostPID)
            } catch {
                // A failed action is evidence too — log it and keep looping
                // (the model sees "error:" and picks a different move).
                outcome = "error: \(error.localizedDescription)"
            }
        case .deny(let r), .needsHuman(let r):
            outcome = "blocked: \(r)"
            esc = esc ?? StepRecord.Escalation(to: "human", reason: r)
        }

        if case .verify(let expectation) = action {
            verified = await verify(expectation)
            outcome += verified! ? " | verified" : " | NOT verified"
        }

        let r = record(i, obs: obs, by: decidedBy, conf: decision.confidence,
                       rat: decision.rationale, action: action,
                       gate: verdict.label, out: outcome, ver: verified, esc: esc,
                       reply: decision.rawReply)
        try await logger.log(r)
        return r
    }

    /// Post-action check: re-observe and see if the expectation is visible in
    /// the AX tree / window titles. Real verification, not self-report. Apps
    /// publish their new AX state asynchronously — a verify that runs in the
    /// same tick as the write can race it, so one short settle + re-observe
    /// keeps the check honest without hiding real failures.
    private func verify(_ expectation: String) async -> Bool {
        // Cold apps (freshly opened document) can take >1s to publish their
        // new AX state — poll briefly before declaring the write invisible.
        for attempt in 0..<5 {
            if attempt > 0 { try? await Task.sleep(nanoseconds: 400_000_000) }
            if await expectationVisible(expectation) { return true }
        }
        return false
    }

    private func expectationVisible(_ expectation: String) async -> Bool {
        guard let obs = try? await perceiver.observe(wantScreenshot: false) else { return false }
        let needle = expectation.lowercased()
        if treeContains(obs.axTree, needle) { return true }
        if obs.windows.contains(where: { $0.title?.lowercased().contains(needle) ?? false }) {
            return true
        }
        // A CLI-launched app isn't always frontmost (keystrokes still land) —
        // its tree would be missed by the frontmost-only check, so walk the
        // other window-owning apps' trees too (bounded; only on a miss).
        var seen = Set<pid_t>()
        for w in obs.windows {
            guard w.pid != obs.frontmostPID, seen.insert(w.pid).inserted else { continue }
            if seen.count > 8 { break }
            if let tree = AXReader.snapshotTree(pid: w.pid), treeContains(tree, needle) {
                return true
            }
        }
        return false
    }

    private func isSecureField(_ ref: String, in tree: AXNode?) -> Bool {
        tree?.flattened.first { $0.ref == ref }?.role == "AXSecureTextField"
    }

    private func treeContains(_ tree: AXNode?, _ needle: String) -> Bool {
        guard let tree else { return false }
        for node in tree.flattened {
            if let v = node.value?.lowercased(), v.contains(needle) { return true }
            if let t = node.title?.lowercased(), t.contains(needle) { return true }
            if let d = node.desc?.lowercased(), d.contains(needle) { return true }
        }
        return false
    }

    private func record(_ i: Int, obs: Snapshot?, by: String, conf: Double?,
                        rat: String?, action: Action?, gate: String, out: String?,
                        ver: Bool?, esc: StepRecord.Escalation?,
                        reply: String? = nil) -> StepRecord {
        StepRecord(index: i, time: Date(), observation: obs?.summary ?? "none",
                   decidedBy: by, confidence: conf, rationale: rat,
                   modelReply: reply,
                   action: action, gate: gate, outcome: out,
                   verified: ver, escalation: esc)
    }

    private func gateVerdict(_ label: String) -> GateVerdict {
        if label.hasPrefix("deny") { return .deny(reason: label) }
        if label.hasPrefix("needsHuman") { return .needsHuman(reason: label) }
        return .allow
    }
}
