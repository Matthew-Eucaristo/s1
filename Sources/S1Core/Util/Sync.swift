import Synchronization

/// A value shared across threads — audio taps, recognizer callbacks, pipe
/// handlers — guarded by a `Mutex`. Read with `value`; mutate in place with
/// `withLock` so read-modify-write (`append`, `[i] = …`) is atomic.
public final class Locked<Value: Sendable>: Sendable {
    private let m: Mutex<Value>
    public init(_ value: Value) { m = Mutex(value) }

    public var value: Value {
        get { m.withLock { $0 } }
        set { m.withLock { $0 = newValue } }
    }

    @discardableResult
    public func withLock<R: Sendable>(_ body: (inout Value) -> R) -> R {
        m.withLock { body(&$0) }
    }
}

/// A one-way flag set from any thread: `set()` and `get`, or `claim()` when
/// exactly one of several racing callbacks may act (resume-once).
public final class AtomicFlag: Sendable {
    private let v = Atomic<Bool>(false)
    public init() {}
    public var get: Bool { v.load(ordering: .acquiring) }
    public func set() { v.store(true, ordering: .releasing) }
    /// True for the first caller only.
    public func claim() -> Bool {
        v.compareExchange(expected: false, desired: true, ordering: .acquiringAndReleasing).exchanged
    }
}
