import Foundation

/// One model call's metering: who asked (role), which model answered, token
/// counts and prompt-cache hits as the provider reported them. Never holds
/// prompts, replies, screen text, or keys — only numbers and names.
public struct UsageRecord: Codable, Sendable, Equatable {
    public var ts: Date
    public var role: String          // s1-decision | s1-vlm | s1-grounder | s2
    public var host: String
    public var model: String
    public var served: String?       // versioned model the provider reports
    public var input: Int?
    public var output: Int?
    public var cached: Int?          // prompt tokens served from cache
    public var cacheMiss: Int?
    public var reasoning: Int?
    public var ms: Int
    public var ok: Bool
    public var error: String?

    public init(ts: Date = Date(), role: String, host: String, model: String, served: String? = nil,
                input: Int? = nil, output: Int? = nil, cached: Int? = nil, cacheMiss: Int? = nil,
                reasoning: Int? = nil, ms: Int, ok: Bool, error: String? = nil) {
        self.ts = ts; self.role = role; self.host = host; self.model = model; self.served = served
        self.input = input; self.output = output; self.cached = cached; self.cacheMiss = cacheMiss
        self.reasoning = reasoning; self.ms = ms; self.ok = ok; self.error = error
    }
}

public struct TokenCounts: Sendable, Equatable {
    public var input: Int?, output: Int?, cached: Int?, cacheMiss: Int?, reasoning: Int?
}

public enum UsageLog {
    public static var path: String {
        ProcessInfo.processInfo.environment["S1_USAGE_LOG"] ?? NSHomeDirectory() + "/.s1/usage.jsonl"
    }
    private static let lock = NSLock()

    public static func append(_ r: UsageRecord, path: String = UsageLog.path) {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .sortedKeys
        guard var line = try? enc.encode(r) else { return }
        line.append(0x0A)
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        try? fm.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                withIntermediateDirectories: true)
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = FileHandle(forWritingAtPath: path) else { return }
        defer { try? h.close() }
        _ = try? h.seekToEnd()
        try? h.write(contentsOf: line)
    }

    public static func load(path: String = UsageLog.path, since: Date? = nil) -> [UsageRecord] {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap {
            guard let r = try? dec.decode(UsageRecord.self, from: Data($0.utf8)) else { return nil }
            if let since, r.ts < since { return nil }
            return r
        }
    }

    /// Token counts from any usage shape s1 talks to: OpenAI chat
    /// (`prompt_tokens`, `prompt_tokens_details.cached_tokens`), DeepSeek
    /// (`prompt_cache_hit_tokens`/`_miss_tokens`), Responses/Anthropic/Jev
    /// (`input_tokens`, `cache_read_input_tokens`).
    public static func counts(fromUsage u: [String: Any]?) -> TokenCounts {
        guard let u else { return TokenCounts() }
        func int(_ v: Any?) -> Int? { (v as? NSNumber)?.intValue }
        let pd = u["prompt_tokens_details"] as? [String: Any]
        let id = u["input_tokens_details"] as? [String: Any]
        let cd = u["completion_tokens_details"] as? [String: Any]
        let od = u["output_tokens_details"] as? [String: Any]
        return TokenCounts(
            input: int(u["prompt_tokens"]) ?? int(u["input_tokens"]),
            output: int(u["completion_tokens"]) ?? int(u["output_tokens"]),
            cached: int(u["prompt_cache_hit_tokens"]) ?? int(pd?["cached_tokens"])
                ?? int(id?["cached_tokens"]) ?? int(u["cache_read_input_tokens"]),
            cacheMiss: int(u["prompt_cache_miss_tokens"]),
            reasoning: int(cd?["reasoning_tokens"]) ?? int(od?["reasoning_tokens"]))
    }

    public struct Summary: Sendable, Hashable {
        public var role: String, model: String
        public var calls = 0, failures = 0, input = 0, output = 0, cached = 0, totalMs = 0
        public var cacheHitRate: Double? { input > 0 ? Double(cached) / Double(input) : nil }
        public var avgMs: Int { calls > 0 ? totalMs / calls : 0 }
    }

    public static func summarize(_ records: [UsageRecord]) -> [Summary] {
        var by: [String: Summary] = [:]
        for r in records {
            let k = r.role + "\u{0}" + r.model
            var s = by[k] ?? Summary(role: r.role, model: r.model)
            s.calls += 1
            if !r.ok { s.failures += 1 }
            s.input += r.input ?? 0
            s.output += r.output ?? 0
            s.cached += r.cached ?? 0
            s.totalMs += r.ms
            by[k] = s
        }
        return by.values.sorted { ($0.role, $0.model) < ($1.role, $1.model) }
    }

    /// Error text safe to persist: status + provider message, clipped, with
    /// anything that looks like a bearer token scrubbed.
    static func scrub(_ s: String) -> String {
        let clipped = String(s.prefix(200))
        return clipped.replacingOccurrences(of: #"(?i)(bearer\s+|sk-|key[=:]\s*)[A-Za-z0-9._\-]{6,}"#,
                                            with: "$1[redacted]", options: .regularExpression)
    }
}
