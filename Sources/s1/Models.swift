import Foundation

// MARK: - Timestamp

/// UTC ISO-8601 timestamps with milliseconds — what every log line carries.
public enum Timestamp {
    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS'Z'"
        return formatter
    }()

    public static func nowISO() -> String {
        formatter.string(from: Date())
    }
}

// MARK: - Action

/// One action the harness can take.
///
/// `kind` is a plain string on purpose: actions will later be produced by
/// models as JSON, and an unknown kind must decode and then be *rejected by
/// the gate* (fail closed) rather than crash the decode.
public struct Action: Codable, Equatable {
    public var kind: String
    public var x: Double?
    public var y: Double?
    public var text: String?
    public var key: String?
    public var modifiers: [String]?
    public var keys: [String]?
    public var dx: Double?
    public var dy: Double?
    public var seconds: Double?
    /// Policy confidence in this action, 0...1. Logged for audit; the future
    /// System 2 escalation keys off this.
    public var confidence: Double?
    /// Lets a policy force-mark an action as destructive for risks the gate
    /// cannot infer from the action alone (e.g. clicking a "Buy" button).
    public var destructive: Bool?
    /// Free-form policy note, kept in the audit log.
    public var note: String?

    public init(kind: String, x: Double? = nil, y: Double? = nil, text: String? = nil,
                key: String? = nil, modifiers: [String]? = nil, keys: [String]? = nil,
                dx: Double? = nil, dy: Double? = nil, seconds: Double? = nil,
                confidence: Double? = nil, destructive: Bool? = nil, note: String? = nil) {
        self.kind = kind
        self.x = x
        self.y = y
        self.text = text
        self.key = key
        self.modifiers = modifiers
        self.keys = keys
        self.dx = dx
        self.dy = dy
        self.seconds = seconds
        self.confidence = confidence
        self.destructive = destructive
        self.note = note
    }
}

// MARK: - Observation

/// Snapshot of the machine at one point in time. Individual perception
/// failures are recorded in `errors` instead of thrown, so the loop keeps
/// running and the log stays honest about what was unavailable.
public struct Observation: Codable, Equatable {
    public var ts: String
    public var screenshot: String?
    public var windowCount: Int?
    public var windowTitles: [String]
    public var axFocusedApp: String?
    public var errors: [String]

    public init(ts: String, screenshot: String? = nil, windowCount: Int? = nil,
                windowTitles: [String] = [], axFocusedApp: String? = nil, errors: [String] = []) {
        self.ts = ts
        self.screenshot = screenshot
        self.windowCount = windowCount
        self.windowTitles = windowTitles
        self.axFocusedApp = axFocusedApp
        self.errors = errors
    }
}

// MARK: - Gate / result

public enum Risk: String, Codable {
    case safe
    case destructive
    case unknown
}

public struct GateDecision: Codable, Equatable {
    public let allowed: Bool
    public let risk: Risk
    public let reason: String

    public init(allowed: Bool, risk: Risk, reason: String) {
        self.allowed = allowed
        self.risk = risk
        self.reason = reason
    }
}

public struct ActionResult: Codable, Equatable {
    public enum Status: String, Codable {
        case executed
        case rejected
        case dryRun = "dry_run"
        case error
    }

    public let status: Status
    public let detail: String

    public init(status: Status, detail: String) {
        self.status = status
        self.detail = detail
    }
}

// MARK: - Step record

/// One full turn of the loop, exactly as written to `run/steps.jsonl`.
public struct StepRecord: Codable, Equatable {
    public var ts: String
    public var step: Int
    public var observation: Observation
    public var action: Action
    public var gate: GateDecision
    public var result: ActionResult
    public var confidence: Double?

    public init(ts: String, step: Int, observation: Observation, action: Action,
                gate: GateDecision, result: ActionResult, confidence: Double?) {
        self.ts = ts
        self.step = step
        self.observation = observation
        self.action = action
        self.gate = gate
        self.result = result
        self.confidence = confidence
    }
}
