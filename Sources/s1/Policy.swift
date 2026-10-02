import Foundation

/// The "brain" seam. v0 ships a deterministic dummy; System 1 models plug in
/// later by conforming to this protocol (see README: "Plugging in a model").
public protocol Policy {
    /// Called once per loop iteration. Return the next action, or `nil` to
    /// stop the loop. `history` holds the records of all previous steps.
    func next(observation: Observation, step: Int, history: [StepRecord]) -> Action?
}

/// Deterministic scripted policy used by tests and dry-runs. The default
/// script exercises safe actions, one gated commit key (enter), and a wait.
public final class DummyPolicy: Policy {
    public static let defaultScript: [Action] = [
        Action(kind: "move_mouse", x: 120, y: 120, confidence: 0.9),
        Action(kind: "click", x: 120, y: 120, confidence: 0.8),
        Action(kind: "type_text", text: "hello from s1", confidence: 0.7),
        Action(kind: "key_press", key: "enter", confidence: 0.6), // gated: commit key
        Action(kind: "wait", seconds: 0.2, confidence: 1.0),
    ]

    private let script: [Action]
    private var index = 0

    public init(script: [Action]? = nil) {
        self.script = script ?? DummyPolicy.defaultScript
    }

    public func next(observation: Observation, step: Int, history: [StepRecord]) -> Action? {
        guard index < script.count else { return nil }
        defer { index += 1 }
        return script[index]
    }
}

public enum PolicyError: Error, CustomStringConvertible {
    case unknown(String)

    public var description: String {
        switch self {
        case .unknown(let name):
            return "unknown policy '\(name)' (available: dummy — see README for adding model policies)"
        }
    }
}

/// Registry of available policies. Model policies get added here later.
public func loadPolicy(named name: String) throws -> Policy {
    switch name {
    case "dummy": return DummyPolicy()
    default: throw PolicyError.unknown(name)
    }
}
