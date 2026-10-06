import Foundation

/// What a model call cost, as exactly as s1 can know it:
/// 1. **billed**: the provider reported the charge (OpenRouter `usage.cost`);
/// 2. **plan**: a flat subscription (OpenCode Go) — nothing per call;
/// 3. **free**: on this Mac (Ollama, LM Studio) or a `:free` model;
/// 4. **estimated**: tokens × the public list price from OpenRouter's catalog;
/// 5. **unknown**: no price to go on.
public enum Billing: String, Sendable, CaseIterable {
    case billed, estimated, plan, free, unknown
}

/// USD per token, as OpenRouter publishes them.
public struct Price: Codable, Sendable, Equatable {
    public var input: Double
    public var output: Double
    public var cacheRead: Double?
    public var cacheWrite: Double?
    public var webSearch: Double?
}

public enum Pricing {
    public static var path: String { NSHomeDirectory() + "/.s1/prices.json" }
    static let source = URL(string: "https://openrouter.ai/api/v1/models")!

    /// The cached public price list (model id → price).
    public static func table(path: String = Pricing.path) -> [String: Price] {
        guard let d = FileManager.default.contents(atPath: path),
              let t = try? JSONDecoder().decode([String: Price].self, from: d) else { return [:] }
        return t
    }

    /// Refresh the list at most once a day. Public data: nothing about the
    /// user is sent. Fails soft — the old list (or none) stays.
    public static func refreshIfStale(path: String = Pricing.path) async {
        let age = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 86_400 else { return }
        var req = URLRequest(url: source)
        req.timeoutInterval = 15
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let t = parse(data), !t.isEmpty,
              let out = try? JSONEncoder().encode(t) else { return }
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        try? out.write(to: URL(fileURLWithPath: path))
    }

    static func parse(_ data: Data) -> [String: Price]? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["data"] as? [[String: Any]] else { return nil }
        var t: [String: Price] = [:]
        for m in models {
            guard let id = m["id"] as? String, let p = m["pricing"] as? [String: Any] else { continue }
            func d(_ k: String) -> Double? { (p[k] as? String).flatMap(Double.init) ?? (p[k] as? NSNumber)?.doubleValue }
            guard let i = d("prompt"), let o = d("completion"), i >= 0, o >= 0 else { continue }
            t[id] = Price(input: i, output: o, cacheRead: d("input_cache_read"),
                          cacheWrite: d("input_cache_write"), webSearch: d("web_search"))
        }
        return t
    }

    /// The list price for a model as s1 names it ("gpt-5-mini" → "openai/gpt-5-mini").
    public static func price(model: String, host: String, in table: [String: Price]) -> Price? {
        let m = model.lowercased()
        if let p = table[m] { return p }
        let prefix: String? = switch true {
        case host.contains("openai.com"): "openai/"
        case host.contains("googleapis"): "google/"
        case host.contains("x.ai"): "x-ai/"
        case host.contains("deepseek"): "deepseek/"
        case host.contains("anthropic"): "anthropic/"
        default: nil
        }
        if let prefix, let p = table[prefix + m] { return p }
        // Same model under any vendor prefix, shortest id first (no ":batch" twins).
        return table.filter { $0.key.split(separator: "/").last.map(String.init) == m }
            .min { $0.key.count < $1.key.count }?.value
    }

    public static func billing(host: String, model: String) -> Billing? {
        if Endpoints.isLocal("http://" + host) { return .free }
        if model.lowercased().hasSuffix(":free") { return .free }
        if host.hasSuffix("opencode.ai") { return .plan }
        return nil
    }

    /// Cost in USD and how sure that number is.
    public static func cost(_ r: UsageRecord, table: [String: Price]) -> (usd: Double, billing: Billing) {
        if let c = r.cost { return (c, .billed) }
        if let b = billing(host: r.host, model: r.model) { return (0, b) }
        guard let p = price(model: r.model, host: r.host, in: table) else { return (0, .unknown) }
        let input = Double(r.input ?? 0), cached = Double(r.cached ?? 0), write = Double(r.cacheWrite ?? 0)
        let fresh = max(0, input - cached - write)
        let usd = fresh * p.input + cached * (p.cacheRead ?? p.input)
            + write * (p.cacheWrite ?? p.input) + Double(r.output ?? 0) * p.output
        return (usd, .estimated)
    }
}

/// Usage for a period, rolled up for the Usage tab: totals, a per-model table
/// and per-bucket series for the chart. Numbers only, from usage.jsonl.
public struct UsageReport: Sendable {
    public struct Row: Hashable, Sendable {
        public var role: String, model: String, host: String
        public var calls = 0, failures = 0, input = 0, cached = 0, cacheWrite = 0, output = 0, totalMs = 0
        public var usd = 0.0
        public var billing: Billing = .unknown
        public var avgMs: Int { calls > 0 ? totalMs / calls : 0 }
    }
    public struct Bucket: Hashable, Sendable {
        public var start: Date, role: String
        public var usd = 0.0, tokens = 0, calls = 0
    }

    public var rows: [Row] = []
    public var buckets: [Bucket] = []
    public var calls = 0, failures = 0, input = 0, cached = 0, cacheWrite = 0, output = 0
    public var billedUSD = 0.0, estimatedUSD = 0.0
    public var planCalls = 0, freeCalls = 0, unknownCalls = 0

    public var spentUSD: Double { billedUSD + estimatedUSD }
    public var cacheHitRate: Double? { input > 0 ? Double(cached) / Double(input) : nil }

    public init() {}

    /// `bucket` is `.hour` or `.day` — the chart's bar width.
    public static func build(_ records: [UsageRecord], prices: [String: Price],
                             bucket: Calendar.Component, calendar: Calendar = .current) -> UsageReport {
        var rep = UsageReport()
        var rows: [String: Row] = [:], tally: [String: [Billing: Int]] = [:]
        var buckets: [String: Bucket] = [:]
        // Older logs named roles differently.
        let legacy = ["s2": "reasoner", "s1-decision": "judge", "decision": "judge"]
        for var r in records {
            r.role = legacy[r.role] ?? r.role
            let (usd, billing) = Pricing.cost(r, table: prices)
            let key = r.role + "\u{0}" + r.model
            var row = rows[key] ?? Row(role: r.role, model: r.model, host: r.host)
            row.calls += 1; if !r.ok { row.failures += 1 }
            row.input += r.input ?? 0; row.cached += r.cached ?? 0
            row.cacheWrite += r.cacheWrite ?? 0; row.output += r.output ?? 0
            row.totalMs += r.ms; row.usd += usd
            rows[key] = row
            tally[key, default: [:]][billing, default: 0] += 1

            rep.calls += 1; if !r.ok { rep.failures += 1 }
            rep.input += r.input ?? 0; rep.cached += r.cached ?? 0
            rep.cacheWrite += r.cacheWrite ?? 0; rep.output += r.output ?? 0
            switch billing {
            case .billed: rep.billedUSD += usd
            case .estimated: rep.estimatedUSD += usd
            case .plan: rep.planCalls += 1
            case .free: rep.freeCalls += 1
            case .unknown: rep.unknownCalls += 1
            }

            let start = calendar.dateInterval(of: bucket, for: r.ts)?.start ?? r.ts
            let bk = "\(start.timeIntervalSince1970)\u{0}\(r.role)"
            var b = buckets[bk] ?? Bucket(start: start, role: r.role)
            b.usd += usd; b.tokens += (r.input ?? 0) + (r.output ?? 0); b.calls += 1
            buckets[bk] = b
        }
        // A row's badge is how most of its calls were priced.
        for (k, t) in tally { rows[k]?.billing = t.max { $0.value < $1.value }?.key ?? .unknown }
        rep.rows = rows.values.sorted { ($0.usd, $0.calls) > ($1.usd, $1.calls) }
        rep.buckets = buckets.values.sorted { $0.start < $1.start }
        return rep
    }
}
