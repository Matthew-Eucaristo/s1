import Foundation

/// One gated step put to the user: "this needs you — go ahead?". Only
/// verdicts the gate marks confirmable get here (`SafetyGate.assess`); a
/// "yes" lets exactly this one action run.
public struct ConfirmRequest: Sendable {
    public var action: Action
    /// Why the gate stopped it ("“File › Move to Trash” can't be undone").
    public var reason: String
    /// The app the step acts in, when known.
    public var app: String?

    public init(action: Action, reason: String, app: String? = nil) {
        self.action = action; self.reason = reason; self.app = app
    }

    /// The step in plain words, for a log line or the spoken question.
    public var summary: String {
        switch action {
        case .menuItem(let p): return "choose \(p.joined(separator: " › "))"
        case .keyCombo(let k): return "press \(k.joined(separator: "+"))"
        case .typeText(let t): return "type “\(t.prefix(60))”"
        case .shell(let c): return "run `\(c.prefix(60))`"
        case .axPress(let r): return "press \(r)"
        case .mcpCall(let s, let t, let a): return "use \(t) from \(s) with \(a.prefix(80))"
        default: return LLMDecisionCodec.describe(action)
        }
    }
}

/// Asks the user and returns their answer. Must return false on timeout and
/// when cancelled — silence is never a yes.
public typealias ConfirmHandler = @Sendable (ConfirmRequest) async -> Bool

public enum Confirmation {
    /// How long a question waits before it counts as "no".
    public static let timeout: TimeInterval = 30

    /// A spoken or typed answer: true = yes, false = no, nil = unclear.
    /// Any "no" word wins ("don't do it", "nggak usah"); a yes must be
    /// nothing but yes words ("yes please", "ya boleh"), so a sentence that
    /// merely contains "yes" isn't taken as one.
    public static func answer(_ text: String) -> Bool? {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && $0 != "'" })
            .map(String.init)
            .filter { !filler.contains($0) }
        guard !words.isEmpty else { return nil }
        if words.contains(where: no.contains) { return false }
        if words.allSatisfy(yes.contains) { return true }
        return nil
    }

    static let yes: Set<String> = [
        "y", "yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go", "ahead", "do", "it", "allow", "confirm", "continue",
        "ya", "iya", "yoi", "boleh", "lanjut", "lanjutkan", "silakan", "gas", "oke", "setuju",
    ]
    static let no: Set<String> = [
        "n", "no", "nope", "nah", "don't", "dont", "cancel", "stop", "deny", "never",
        "tidak", "nggak", "ngga", "gak", "ga", "enggak", "jangan", "batal", "batalkan", "tolak", "usah",
    ]
    static let filler: Set<String> = ["please", "s", "tolong", "aja", "saja", "deh", "dong", "sih", "one"]

    /// Wait for `ask`, but at most `timeout`: no answer is a no.
    public static func bounded(_ timeout: TimeInterval = Confirmation.timeout,
                               _ ask: @escaping @Sendable () async -> Bool) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await ask() }
            group.addTask {
                try? await Task.sleep(for: .seconds(timeout))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}
