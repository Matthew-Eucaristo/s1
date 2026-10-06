import Foundation

/// Why the Reasoner (System 2) couldn't answer, read back from a step's
/// rationale ("s2 error: …"). Lets the app say "usage limit" instead of a
/// generic "couldn't work out how".
public enum ReasonerFailure: Sendable, Equatable {
    case usageLimit
    case badKey
    case unreachable
    case other(String)

    static let prefix = "s2 error: "

    public init?(rationale: String) {
        guard rationale.hasPrefix(Self.prefix) else { return nil }
        let m = rationale.lowercased()
        if m.contains(" 429") || m.contains("usage limit") || m.contains("rate limit") || m.contains("quota") {
            self = .usageLimit
        } else if m.contains(" 401") || m.contains(" 403") || m.contains("api key") || m.contains("unauthorized") {
            self = .badKey
        } else if m.contains("timed out") || m.contains("offline") || m.contains("could not connect")
                    || m.contains("network connection") || m.contains("hostname") {
            self = .unreachable
        } else {
            self = .other(String(rationale.dropFirst(Self.prefix.count).prefix(160)))
        }
    }

    /// The last Reasoner failure in a run, if that's how it ended.
    public static func last(in steps: [StepRecord]) -> ReasonerFailure? {
        steps.reversed().lazy.compactMap { $0.rationale.flatMap(ReasonerFailure.init(rationale:)) }.first
    }
}
