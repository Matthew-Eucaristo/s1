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
    let idleReset: TimeInterval

    public init(idleReset: TimeInterval = 30 * 60) { self.idleReset = idleReset }

    private func rotateIfIdle(_ now: Date) {
        if now.timeIntervalSince(last) > idleReset {
            id = UUID().uuidString.lowercased()
            turns = []
        }
        last = now
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
        if turns.count > 200 { turns.removeFirst(turns.count - 200) }
    }

    /// The whole session, newest kept first when it outgrows `budget`
    /// characters (oldest dropped) — returned oldest → newest.
    public func recent(_ n: Int = 200, budget: Int = 6000) -> [Turn] {
        lock.lock(); defer { lock.unlock() }
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
        last = Date()
    }
}
