import Foundation

/// The running conversation across goals: a stable session id (provider
/// routing + prompt caching, e.g. OpenCode Go's `x-opencode-session`) and
/// the last few turns so S1/S2 can resolve "that", "it", "again".
/// Rotates after 30 minutes of silence — a new conversation, a new cache.
public final class Conversation: @unchecked Sendable {
    public struct Turn: Sendable, Equatable {
        public var goal: String
        public var outcome: String
        /// S1 subgoals that ran (delegated or skill steps) — "save that as a skill".
        public var steps: [String] = []
        public var ok: Bool = true
    }

    public static let shared = Conversation()

    private let lock = NSLock()
    private var id = UUID().uuidString.lowercased()
    private var last = Date()
    private var turns: [Turn] = []
    /// Rolling digest of turns that fell off the 200-turn store — the
    /// compaction side of the sliding window. Bounded at 120 lines (about
    /// 12k chars worst case) so a marathon session can't leak memory; the
    /// total counter still records everything that ever left the window.
    private var evicted: [String] = []
    private var evictedTotal = 0
    /// Same digesting, minus the arrays: how many stored turns the last
    /// `recentContext` call left outside the char budget.
    let idleReset: TimeInterval

    public init(idleReset: TimeInterval = 30 * 60) { self.idleReset = idleReset }

    private func rotateIfIdle(_ now: Date) {
        if now.timeIntervalSince(last) > idleReset {
            id = UUID().uuidString.lowercased()
            turns = []
            evicted = []
            evictedTotal = 0
        }
        last = now
    }

    /// One digest line for the compaction list — goal plus outcome,
    /// terse. Locked callers only.
    private static func digest(_ t: Turn) -> String {
        let g = t.goal.prefix(90)
        let o = t.outcome.prefix(90)
        return o.isEmpty ? String(g)
            : "\(g) → \(t.ok ? "" : "FAILED: ")\(o)"
    }

    /// One step as the next request needs to know it: what was done and
    /// what visibly came of it ("keyCombo(nexttrack)", "axPress(e273) → new:
    /// “Caprice No. 24”"). Answers and no-ops aren't worth the space.
    static func digest(_ r: StepRecord) -> String? {
        guard let a = r.action else { return nil }
        switch a { case .done, .verify, .wait: return nil; default: break }
        var s = LLMDecisionCodec.describe(a)
        if let o = r.outcome {
            if o.hasPrefix("error:") || o.hasPrefix("blocked:") { s += " FAILED: " + o.prefix(80) }
            else if let i = o.range(of: " → ") { s += " → " + o[i.upperBound...].prefix(90) }
        }
        return s
    }

    public func sessionID(now: Date = Date()) -> String {
        lock.lock(); defer { lock.unlock() }
        rotateIfIdle(now)
        return id
    }

    public func record(goal: String, outcome: String, steps: [String] = [], ok: Bool = true,
                       now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        rotateIfIdle(now)
        turns.append(Turn(goal: String(goal.prefix(300)), outcome: String(outcome.prefix(400)),
                          steps: steps.prefix(12).map { String($0.prefix(200)) }, ok: ok))
        // Sliding window: the store keeps the newest 200 turns. Turns that
        // fall off are compacted into terse digest lines — the model still
        // knows what happened earlier in the session instead of the oldest
        // work silently vanishing.
        if turns.count > 200 {
            let extra = turns.count - 200
            for t in turns.prefix(extra) { evicted.append(Self.digest(t)) }
            evictedTotal += extra
            turns.removeFirst(extra)
            if evicted.count > 120 { evicted.removeFirst(evicted.count - 120) }
        }
    }

    /// The whole session, newest kept first when it outgrows `budget`
    /// characters (oldest dropped) — returned oldest → newest.
    public func recent(_ n: Int = 200, budget: Int = 6000) -> [Turn] {
        lock.lock(); defer { lock.unlock() }
        return window(n, budget: budget)
    }

    /// The sliding-window + compaction pair: `turns` is the newest history
    /// that fits `budget`; `summary` is a bounded digest of everything
    /// older — turns still in the store but over budget AND turns that
    /// aged out of the store entirely. Modern agent-loop context handling:
    /// evicted work is summarized, never silently dropped.
    public func recentContext(_ n: Int = 200, budget: Int = 6000,
                              summaryBudget: Int = 1200) -> (summary: String?, turns: [Turn]) {
        lock.lock(); defer { lock.unlock() }
        let win = window(n, budget: budget)
        // Stored-but-over-budget turns get digested on the fly; turns that
        // already aged out of the store carry their digests in `evicted`.
        let storedOut = turns.count - win.count
        let lines = evicted + turns.prefix(storedOut).map(Self.digest)
        let total = evictedTotal + storedOut
        guard total > 0 else { return (nil, win) }
        // Bound the digest: drop the OLDEST lines first — the freshest
        // context is always the most recent work.
        var used = 0
        var kept: [String] = []
        for line in lines.reversed() {
            used += line.count + 2
            if used > summaryBudget { break }
            kept.insert(line, at: 0)
        }
        let hidden = total - kept.count
        var s = "\(total) earlier turn\(total == 1 ? "" : "s") this session"
        if !kept.isEmpty {
            s += ": " + kept.joined(separator: "; ")
        }
        if hidden > 0 { s += " (\(hidden) oldest not shown)" }
        return (s, win)
    }

    /// Locked helper — the budgeted window of stored turns.
    private func window(_ n: Int, budget: Int) -> [Turn] {
        var out: [Turn] = [], used = 0
        for t in turns.suffix(n).reversed() {
            used += t.goal.count + t.outcome.count + 8
            if used > budget, !out.isEmpty { break }
            out.insert(t, at: 0)
        }
        return out
    }

    public func lastSuccessful() -> Turn? {
        lock.lock(); defer { lock.unlock() }
        return turns.last { $0.ok }
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        id = UUID().uuidString.lowercased()
        turns = []
        evicted = []
        evictedTotal = 0
        last = Date()
    }
}
