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
    /// The done summary — S2's answer when the goal was a question.
    public var summary: String? = nil
    /// S1 subgoals that finished (delegated by S2, or a skill's steps).
    public var subgoals: [String] = []

    /// A real answer worth showing/speaking (not the grammar's boilerplate).
    public var answer: String? {
        guard status == .done, let s = summary?.trimmingCharacters(in: .whitespacesAndNewlines),
              !s.isEmpty, !["done", "goal completed"].contains(s.lowercased()) else { return nil }
        return s
    }
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

    /// `onPhase` narrates each step's phase ("observing", "thinking",
    /// "reasoning", "acting") — lets a UI show the run is alive while a
    /// slow local model holds the decision call for tens of seconds.
    /// `plan` pre-seeds S1 subgoals (a saved skill); the run is done once
    /// they all finish, unless S2 had to take over.
    public func run(goal: String, policy: any Policy, logger: RunLogger, plan: [String] = [],
                    onPhase: (@Sendable (String) -> Void)? = nil) async throws -> RunReport {
        var history: [StepRecord] = []
        // S2 → S1 delegation: subgoals S1 runs with its own scoped history.
        var queue: [String] = Array(plan.prefix(12))
        var completed: [String] = []
        var subHistory: [StepRecord] = []
        var delegations = 0
        var forceS2: String?
        var escalations = 0
        var status: RunStatus = .maxStepsReached

        for i in 0..<config.maxSteps {
            // A cancelled owner task ends the run even when no kill-switch
            // file is configured (e.g. a forgotten config, or a caller that
            // cancels instead of writing the file).
            if Task.isCancelled {
                status = .aborted
                try await logger.log(record(i, obs: nil, by: "system", conf: nil,
                                            rat: "task cancelled", action: nil,
                                            gate: "-", out: "cancelled", ver: nil, esc: nil))
                break
            }
            if let k = config.killSwitchPath, FileManager.default.fileExists(atPath: k) {
                status = .aborted
                try await logger.log(record(i, obs: nil, by: "system", conf: nil,
                                            rat: "kill switch", action: nil,
                                            gate: "-", out: "stop file present", ver: nil, esc: nil))
                break
            }

            let obs: Snapshot
            do {
                onPhase?("observing…")
                obs = try await perceiver.observe(preferScreenshot: policy.wantsScreenshot)
            } catch {
                // Evidence continuity: a perception failure must land in
                // steps.jsonl too — otherwise the run file ends mid-thought
                // with no trace of why.
                try await logger.log(record(i, obs: nil, by: "system", conf: nil,
                                            rat: "observation failed", action: nil,
                                            gate: "-", out: error.localizedDescription,
                                            ver: nil, esc: nil))
                throw error
            }
            let rec: StepRecord
            let delegated: [String]?
            let sub = queue.first
            do {
                (rec, delegated) = try await step(i, goal: goal, s1Goal: sub ?? goal, policy: policy, obs: obs,
                                                  history: history, s1History: sub == nil ? history : subHistory,
                                                  forceS2: forceS2, logger: logger, onPhase: onPhase)
                forceS2 = nil
            } catch {
                // A stop landing mid-decision (kill switch, cancelled task)
                // ends the run as aborted; any other failure is reported as one.
                let stopped = Task.isCancelled
                    || config.killSwitchPath.map { FileManager.default.fileExists(atPath: $0) } == true
                guard stopped else { throw error }
                status = .aborted
                break
            }
            if rec.escalation != nil { escalations += 1 }

            if let delegated {
                history.append(rec)
                delegations += 1
                // A planner that keeps re-planning isn't converging.
                if delegations > 3 { status = .stuckLoop; break }
                queue = Array(delegated.prefix(8)); subHistory = []
                onPhase?("S1: \(queue.count) subgoal\(queue.count == 1 ? "" : "s")")
                continue
            }
            if let sub {
                if case .done? = rec.action, rec.escalation == nil {
                    // Subgoal finished — not the run. Next subgoal, or back to S2.
                    queue.removeFirst(); subHistory = []
                    completed.append(sub)
                    if queue.isEmpty, !plan.isEmpty, delegations == 0, escalations == 0 {
                        return RunReport(status: .done, steps: i + 1, runDir: logger.runDir.path,
                                         escalations: 0, summary: "done", subgoals: completed)
                    }
                    if queue.isEmpty {
                        forceS2 = "delegated subgoals finished — check the screen; reply done (with the answer, if one was asked) when the goal is met"
                    }
                    _ = sub
                    continue
                }
                if rec.escalation != nil { queue = []; subHistory = [] }   // S2 took over
                else { subHistory.append(rec) }
            }
            history.append(rec)

            switch rec.action {
            case .done(let summary)?: status = .done; return RunReport(status: status, steps: i + 1, runDir: logger.runDir.path, escalations: escalations, summary: summary, subgoals: completed)
            default: break
            }
            if case .needsHuman = gateVerdict(rec.gate) { status = .needsHuman; break }
            if case .deny = gateVerdict(rec.gate) { status = .aborted; break }
            if rec.escalation != nil, s2 == nil { status = .escalatedToS2; break }
            // S2 was consulted and still couldn't decide — stop instead of
            // burning steps on an unrecoverable abstention.
            if rec.action == nil, rec.escalation != nil { status = .escalatedToS2; break }
            // Stuck-loop guards: a model repeating the same action 3× never
            // converges, nor does an A-B-A-B oscillation (click, wait, click,
            // wait…). Grammar steps are exempt: they come from the user's own
            // words ("press tab 3 times") and end with the command.
            let modelTail = { (n: Int) in
                history.suffix(n).count == n && history.suffix(n).allSatisfy { $0.decidedBy != "s1:\(AXPolicy.grammarName)" }
            }
            if modelTail(3),
               let a0 = history[history.count - 1].action,
               history.suffix(3).allSatisfy({ $0.action == a0 }) {
                try await logger.log(record(history.count, obs: nil, by: "system", conf: nil,
                                            rat: "stuck loop: same action 3x", action: nil,
                                            gate: "-", out: "aborted", ver: nil, esc: nil))
                status = .stuckLoop
                break
            }
            if modelTail(4) {
                let tail = history.suffix(4).compactMap { $0.action }
                if tail.count == 4, tail[0] == tail[2], tail[1] == tail[3], tail[0] != tail[1] {
                    try await logger.log(record(history.count, obs: nil, by: "system", conf: nil,
                                                rat: "stuck loop: A-B-A-B oscillation", action: nil,
                                                gate: "-", out: "aborted", ver: nil, esc: nil))
                    status = .stuckLoop
                    break
                }
            }
        }
        return RunReport(status: status, steps: history.count, runDir: logger.runDir.path,
                         escalations: escalations, subgoals: completed)
    }

    private func step(_ i: Int, goal: String, s1Goal: String, policy: any Policy, obs input: Snapshot,
                      history: [StepRecord], s1History: [StepRecord], forceS2: String?,
                      logger: RunLogger,
                      onPhase: (@Sendable (String) -> Void)?) async throws -> (StepRecord, [String]?) {
        var obs = input
        // A throwing policy counts as abstention — logged like any other
        // low-confidence step instead of crashing the run.
        var decision: Decision
        if let forceS2, s2 != nil {
            decision = Decision(action: nil, confidence: 0, rationale: forceS2)
        } else { do {
            // Raced against the kill file — a model request would otherwise
            // sit out the whole HTTP timeout before `s1 stop` is noticed.
            let decisionObs = obs
            onPhase?("thinking…")
            decision = try await S1Runner.racingKillSwitch(config.killSwitchPath) {
                try await policy.decide(observation: decisionObs, goal: s1Goal, history: s1History)
            }
        } catch {
            if let k = config.killSwitchPath, FileManager.default.fileExists(atPath: k) {
                // Record the interrupted step, then propagate — the run ends
                // aborted, not as an abstention that walks into S2.
                let r = record(i, obs: obs, by: "s1:\(policy.name)", conf: nil,
                               rat: "kill switch mid-decision", action: nil,
                               gate: "-", out: "interrupted", ver: nil, esc: nil)
                try await logger.log(r)
                throw error
            }
            decision = Decision(action: nil, confidence: 0,
                                rationale: "policy error: \(error.localizedDescription)")
        } }
        var decidedBy = "s1:\(policy.name)"
        var esc: StepRecord.Escalation?

        let lowConf = decision.confidence < config.confidenceThreshold || decision.action == nil
        // A "done" the Judge doubts is just another unsure step: the Reasoner
        // checks what actually happened and finishes, retries, or explains.
        if lowConf {
            if let s2 {
                var why = forceS2 ?? (decision.action == nil
                    ? "s1 abstained (conf \(decision.confidence)): \(decision.rationale)"
                    : "s1 conf \(decision.confidence) < \(config.confidenceThreshold)")
                if forceS2 == nil, s1Goal != goal { why = "subgoal '\(s1Goal)' failed — \(why)" }
                let reason = why
                esc = StepRecord.Escalation(to: "s2:\(s2.name)", reason: reason)
                do {
                    // A reasoner that can see gets the screen with the
                    // escalation; capture failures fall back to AX only.
                    if s2.wantsScreenshot, obs.screenshotPath == nil,
                       let shot = try? await perceiver.observe(wantScreenshot: true) {
                        obs = shot
                    }
                    let s2Obs = obs
                    onPhase?("reasoning (S2)…")
                    decision = try await S1Runner.racingKillSwitch(config.killSwitchPath) {
                        try await s2.decide(observation: s2Obs, goal: goal,
                                            history: history, reason: reason)
                    }
                } catch {
                    if let k = config.killSwitchPath,
                       FileManager.default.fileExists(atPath: k) {
                        let r = record(i, obs: obs, by: "s2:\(s2.name)", conf: nil,
                                       rat: "kill switch mid-decision", action: nil,
                                       gate: "-", out: "interrupted", ver: nil,
                                       esc: esc)
                        try await logger.log(r)
                        throw error
                    }
                    decision = Decision(action: nil, confidence: 0,
                                        rationale: "s2 error: \(error.localizedDescription)")
                }
                decidedBy = "s2:\(s2.name)"
                // A Reasoner guessing blindly (a "placeholder" click at 0,0,
                // near-zero confidence) asks the user instead of acting.
                if let a = decision.action, Self.unusable(a, confidence: decision.confidence) {
                    let why = "I'm not sure what to do here; name the button or item you mean"
                    let r = record(i, obs: obs, by: decidedBy, conf: decision.confidence,
                                   rat: decision.rationale, action: nil,
                                   gate: "needsHuman(\(why))", out: "suppressed: \(a)",
                                   ver: nil, esc: StepRecord.Escalation(to: "human", reason: why),
                                   reply: decision.rawReply)
                    try await logger.log(r)
                    return (r, nil)
                }
            } else {
                esc = StepRecord.Escalation(to: "s2:none", reason: "no S2 configured; conf \(decision.confidence)")
                // Below threshold with nowhere to escalate: suppress the
                // action instead of executing it. "Below threshold → S2"
                // means the uncertain step must NOT touch the screen —
                // acting first and stopping after would defeat the gate.
                let r = record(i, obs: obs, by: decidedBy, conf: decision.confidence,
                               rat: decision.rationale, action: nil,
                               gate: "-", out: "suppressed: below threshold, no S2",
                               ver: nil, esc: esc, reply: decision.rawReply)
                try await logger.log(r)
                return (r, nil)
            }
        }

        if decision.action == nil, let goals = decision.delegate, !goals.isEmpty, esc != nil {
            let r = record(i, obs: obs, by: decidedBy, conf: decision.confidence,
                           rat: decision.rationale, action: nil, gate: "-",
                           out: "delegated to S1: " + goals.joined(separator: " | "),
                           ver: nil, esc: esc, reply: decision.rawReply)
            try await logger.log(r)
            return (r, goals)
        }
        guard let action = decision.action else {
            let r = record(i, obs: obs, by: decidedBy, conf: decision.confidence,
                           rat: decision.rationale, action: nil,
                           gate: "-", out: "no action", ver: nil, esc: esc,
                           reply: decision.rawReply)
            try await logger.log(r)
            return (r, nil)
        }

        // Screenshot on demand: the reason comes from the decision payload.
        // The re-observe lands the image via the sink before the actuator's
        // no-op outcome is recorded, so the record reads "captured", not
        // "we did something unspecified".
        // A refused capture (no Screen Recording grant) hands back to the user
        // with the reason. Thrown, it would read as a Stop.
        var captureError: String?
        if case .captureScreenshot = action {
            do { obs = try await perceiver.observe(wantScreenshot: true) }
            catch { captureError = error.localizedDescription }
        }

        var verdict = gate.evaluate(action)
        if let captureError { verdict = .needsHuman(reason: captureError) }
        // Secure-field guard: a password box must never be filled by an
        // agent — not by raw keystrokes (focus check) nor a targeted AX
        // write (ref's role check). Escalates to a human, same as the
        // deny list.
        if case .typeText = action, obs.secureTextFocused {
            verdict = .needsHuman(reason: "focused field is a secure text field")
        }
        // Paste (Cmd+V) lands in a password box without a keystroke —
        // keyCombo gets the same guard.
        if case .editText = action, obs.secureTextFocused {
            verdict = .needsHuman(reason: "focused field is a secure text field")
        }
        if case .keyCombo = action, obs.secureTextFocused {
            verdict = .needsHuman(reason: "focused field is a secure text field")
        }
        // Any targeted write/perform on a secure field escalates too — not
        // just the text-carrying axSetValue.
        switch action {
        case .axPress(let ref), .axSetValue(let ref, _), .axAction(let ref, _),
             .axSetAttribute(let ref, _, _):
            if isSecureField(ref, in: obs.axTree) {
                verdict = .needsHuman(reason: "target is a secure text field")
            }
        default: break
        }
        // Keystrokes into a terminal become commands on Return — text
        // headed there is scanned with the command-level list, so a plain
        // "rm file" can't ride in under the flag-bearing patterns.
        if SafetyGate.terminalApps.contains(obs.frontmostApp ?? "") {
            let payload: String? = switch action {
            case .typeText(let t): t
            case .axSetValue(_, let v): v
            default: nil
            }
            if let payload, case .needsHuman(let r) = SafetyGate.evaluateTerminalPayload(payload) {
                verdict = .needsHuman(reason: r)
            }
        }
        var outcome = "blocked"
        var verified: Bool?

        switch verdict {
        case .allow:
            if case .webSearch(let q) = action {
                // Searching is the Reasoner's provider's job, not the screen's.
                if let s2, s2.canSearchWeb, !(actuator is DryRunActuator) {
                    onPhase?("Searching the web for “\(q.prefix(60))”…")
                    do { outcome = "web results: " + (try await s2.searchWeb(q)) }
                    catch { outcome = "error: web search failed: \(error.localizedDescription)" }
                } else {
                    outcome = actuator is DryRunActuator ? "[dry-run] web search"
                        : "error: web search isn't available — answer from what you know and say it may be out of date"
                }
            } else if case .wait(let s) = action {
                // Wait in the loop, not the actuator: a 60s `wait` must hear
                // the kill switch within ~0.5s, not when it finally ends.
                // Clamp too — a model saying "wait an hour" shouldn't park a
                // run for an hour; 5 min bounds any legitimate settle-wait.
                // Dry-run executes nothing, so it doesn't burn the wait either.
                if actuator is DryRunActuator {
                    outcome = "[dry-run] wait \(s)s"
                } else {
                    let capped = s.isFinite ? min(max(s, 0), 300) : 0
                    outcome = await S1Runner.sleepInterruptibly(capped, killSwitchPath: config.killSwitchPath)
                        ? "waited \(capped)s" : "interrupted (kill switch)"
                }
            } else {
                do {
                    outcome = try await actuator.perform(action, frontmostPID: obs.frontmostPID)
                    if Self.checksEffect(action, decidedBy: decidedBy), !(actuator is DryRunActuator) {
                        outcome += await effect(of: action, before: obs)
                    }
                } catch {
                    // A failed action is evidence too — log it and keep looping
                    // (the model sees "error:" and picks a different move).
                    outcome = "error: \(error.localizedDescription)"
                }
            }
        case .deny(let r), .needsHuman(let r):
            outcome = "blocked: \(r)"
            esc = esc ?? StepRecord.Escalation(to: "human", reason: r)
        }

        // A blocked verify can never become visible — skip the 2s re-observe
        // poll on deny/needsHuman instead of stalling on a known no.
        if case .verify(let expectation) = action, case .allow = verdict {
            verified = await verify(expectation)
            outcome += verified == true ? " | verified" : " | NOT verified"
        }

        let r = record(i, obs: obs, by: decidedBy, conf: decision.confidence,
                       rat: decision.rationale, action: action,
                       gate: verdict.label, out: outcome, ver: verified, esc: esc,
                       reply: decision.rawReply)
        try await logger.log(r)
        return (r, nil)
    }

    /// Steps whose result shows on screen. Clicks and presses always (a press
    /// that did nothing gets a real click); typing and keys only for model
    /// steps, where the next decision depends on knowing what happened.
    static func checksEffect(_ action: Action, decidedBy: String) -> Bool {
        switch action {
        case .click, .doubleClick, .rightClick, .axPress, .axAction, .axSetAttribute: return true
        case .typeText, .editText, .axSetValue, .drag, .scroll: return decidedBy.hasPrefix("s2:")
        case .keyCombo(let keys):
            return decidedBy.hasPrefix("s2:") && !keys.contains { CGEventActuator.mediaKeys[$0.lowercased()] != nil }
        default: return false
        }
    }

    /// An action not worth executing: a pointer action at the screen's corner
    /// (models emit 0,0 as a placeholder) or a screen action at near-zero
    /// confidence. Answers and checks are always fine.
    static func unusable(_ a: Action, confidence: Double) -> Bool {
        switch a {
        case .done, .verify, .wait, .captureScreenshot, .webSearch: return false
        case .click(let x, let y), .doubleClick(let x, let y), .rightClick(let x, let y), .moveMouse(let x, let y):
            if x <= 1 && y <= 1 { return true }
        case .drag(let fx, let fy, _, _):
            if fx <= 1 && fy <= 1 { return true }
        default: break
        }
        return confidence < 0.25
    }

    /// Roles where a second activation would undo the first.
    static let toggles: Set<String> = ["AXCheckBox", "AXSwitch", "AXDisclosureTriangle", "AXToggle"]

    /// What the step changed, polled briefly (apps publish AX changes a beat
    /// late). An AXPress that changed nothing gets one real click on the
    /// element's center: SwiftUI and web controls often accept AXPress and
    /// ignore it.
    private func effect(of action: Action, before: Snapshot) async -> String {
        if let change = await observedChange(since: before) { return " → " + change }
        if case .axPress(let ref) = action,
           let n = before.axTree?.flattened.first(where: { $0.ref == ref }),
           let f = n.frame, f.w > 0, f.h > 0, !Self.toggles.contains(n.role) {
            let click = Action.click(x: f.x + f.w / 2, y: f.y + f.h / 2)
            guard (try? await actuator.perform(click, frontmostPID: before.frontmostPID)) != nil else {
                return " → no visible change"
            }
            if let change = await observedChange(since: before) {
                return " (the press did nothing, so s1 clicked it) → " + change
            }
            return " → no visible change, even after a real click"
        }
        return " → no visible change"
    }

    private func observedChange(since before: Snapshot) async -> String? {
        for delay: UInt64 in [250_000_000, 500_000_000] {
            try? await Task.sleep(nanoseconds: delay)
            guard let now = try? await perceiver.observe(wantScreenshot: false) else { return nil }
            if let change = ScreenDiff.summary(before, now) { return change }
        }
        return nil
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
        S1SecureField.isSecure(ref, in: tree)
    }

    private func treeContains(_ tree: AXNode?, _ needle: String) -> Bool {
        guard let tree else { return false }
        for node in tree.flattened {
            if let v = node.value?.lowercased(), v.contains(needle) { return true }
            if let t = node.title?.lowercased(), t.contains(needle) { return true }
            if let d = node.desc?.lowercased(), d.contains(needle) { return true }
            if let h = node.help?.lowercased(), h.contains(needle) { return true }
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

/// Shared secure-field check — the loop's password guard, also used by
/// replay so a re-run never types into an AXSecureTextField either.
enum S1SecureField {
    static func isSecure(_ ref: String, in tree: AXNode?) -> Bool {
        tree?.flattened.first { $0.ref == ref }?.role == "AXSecureTextField"
    }
}
