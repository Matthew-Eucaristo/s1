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
                              killSwitchPath: String? = nil,
                              perceiver: any Perceiver = SystemPerceiver()) async throws -> Int {
        let recs = try steps(in: runDir)
        var i = 0
        // Focus before a replayed wait: keys after it must still go there.
        var aimed: FocusMark?
        steps: for rec in recs {
            if Task.isCancelled || (killSwitchPath.map { FileManager.default.fileExists(atPath: $0) } ?? false) {
                try await logger.log(StepRecord(index: i, time: Date(),
                    observation: "replay", decidedBy: "system",
                    confidence: nil, rationale: Task.isCancelled ? "task cancelled" : "kill switch",
                    modelReply: nil, action: nil, gate: "-", outcome: "aborted",
                    verified: nil, escalation: nil))
                break steps
            }
            guard var action = rec.action else { continue }
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
                case .axPress, .axSetValue, .axAction, .axSetAttribute,
                     .typeText, .keyCombo, .editText, .menuItem: true
                default: false
                }
                let liveObs = needsObs
                    ? try? await perceiver.observe(wantScreenshot: false)
                    : nil
                // A ref is an index into the screen as it was recorded:
                // re-find that element now, or ask instead of pressing
                // whatever sits at the old index today.
                var lost: String?
                if let ref = action.axRef, liveObs != nil {
                    if let live = rec.target?.resolve(in: liveObs?.axTree) {
                        action = action.withRef(live)
                    } else {
                        lost = rec.target == nil
                            ? "this recording doesn't say which element \(ref) was"
                            : "the recorded element (\(rec.target?.label ?? rec.target?.role ?? ref)) isn't on screen"
                    }
                }
                var verdict = gate.evaluate(action)
                if let lost { verdict = .needsHuman(reason: lost) }
                // Keys, text and menu commands go wherever focus is: a
                // password box (typing, paste, Edit › Paste) never gets
                // them, and an unreadable screen is no proof it isn't one.
                let focusBound: Bool = switch action {
                case .typeText, .keyCombo, .editText, .menuItem: true
                default: false
                }
                if focusBound, liveObs?.secureTextFocused != false {
                    verdict = .needsHuman(reason: liveObs == nil
                        ? "couldn't read the screen to check the focused field"
                        : "focused field is a secure text field")
                }
                // Same secure-field coverage as the live loop: any targeted
                // write/perform on a password box escalates.
                switch action {
                case .axPress(let ref), .axSetValue(let ref, _), .axAction(let ref, _),
                     .axSetAttribute(let ref, _, _):
                    if liveObs == nil {
                        verdict = .needsHuman(reason: "couldn't read the screen to find \(ref)")
                    } else if S1SecureField.isSecure(ref, in: liveObs?.axTree) {
                        verdict = .needsHuman(reason: "target is a secure text field")
                    }
                default: break
                }
                // Replay of text into a terminal gets the command scan too —
                // a recorded "ls" is fine, a recorded "rm file" isn't.
                if SafetyGate.isTerminal(liveObs?.frontmostApp) {
                    let payload: String? = switch action {
                    case .typeText(let t): t
                    case .axSetValue(_, let v): v
                    default: nil
                    }
                    if let payload, case .needsHuman(let r) = SafetyGate.evaluateTerminalPayload(payload) {
                        verdict = .needsHuman(reason: r)
                    }
                }
                // Same focus guard as the live loop: the user moving focus
                // during a replayed wait stops the keys meant for before.
                var moved = false
                if case .allow = verdict,
                   let why = FocusGuard.check(action, aimed: aimed, now: liveObs?.focus) {
                    verdict = .needsHuman(reason: why)
                    moved = true
                }
                var outcome = "blocked"
                if case .allow = verdict {
                    if case .wait(let s) = action {
                        if aimed == nil { aimed = await perceiver.focus() }
                        if actuator is DryRunActuator {
                            // A dry-run previews without touching the machine
                            // — burning a real 60s recorded wait defeats that.
                            outcome = "[dry-run] wait \(s)s"
                        } else {
                            // Same guard rail as the live loop: replaying a
                            // run that recorded wait(3600) must not sit for
                            // an hour with no cap.
                            let capped = s.isFinite ? min(max(s, 0), 300) : 0
                            outcome = await S1Runner.sleepInterruptibly(capped, killSwitchPath: killSwitchPath)
                                ? "waited \(capped)s" : "interrupted (kill switch)"
                        }
                    } else {
                        do {
                            outcome = try await actuator.perform(action, frontmostPID: liveObs?.frontmostPID)
                        } catch {
                            outcome = "error: \(error.localizedDescription)"
                        }
                    }
                }
                // Keep the identity: a replay's own record can be replayed too.
                try await logger.log(StepRecord(index: i, time: Date(),
                    observation: "replay", decidedBy: "replay",
                    confidence: nil, rationale: rec.rationale, modelReply: nil, action: action,
                    gate: verdict.label, outcome: outcome,
                    verified: nil, escalation: nil, target: rec.target))
                if !FocusGuard.keepsFocus(action) { aimed = nil }
                // A step that needs the user ends the replay, as it ends a
                // live run: the steps after it (a Return after blocked
                // typing, keys aimed at a focus that moved) assumed it ran.
                var needsHuman = moved
                if case .needsHuman = verdict { needsHuman = true }
                if needsHuman { i += 1; break steps }
            }
            i += 1
        }
        return i
    }
}
