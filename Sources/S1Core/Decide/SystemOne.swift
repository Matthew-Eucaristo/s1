import CoreGraphics
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
    /// Screenshots go along with each question — set from the catalog and
    /// the "share the screen" switch, else guessed from the model name.
    public var acceptsImages: Bool
    /// Clef / Clef Flash (Cloudflare) and Liquid d1 accept `images`.
    public static func acceptsImages(model: String) -> Bool {
        let m = model.lowercased()
        // d1's free tier is text-only ("does not accept images").
        if m.hasSuffix(":free") { return false }
        return m.contains("clef") || m == "d1" || m.hasPrefix("d1:") || m.hasPrefix("d1-")
    }

    public init(endpoint: Endpoint, timeout: TimeInterval = 30, images: Bool? = nil) {
        self.endpoint = endpoint
        self.timeout = timeout
        self.acceptsImages = images ?? Self.acceptsImages(model: endpoint.model)
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

    /// Images as each server wants them: Liquid takes `data:` URLs; Ollama and
    /// Workers AI take bare base64 (what `ScreenImage` produces).
    static func wire(_ images: [String], for url: URL) -> [String] {
        guard url.host?.hasSuffix("liquid.ai") == true else { return images }
        return images.map { $0.hasPrefix("data:") ? $0 : "data:image/jpeg;base64,\($0)" }
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
        do {
            return try await send(state: state, questions: questions, images: images)
        } catch let e as S1Error where !images.isEmpty && acceptsImages
                    && "\(e)".lowercased().contains("accept images") {
            // The model turned out to be text-only: answer from the AX state.
            return try await send(state: state, questions: questions, images: [])
        }
    }

    private func send(state: JSONValue, questions: [String: DecisionQuestion],
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
                                     images: acceptsImages ? Self.wire(images, for: url) : [])
        let started = Date()
        let host = url.host ?? endpoint.baseURL
        func record(_ ok: Bool, _ r: DecisionResult? = nil, error: String? = nil) {
            UsageLog.append(UsageRecord(role: "judge", host: host, model: endpoint.model,
                served: r?.model, input: r?.usage?.input_tokens, output: r?.usage?.output_tokens,
                ms: Int(Date().timeIntervalSince(started) * 1000), ok: ok,
                error: error.map(UsageLog.scrub)))
        }
        let data: Data, resp: URLResponse
        do { (data, resp) = try await URLSession.shared.data(for: req) }
        catch {
            DebugTrace.http(role: "judge", url: url, status: 0, ms: Int(Date().timeIntervalSince(started) * 1000),
                            request: req.httpBody, response: nil, error: error.localizedDescription)
            record(false, error: error.localizedDescription); throw error
        }
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        DebugTrace.http(role: "judge", url: url, status: code, ms: Int(Date().timeIntervalSince(started) * 1000),
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

/// The Judge (System 1's model) in front of the grammar. The grammar proposes;
/// the Judge looks where it adds something and stays out of the way where
/// the grammar is exact:
/// - several controls could be meant → it picks one (`choice`), seeing the
///   screen when it reads images;
/// - the grammar is unsure (fuzzy match) → it scores the step;
/// - the run says it's done after touching the UI → it checks the goal
///   really happened.
/// It can only make a step MORE cautious: a low score lowers confidence,
/// which the loop routes to the Reasoner. The safety gate runs after it.
public struct JudgedPolicy: Policy {
    public var inner: any Policy
    public var judge: any DecisionJudge
    /// Probability under which the judge overrides the policy's confidence.
    public var vetoBelow: Double
    /// The screen for a judge that reads images, taken only when it looks.
    public var capture: @Sendable () async -> String?

    /// Grammar decisions at or above this are exact; the judge skips them.
    static let sureAbove = 0.9

    public init(inner: any Policy, judge: any DecisionJudge, vetoBelow: Double = 0.3,
                capture: @escaping @Sendable () async -> String? = {
                    (try? await SystemPerceiver.captureScreen()).flatMap { ScreenImage.downscaledJPEG($0) }
                }) {
        self.inner = inner
        self.judge = judge
        self.vetoBelow = vetoBelow
        self.capture = capture
    }

    public var name: String { inner.name }
    public var wantsScreenshot: Bool { inner.wantsScreenshot }
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

    /// Runs whose "done" deserves a second look: a step whose result depends
    /// on the screen (not a launch or a key), or one that failed or didn't
    /// verify. The Judge reads every step's outcome in `history`.
    static func touchedUI(_ history: [StepRecord]) -> Bool {
        history.contains { r in
            if r.verified == false { return true }
            if let o = r.outcome, o.hasPrefix("error:") || o.hasPrefix("blocked:") { return true }
            switch r.action {
            case .click?, .doubleClick?, .rightClick?, .drag?, .axPress?, .axSetValue?, .typeText?: return true
            default: return false
            }
        }
    }

    public func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        var d = try await inner.decide(observation: observation, goal: goal, history: history)
        if d.action == nil, let words = d.explore {
            // The grammar knows it's a click but not on what: look for it.
            let images = await screen(observation)
            if let found = try? await explore(words, base: d, goal: goal, observation: observation,
                                               history: history, images: images) {
                return found
            }
            return d
        }
        guard let action = d.action else { return d }
        let isDone: Bool = { if case .done = action { return true }; return false }()
        // One candidate is a real question too: with "none of these" beside it.
        let options = (d.options?.isEmpty == false) ? d.options : nil
        guard inner.judgeable || options != nil || d.confidence < Self.sureAbove
                || (isDone && Self.touchedUI(history)) else { return d }

        let images = await screen(observation)
        do {
            if let options {
                try await pick(options, for: &d, goal: goal, observation: observation,
                               history: history, images: images)
            } else {
                let state = DecisionContext.state(goal: goal, observation: observation,
                                                  history: history, proposed: action)
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
            }
        } catch {
            // Judge down = no extra signal; the policy's own decision stands.
            d.rationale += " · judge unavailable"
        }
        return d
    }

    /// The screen, for a Judge that reads images — taken only when it looks.
    func screen(_ observation: Snapshot) async -> [String] {
        guard judge.acceptsImages else { return [] }
        if let path = observation.screenshotPath, let jpeg = ScreenImage.downscaledJPEG(path: path) {
            return [jpeg]
        }
        return await capture().map { [$0] } ?? []
    }

    static let noneOption = "none of these"

    /// The grammar's candidates as a distribution: the Judge chooses one, or
    /// says none fits. A confident choice among the grammar's own candidates
    /// may carry the step (capped below exact grammar hits); "none" or a
    /// flat answer hands it to the Reasoner.
    private func pick(_ options: [Decision.Option], for d: inout Decision, goal: String,
                      observation: Snapshot, history: [StepRecord], images: [String]) async throws {
        let keys = options.enumerated().map { "\($0.offset + 1). \($0.element.label)" }
        guard let answer = try await choose(
            "Which of these controls on the `current` screen should be used next for `goal`?",
            among: keys, observation: observation, goal: goal, history: history, images: images) else { return }
        guard let i = answer.index else {
            d.confidence = min(d.confidence, 0.2)
            d.rationale += " · judge \(judge.model): none of the candidates fits"
            return
        }
        let p = answer.p
        d.action = options[i].action
        d.rationale += String(format: " · judge %@ picked %d/%d p=%.2f", judge.model, i + 1, options.count, p)
        d.confidence = p < vetoBelow ? min(d.confidence, p) : max(d.confidence, min(p, Self.pickedCap))
    }

    /// A Judge's choice can carry a step this far — never as sure as an exact match.
    static let pickedCap = 0.85

    /// One `choice` question over `keys` plus "none of these": the chosen
    /// index (nil = none fits) and its probability; nil when the Judge gave
    /// no usable answer.
    func choose(_ question: String, among keys: [String], observation: Snapshot, goal: String,
                history: [StepRecord], images: [String]) async throws -> (index: Int?, p: Double)? {
        var criteria = Dictionary(uniqueKeysWithValues: keys.map { ($0, String?.none) })
        criteria[Self.noneOption] = "What `goal` refers to is not in this list"
        let state = DecisionContext.state(goal: goal, observation: observation, history: history)
        let r = try await judge.evaluate(state: state, questions: ["target": .choice(question, options: criteria)],
                                         images: images)
        guard let ans = r.answers["target"], let chosen = ans.choice else { return nil }
        let p = ans.probabilities?[chosen] ?? ans.confidence ?? 1
        if chosen == Self.noneOption { return (nil, p) }
        guard let i = keys.firstIndex(of: chosen) else { return nil }
        return (i, p)
    }
}

public extension JudgedPolicy {
    /// Wrap `policy` with the configured decision judge; unchanged when no
    /// decision model is configured.
    static func wrapIfConfigured(_ policy: any Policy,
                                 endpoint: Endpoint? = Models.endpoint(.judge),
                                 images: Bool? = nil) -> any Policy {
        guard let ep = endpoint else { return policy }
        return JudgedPolicy(inner: policy, judge: SystemOneClient(endpoint: ep, images: images))
    }
}
