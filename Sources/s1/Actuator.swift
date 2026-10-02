import Foundation

/// Backend that performs a *gated* action for real. macOS uses CGEvent
/// (`CGEventBackend`, see Mac/); tests inject a recording mock so the whole
/// loop is verifiable off-macOS.
public protocol ActionBackend {
    /// Performs the action and returns a short human-readable detail string.
    /// Throws on any execution failure.
    func perform(_ action: Action) throws -> String
}

/// Fails loudly with a clear message — used when no platform backend exists
/// (e.g. running on Linux).
public struct UnavailableBackend: ActionBackend {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func perform(_ action: Action) throws -> String {
        throw BackendError.unavailable(reason)
    }
}

public enum BackendError: Error, CustomStringConvertible {
    case unavailable(String)
    case unsupported(String)
    case badAction(String)

    public var description: String {
        switch self {
        case .unavailable(let message): return "backend unavailable: \(message)"
        case .unsupported(let kind): return "no backend handler for action kind '\(kind)'"
        case .badAction(let message): return "invalid action: \(message)"
        }
    }
}

/// The gate + execution pair produced for one action. Keeping both together
/// guarantees the log records the exact decision that was applied.
public struct Execution: Equatable {
    public let gate: GateDecision
    public let result: ActionResult

    public init(gate: GateDecision, result: ActionResult) {
        self.gate = gate
        self.result = result
    }
}

/// Applies the gate, then either executes, skips (dry-run), or records the
/// rejection. Never throws — failures become an `.error` result so the loop
/// can log them and keep going.
public final class Actuator {
    public let dryRun: Bool
    public let allowDestructive: Bool
    private let backend: ActionBackend

    public init(dryRun: Bool = false, allowDestructive: Bool = false, backend: ActionBackend? = nil) {
        self.dryRun = dryRun
        self.allowDestructive = allowDestructive
        self.backend = backend ?? UnavailableBackend(reason: "no action backend configured")
    }

    public func execute(_ action: Action) -> Execution {
        let decision = ActionGate.decide(action, allowDestructive: allowDestructive)

        guard decision.allowed else {
            return Execution(gate: decision,
                             result: ActionResult(status: .rejected, detail: decision.reason))
        }
        if dryRun {
            return Execution(gate: decision,
                             result: ActionResult(status: .dryRun, detail: "not executed (dry-run)"))
        }
        do {
            if action.kind == "wait" {
                let seconds = action.seconds ?? 0.5
                Thread.sleep(forTimeInterval: seconds)
                return Execution(gate: decision,
                                 result: ActionResult(status: .executed, detail: "waited \(seconds)s"))
            }
            let detail = try backend.perform(action)
            return Execution(gate: decision,
                             result: ActionResult(status: .executed, detail: detail))
        } catch {
            return Execution(gate: decision,
                             result: ActionResult(status: .error, detail: "\(error)"))
        }
    }
}
