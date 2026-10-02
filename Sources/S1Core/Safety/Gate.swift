import Foundation

public enum GateVerdict: Sendable, Equatable {
    case allow
    case deny(reason: String)
    /// Irreversible or denylisted: the loop must stop and ask a human.
    case needsHuman(reason: String)

    var label: String {
        switch self {
        case .allow: return "allow"
        case .deny(let r): return "deny(\(r))"
        case .needsHuman(let r): return "needsHuman(\(r))"
        }
    }
}

/// Classifies every action before it executes. Deny-list is hard: no policy
/// flag can override it — the step is escalated to a human instead.
public struct SafetyGate: Sendable {
    public var allowReversible: Bool
    public var allowIrreversible: Bool

    /// Patterns that always route to a human, even in `--allow-irreversible`
    /// runs: credentials, purchases, outbound messages.
    public static let denyPatterns: [(regex: String, why: String)] = [
        (#"(?i)\b(password|passwd|passcode|pin|otp|2fa|totp|cvc|cvv|security code|card number|kartu|sandi)\b"#,
         "credential-like content"),
        (#"(?i)\b(buy now|purchase|checkout|place order|konfirmasi pembayaran|bayar sekarang)\b"#,
         "possible purchase"),
        (#"(?i)\b(rm\s+-rf|mkfs|dd\s+if=|:(){ :\|:& };:)\b"#,
         "destructive shell"),
    ]

    public init(allowReversible: Bool = true, allowIrreversible: Bool = false) {
        self.allowReversible = allowReversible
        self.allowIrreversible = allowIrreversible
    }

    public func evaluate(_ action: Action) -> GateVerdict {
        // Deny-list first: it applies to every class.
        for payload in action.textPayloads {
            for rule in Self.denyPatterns {
                if payload.range(of: rule.regex, options: .regularExpression) != nil {
                    return .needsHuman(reason: "denylist: \(rule.why)")
                }
            }
        }
        switch action.actionClass {
        case .read:
            return .allow
        case .reversible:
            return allowReversible ? .allow : .deny(reason: "reversible actions disabled")
        case .irreversible:
            return allowIrreversible
                ? .needsHuman(reason: "irreversible requires human confirmation")
                : .deny(reason: "irreversible not allowed (pass --allow-irreversible to queue for confirmation)")
        }
    }
}
