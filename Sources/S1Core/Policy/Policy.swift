import Foundation

/// What a brain hands back. `action == nil` means "I don't know" — the loop
/// treats that the same as confidence below threshold: escalate.
public struct Decision: Codable, Sendable {
    public var action: Action?
    public var confidence: Double
    public var rationale: String
    /// Raw model reply, when the policy is LLM-backed — part of the evidence trail.
    public var rawReply: String?

    public init(action: Action?, confidence: Double, rationale: String, rawReply: String? = nil) {
        self.action = action
        self.confidence = confidence
        self.rationale = rationale
        self.rawReply = rawReply
    }
}

/// System 1 is a protocol, not a model. Swap implementations freely —
/// dummy, scripted, deterministic AX, local VLM — without touching the loop.
public protocol Policy: Sendable {
    var name: String { get }
    /// True → the loop attaches a screenshot to every observation for this
    /// policy (VLM brains). AX-first policies keep this false and stay cheap.
    var wantsScreenshot: Bool { get }
    /// False for exact, rule-based brains (the AX grammar): their parse IS
    /// the decision, so a statistical judge must not second-guess it.
    var judgeable: Bool { get }
    func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision
}

public extension Policy {
    var wantsScreenshot: Bool { false }
    var judgeable: Bool { true }
}

/// System 2: the escalation brain (LLM, local or cloud). P2 wires real
/// providers; the protocol is fixed now so escalation logging already works.
public protocol Reasoner: Sendable {
    var name: String { get }
    func decide(observation: Snapshot, goal: String, history: [StepRecord], reason: String) async throws -> Decision
}

/// Placeholder policy that always abstains — drives escalation paths in tests.
public struct DummyPolicy: Policy {
    public let name = "dummy"
    public var confidence: Double
    public init(confidence: Double = 0.0) { self.confidence = confidence }
    public func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        Decision(action: nil, confidence: confidence, rationale: "dummy policy abstains")
    }
}

/// Replays a fixed plan — the honest way to exercise the real harness before
/// any model exists (P1). Plan entries are consumed in step order.
public struct ScriptedPolicy: Policy {
    public let name = "scripted"
    public struct Step: Codable, Sendable {
        public var action: Action
        public var confidence: Double
        public var rationale: String
        public init(action: Action, confidence: Double = 1.0, rationale: String = "scripted") {
            self.action = action; self.confidence = confidence; self.rationale = rationale
        }
        /// Hand-written plans shouldn't have to repeat defaults — confidence
        /// and rationale decode to 1.0/"scripted" when omitted.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            action = try c.decode(Action.self, forKey: .action)
            confidence = try c.decodeIfPresent(Double.self, forKey: .confidence) ?? 1.0
            rationale = try c.decodeIfPresent(String.self, forKey: .rationale) ?? "scripted"
        }
    }
    public var steps: [Step]

    public init(steps: [Step]) { self.steps = steps }

    public init(planJSON: Data) throws {
        steps = try JSONDecoder().decode([Step].self, from: planJSON)
    }

    public func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        let idx = history.count
        guard idx < steps.count else {
            return Decision(action: .done(summary: "plan exhausted"), confidence: 1.0, rationale: "end of script")
        }
        let s = steps[idx]
        return Decision(action: s.action, confidence: s.confidence, rationale: s.rationale)
    }
}
