import Foundation

/// OpenTelemetry traces (OTLP/HTTP, JSON) — off unless asked for:
/// `telemetry.endpoint` in config.json, or `S1_OTEL=on` together with the
/// standard `OTEL_EXPORTER_OTLP_ENDPOINT` (and `OTEL_EXPORTER_OTLP_HEADERS`).
///
/// One trace per run, following the GenAI semantic conventions (still
/// "Development" upstream, so names may change): an `invoke_agent` span for
/// the run, an `execute_tool` span per step, a `chat` span per model call.
/// Only names, numbers and statuses leave the Mac — goal text, actions and
/// outcomes only with `telemetry.content: true`.
public enum Telemetry {
    public struct Settings: Sendable, Equatable {
        public var endpoint: URL
        public var headers: [String: String]
        public var content: Bool
    }

    public static func settings(_ cfg: S1Config = .load(),
                                env: [String: String] = ProcessInfo.processInfo.environment) -> Settings? {
        if let t = cfg.telemetry, let e = t.endpoint, !e.isEmpty, let url = traces(e) {
            return Settings(endpoint: url, headers: t.headers ?? [:], content: t.content ?? false)
        }
        guard let on = env["S1_OTEL"]?.lowercased(), ["1", "on", "true", "yes"].contains(on),
              let e = env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] ?? env["OTEL_EXPORTER_OTLP_ENDPOINT"],
              let url = env["OTEL_EXPORTER_OTLP_TRACES_ENDPOINT"] != nil ? URL(string: e) : traces(e) else { return nil }
        // "k1=v1,k2=v2", the variable's standard form.
        var headers: [String: String] = [:]
        for pair in (env["OTEL_EXPORTER_OTLP_HEADERS"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { headers[kv[0]] = kv[1].removingPercentEncoding ?? kv[1] }
        }
        return Settings(endpoint: url, headers: headers, content: false)
    }

    /// Base endpoint → its traces path.
    static func traces(_ base: String) -> URL? {
        let b = base.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        return URL(string: b.hasSuffix("/v1/traces") ? b : b + "/v1/traces")
    }

    // MARK: - spans

    struct Span: Sendable {
        var traceID: String, spanID: String, parentID: String?
        var name: String, kind: Int
        var start: Date, end: Date
        var attributes: [(String, Attr)]
        var ok: Bool
    }

    enum Attr: Sendable {
        case string(String), int(Int), double(Double), bool(Bool)
        var json: [String: Any] {
            switch self {
            case .string(let s): ["stringValue": s]
            case .int(let i): ["intValue": String(i)]
            case .double(let d): ["doubleValue": d]
            case .bool(let b): ["boolValue": b]
            }
        }
    }

    /// The run a model call belongs to (set around a run).
    public struct RunContext: Sendable {
        let traceID: String, spanID: String
        let settings: Settings
        let started: Date
        let calls = Locked<[Span]>([])
    }
    @TaskLocal public static var current: RunContext?

    static func hex(_ bytes: Int) -> String {
        (0 ..< bytes).map { _ in String(format: "%02x", UInt8.random(in: 0 ... 255)) }.joined()
    }

    /// A context for one run, or nil when export is off.
    public static func begin(settings: Settings? = Telemetry.settings()) -> RunContext? {
        settings.map { RunContext(traceID: hex(16), spanID: hex(8), settings: $0, started: Date()) }
    }

    /// End a run: its span, a span per logged step, and the model calls made
    /// during it, sent in one export.
    public static func end(_ ctx: RunContext?, goal: String, report: RunReport, steps: [StepRecord]) {
        guard let ctx else { return }
        var spans: [Span] = []
        var attrs: [(String, Attr)] = [
            ("gen_ai.operation.name", .string("invoke_agent")), ("gen_ai.agent.name", .string("s1")),
            ("s1.run.status", .string(report.status.rawValue)), ("s1.run.steps", .int(report.steps)),
            ("s1.run.escalations", .int(report.escalations)),
        ]
        if ctx.settings.content { attrs.append(("s1.goal", .string(goal))) }
        spans.append(Span(traceID: ctx.traceID, spanID: ctx.spanID, parentID: nil, name: "invoke_agent s1",
                          kind: 1, start: ctx.started, end: Date(), attributes: attrs,
                          ok: report.status == .done))
        var prev = ctx.started
        for r in steps {
            let tool = r.action.map(Self.toolName) ?? "none"
            var a: [(String, Attr)] = [
                ("gen_ai.operation.name", .string("execute_tool")), ("gen_ai.tool.name", .string(tool)),
                ("s1.step.index", .int(r.index)), ("s1.step.decided_by", .string(r.decidedBy)),
                ("s1.step.gate", .string(r.gate.split(separator: "(").first.map(String.init) ?? r.gate)),
            ]
            if let c = r.confidence { a.append(("s1.step.confidence", .double(c))) }
            if ctx.settings.content {
                if let act = r.action { a.append(("s1.step.action", .string(LLMDecisionCodec.describe(act)))) }
                if let o = r.outcome { a.append(("s1.step.outcome", .string(String(o.prefix(500))))) }
            }
            let failed = r.outcome?.hasPrefix("error:") == true || r.gate.hasPrefix("deny")
            spans.append(Span(traceID: ctx.traceID, spanID: hex(8), parentID: ctx.spanID,
                              name: "execute_tool \(tool)", kind: 1, start: min(prev, r.time), end: r.time,
                              attributes: a, ok: !failed))
            prev = r.time
        }
        spans += ctx.calls.value
        export(spans, to: ctx.settings)
    }

    /// One model call (from the usage log): a child of the current run, or
    /// a trace of its own outside one.
    static func modelCall(_ r: UsageRecord) {
        let ctx = current
        guard let settings = ctx?.settings ?? Telemetry.settings() else { return }
        var a: [(String, Attr)] = [
            ("gen_ai.operation.name", .string("chat")), ("gen_ai.request.model", .string(r.model)),
            ("server.address", .string(r.host)), ("s1.model.role", .string(r.role)),
        ]
        if let m = r.served { a.append(("gen_ai.response.model", .string(m))) }
        if let i = r.input { a.append(("gen_ai.usage.input_tokens", .int(i))) }
        if let o = r.output { a.append(("gen_ai.usage.output_tokens", .int(o))) }
        if let e = r.error { a.append(("error.type", .string(String(e.prefix(120))))) }
        let span = Span(traceID: ctx?.traceID ?? hex(16), spanID: hex(8), parentID: ctx?.spanID,
                        name: "chat \(r.model)", kind: 3,
                        start: r.ts.addingTimeInterval(-Double(r.ms) / 1000), end: r.ts,
                        attributes: a, ok: r.ok)
        if let ctx { ctx.calls.withLock { $0.append(span) } } else { export([span], to: settings) }
    }

    static func toolName(_ a: Action) -> String {
        let s = String(describing: a)
        return String(s.prefix(while: { $0 != "(" }))
    }

    // MARK: - OTLP/HTTP JSON

    static func payload(_ spans: [Span]) -> [String: Any] {
        func nanos(_ d: Date) -> String { String(UInt64(max(0, d.timeIntervalSince1970) * 1_000_000_000)) }
        let resource: [[String: Any]] = [
            ["key": "service.name", "value": ["stringValue": "s1"]],
            ["key": "service.version", "value": ["stringValue": S1Info.version]],
        ]
        let list: [[String: Any]] = spans.map { s in
            var o: [String: Any] = [
                "traceId": s.traceID, "spanId": s.spanID, "name": s.name, "kind": s.kind,
                "startTimeUnixNano": nanos(s.start), "endTimeUnixNano": nanos(max(s.end, s.start)),
                "attributes": s.attributes.map { ["key": $0.0, "value": $0.1.json] },
                "status": ["code": s.ok ? 1 : 2],
            ]
            if let p = s.parentID { o["parentSpanId"] = p }
            return o
        }
        return ["resourceSpans": [[
            "resource": ["attributes": resource],
            "scopeSpans": [["scope": ["name": "s1", "version": S1Info.version], "spans": list]],
        ]]]
    }

    static func export(_ spans: [Span], to s: Settings) {
        guard !spans.isEmpty, let body = try? JSONSerialization.data(withJSONObject: payload(spans)) else { return }
        var req = URLRequest(url: s.endpoint)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in s.headers { req.setValue(v, forHTTPHeaderField: k) }
        req.httpBody = body
        // Best effort: a collector that's down never slows or fails a run.
        Task.detached { _ = try? await URLSession.shared.data(for: req) }
    }
}
