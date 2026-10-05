import Foundation

/// Any JSON value — the System One `state` and structured instructions.
public indirect enum JSONValue: Codable, Sendable, Equatable {
    case string(String), number(Double), bool(Bool), null
    case array([JSONValue]), object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .null: try c.encodeNil()
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        }
    }
}

/// A typed System One question — the three primitives shared by TypeSafe
/// Jev, Cloudflare Clef and Ollama's `/v1/systemone`.
public enum DecisionQuestion: Sendable, Encodable {
    /// Yes/no → probability of yes.
    case noul(String, yes: String? = nil, no: String? = nil)
    /// One of a set → chosen option + full distribution. Options map to a
    /// rubric description (nil = the option name says it all).
    case choice(String, options: [String: String?])
    /// Ordered levels → probability-weighted position (0 = first level).
    case score(String, levels: [String])

    private enum K: String, CodingKey { case type, instructions, criteria }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        switch self {
        case let .noul(q, yes, no):
            try c.encode("noul", forKey: .type)
            try c.encode(q, forKey: .instructions)
            if yes != nil || no != nil {
                var crit: [String: String] = [:]
                crit["true"] = yes
                crit["false"] = no
                try c.encode(crit, forKey: .criteria)
            }
        case let .choice(q, options):
            try c.encode("choice", forKey: .type)
            try c.encode(q, forKey: .instructions)
            try c.encode(options.mapValues { $0.map(JSONValue.string) ?? .null }, forKey: .criteria)
        case let .score(q, levels):
            try c.encode("score", forKey: .type)
            try c.encode(q, forKey: .instructions)
            try c.encode(levels, forKey: .criteria)
        }
    }
}

public struct DecisionAnswer: Codable, Sendable, Equatable {
    public var type: String
    public var noul: Double?
    public var choice: String?
    public var score: Double?
    public var probabilities: [String: Double]?
    public var confidence: Double?
}

public struct DecisionResult: Codable, Sendable {
    public var model: String?
    public var answers: [String: DecisionAnswer]
    public var usage: DecisionUsage?

    public init(model: String? = nil, answers: [String: DecisionAnswer], usage: DecisionUsage? = nil) {
        self.model = model; self.answers = answers; self.usage = usage
    }
}

/// System One usage block (`input_tokens`/`output_tokens`; Jev bills input).
public struct DecisionUsage: Codable, Sendable, Equatable {
    public var input_tokens: Int?
    public var output_tokens: Int?
}

/// Anything that answers typed questions about a state.
public protocol DecisionJudge: Sendable {
    var model: String { get }
    /// Vision-capable decision models (Clef family) also get the screenshot.
    var acceptsImages: Bool { get }
    func evaluate(state: JSONValue, questions: [String: DecisionQuestion]) async throws -> DecisionResult
    func evaluate(state: JSONValue, questions: [String: DecisionQuestion],
                  images: [String]) async throws -> DecisionResult
}

public extension DecisionJudge {
    var acceptsImages: Bool { false }
    func evaluate(state: JSONValue, questions: [String: DecisionQuestion],
                  images: [String]) async throws -> DecisionResult {
        try await evaluate(state: state, questions: questions)
    }
}

/// HTTP client for the System One API (`POST …/v1/systemone`). One client
/// covers local Ollama (≥ 0.35: nimble, tev1, clef-flash, clef), hosted
/// TypeSafe Jev, and Cloudflare Workers AI Clef — they share the wire shape.
public struct SystemOneClient: DecisionJudge {
    public var endpoint: Endpoint
    public var timeout: TimeInterval
    public var model: String { endpoint.model }
    /// Clef / Clef Flash take base64 `images` (Ollama + Workers AI); Jev,
    /// nimble and tev1 are text-only.
    public var acceptsImages: Bool { Self.acceptsImages(model: endpoint.model) }
    public static func acceptsImages(model: String) -> Bool {
        model.lowercased().contains("clef")
    }

    public init(endpoint: Endpoint, timeout: TimeInterval = 30) {
        self.endpoint = endpoint
        self.timeout = timeout
    }

    /// Where requests go. Accepts a server root (`http://localhost:11434`,
    /// `https://api.typesafe.ai`), a root that already ends in `/v1`
    /// (what OpenAI-style configs carry), the full `/v1/systemone` URL, or a
    /// Cloudflare `…/ai/run/@cf/cloudflare/clef` model URL.
    public static func url(for base: String) -> URL? {
        let b = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if b.hasSuffix("/systemone") || b.contains("/ai/run/") { return URL(string: b) }
        if b.hasSuffix("/v1") { return URL(string: b + "/systemone") }
        return URL(string: b + "/v1/systemone")
    }

    public static func body(model: String, state: JSONValue,
                            questions: [String: DecisionQuestion],
                            images: [String] = []) throws -> Data {
        struct Body: Encodable {
            var model: String
            var state: JSONValue
            var questions: [String: DecisionQuestion]
            var images: [String]?
        }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return try enc.encode(Body(model: model, state: state, questions: questions,
                                   images: images.isEmpty ? nil : Array(images.prefix(4))))
    }

    /// Decode a reply — bare `{model, answers}` or Cloudflare's
    /// `{"result": {…}, "success": true}` envelope.
    public static func decode(_ data: Data) throws -> DecisionResult {
        let dec = JSONDecoder()
        if let r = try? dec.decode(DecisionResult.self, from: data) { return r }
        struct Envelope: Decodable { var result: DecisionResult }
        if let e = try? dec.decode(Envelope.self, from: data) { return e.result }
        let snippet = String(decoding: data.prefix(300), as: UTF8.self).terminalSafe
        throw S1Error.aborted("decision model reply not understood: \(snippet)")
    }

    public func evaluate(state: JSONValue, questions: [String: DecisionQuestion]) async throws -> DecisionResult {
        try await evaluate(state: state, questions: questions, images: [])
    }

    public func evaluate(state: JSONValue, questions: [String: DecisionQuestion],
                         images: [String]) async throws -> DecisionResult {
        guard let url = Self.url(for: endpoint.baseURL) else {
            throw S1Error.aborted("bad decision endpoint URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("s1/\(S1Info.version)", forHTTPHeaderField: "User-Agent")
        if let key = endpoint.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in endpoint.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = try Self.body(model: endpoint.model, state: state, questions: questions,
                                     images: acceptsImages ? images : [])
        let started = Date()
        let host = url.host ?? endpoint.baseURL
        func record(_ ok: Bool, _ r: DecisionResult? = nil, error: String? = nil) {
            UsageLog.append(UsageRecord(role: "s1-decision", host: host, model: endpoint.model,
                served: r?.model, input: r?.usage?.input_tokens, output: r?.usage?.output_tokens,
                ms: Int(Date().timeIntervalSince(started) * 1000), ok: ok,
                error: error.map(UsageLog.scrub)))
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch {
            DebugTrace.http(role: "s1-decision", url: url, status: 0, ms: Int(Date().timeIntervalSince(started) * 1000),
                            request: req.httpBody, response: nil, error: error.localizedDescription)
            record(false, error: error.localizedDescription); throw error
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        DebugTrace.http(role: "s1-decision", url: url, status: code, ms: Int(Date().timeIntervalSince(started) * 1000),
                        request: req.httpBody, response: data)
        guard code == 200 else {
            // Error bodies never carry our key — but keep them short.
            let snippet = String(decoding: data.prefix(200), as: UTF8.self).terminalSafe
            record(false, error: "HTTP \(code): \(snippet)")
            throw S1Error.aborted("decision model HTTP \(code): \(snippet)")
        }
        do {
            let r = try Self.decode(data)
            record(true, r)
            return r
        } catch { record(false, error: "undecodable reply"); throw error }
    }
}

/// The state a decision model sees: the goal, what is on screen NOW, and
/// what already happened this run. Bounded and value-free — control labels
/// only (no field contents), so documents and passwords never leave the Mac.
public enum DecisionContext {
    public static let maxControls = 40
    public static let maxHistory = 8

    public static func state(goal: String, observation: Snapshot, history: [StepRecord],
                             proposed: Action? = nil, recentGoals: [String] = []) -> JSONValue {
        var current: [String: JSONValue] = [
            "frontmost_app": .string(observation.frontmostApp ?? "none"),
            "password_field_focused": .bool(observation.secureTextFocused),
        ]
        let titles = observation.windows.compactMap(\.title).filter { !$0.isEmpty }.prefix(8)
        if !titles.isEmpty { current["window_titles"] = .array(titles.map { .string(clip($0)) }) }
        if let tree = observation.axTree {
            var seen = Set<String>()
            var controls: [JSONValue] = []
            for n in tree.flattened {
                guard let label = n.title ?? n.desc ?? n.help, !label.isEmpty else { continue }
                let role = n.role.replacingOccurrences(of: "AX", with: "")
                let item = "\(role): \(clip(label))"
                if seen.insert(item).inserted { controls.append(.string(item)) }
                if controls.count >= maxControls { break }
            }
            if !controls.isEmpty { current["visible_controls"] = .array(controls) }
        }
        let steps: [JSONValue] = history.suffix(maxHistory).map { r in
            var o: [String: JSONValue] = ["step": .number(Double(r.index)),
                                          "decided_by": .string(r.decidedBy)]
            if let a = r.action { o["action"] = .string(clip(String(describing: a), 160)) }
            if let out = r.outcome { o["outcome"] = .string(clip(out, 160)) }
            if let v = r.verified { o["verified"] = .bool(v) }
            if r.gate != "allow", r.gate != "-" { o["gate"] = .string(r.gate) }
            return .object(o)
        }
        var s: [String: JSONValue] = ["goal": .string(goal), "current": .object(current),
                                      "history": .array(steps)]
        if let p = proposed { s["proposed_action"] = .string(clip(String(describing: p), 200)) }
        if !recentGoals.isEmpty {
            s["earlier_goals"] = .array(recentGoals.prefix(5).map { .string(clip($0)) })
        }
        return .object(s)
    }

    private static func clip(_ s: String, _ n: Int = 80) -> String {
        let t = s.terminalSafe
        return t.count <= n ? t : String(t.prefix(n)) + "…"
    }
}

/// S1 decision judge in front of any policy: the policy proposes, a
/// System One model scores the proposal against the goal, the screen, and
/// the run so far. A low score lowers the step's confidence, which the
/// loop already routes to S2 (or suppresses). It can only make a step MORE
/// cautious — the safety gate still runs after it, unchanged.
public struct JudgedPolicy: Policy {
    public var inner: any Policy
    public var judge: any DecisionJudge
    /// Probability under which the judge overrides the policy's confidence.
    public var vetoBelow: Double

    public init(inner: any Policy, judge: any DecisionJudge, vetoBelow: Double = 0.3) {
        self.inner = inner
        self.judge = judge
        self.vetoBelow = vetoBelow
    }

    public var name: String { inner.name }
    public var wantsScreenshot: Bool { inner.wantsScreenshot || judge.acceptsImages }
    public var judgeable: Bool { inner.judgeable }

    static let questions: [String: DecisionQuestion] = [
        "advances": .noul(
            "Given the `current` screen and the `history` of this run, does `proposed_action` move the user toward `goal`?",
            yes: "The action is a sensible next step for the goal right now",
            no: "The action is wrong, premature, or unrelated to the goal"),
        "repeats_failure": .noul(
            "Does `proposed_action` repeat a step from `history` that already failed or did not verify?"),
    ]
    static let doneQuestions: [String: DecisionQuestion] = [
        "advances": .noul(
            "Given the `current` screen and the `history` of this run, has `goal` actually been accomplished?",
            yes: "Every part of the goal is done", no: "Some part of the goal is still undone"),
    ]

    public func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        var d = try await inner.decide(observation: observation, goal: goal, history: history)
        guard inner.judgeable, let action = d.action else { return d }
        let isDone: Bool = { if case .done = action { return true }; return false }()
        let state = DecisionContext.state(goal: goal, observation: observation,
                                          history: history, proposed: action)
        do {
            // Vision judges see the same downscaled frame the VLM would.
            let images = judge.acceptsImages
                ? observation.screenshotPath.flatMap { VLMPolicy.downscaledJPEG(path: $0) }.map { [$0] } ?? []
                : []
            let r = try await judge.evaluate(state: state,
                                             questions: isDone ? Self.doneQuestions : Self.questions,
                                             images: images)
            var p = r.answers["advances"]?.noul ?? 1
            if let rep = r.answers["repeats_failure"]?.noul, rep > 0.7 { p = min(p, 1 - rep) }
            let tag = String(format: "judge %@ p=%.2f", judge.model, p)
            if p < vetoBelow {
                d.confidence = min(d.confidence, p)
                d.rationale += " · \(tag) → low"
            } else {
                d.rationale += " · \(tag)"
            }
        } catch {
            // Judge down = no extra signal; the policy's own decision stands.
            d.rationale += " · judge unavailable"
        }
        return d
    }
}

public extension JudgedPolicy {
    /// Wrap `policy` with the configured decision judge; unchanged when no
    /// decision model is configured.
    static func wrapIfConfigured(_ policy: any Policy,
                                 endpoint: Endpoint? = Endpoints.decision()) -> any Policy {
        guard let ep = endpoint else { return policy }
        return JudgedPolicy(inner: policy, judge: SystemOneClient(endpoint: ep))
    }
}
