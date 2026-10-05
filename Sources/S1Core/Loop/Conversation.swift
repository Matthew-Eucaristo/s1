import Foundation

/// The running conversation across goals: a stable session id (provider
/// routing + prompt caching, e.g. OpenCode Go's `x-opencode-session`) and
/// the last few turns so S1/S2 can resolve "that", "it", "again".
/// Rotates after 30 minutes of silence — a new conversation, a new cache.
public final class Conversation: @unchecked Sendable {
    public struct Turn: Sendable, Equatable {
        public var goal: String
        public var outcome: String
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

    public func record(goal: String, outcome: String, now: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        rotateIfIdle(now)
        turns.append(Turn(goal: String(goal.prefix(300)), outcome: String(outcome.prefix(400))))
        if turns.count > 12 { turns.removeFirst(turns.count - 12) }
    }

    public func recent(_ n: Int = 6) -> [Turn] {
        lock.lock(); defer { lock.unlock() }
        return Array(turns.suffix(n))
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        id = UUID().uuidString.lowercased()
        turns = []
        last = Date()
    }
}
