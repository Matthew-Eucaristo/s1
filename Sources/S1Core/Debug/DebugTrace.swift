import Foundation

/// Debug evidence for a run: every S1/S2 HTTP exchange (minus credentials)
/// and voice-turn timings, appended as JSONL next to steps.jsonl. On by
/// default while the agent is being tuned; `S1_DEBUG=0` turns it off.
public enum DebugTrace {
    @TaskLocal public static var runDir: URL?

    public static var enabled: Bool { ProcessInfo.processInfo.environment["S1_DEBUG"] != "0" }

    static let root = URL(fileURLWithPath: S1Home.path + "/artifacts")
    private static let lock = NSLock()

    /// One HTTP exchange. Bodies only — headers (Authorization) never land here.
    public static func http(role: String, url: URL?, status: Int, ms: Int,
                            request: Data?, response: Data?, error: String? = nil) {
        var f: [String: Any] = ["role": role, "url": url?.absoluteString ?? "", "status": status, "ms": ms]
        if let request { f["request"] = sanitized(request) }
        if let response { f["response"] = sanitized(response, limit: 16_000) }
        if let error { f["error"] = error }
        event("http", f)
    }

    /// Append one event to `<run>/debug.jsonl`, or `artifacts/debug.jsonl`
    /// outside a run (voice turns happen before a run exists).
    public static func event(_ kind: String, _ fields: [String: Any]) {
        guard enabled else { return }
        var f = fields
        f["kind"] = kind
        f["ts"] = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
        guard JSONSerialization.isValidJSONObject(f),
              var line = try? JSONSerialization.data(withJSONObject: f, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        let url = (runDir ?? root).appendingPathComponent("debug.jsonl")
        lock.lock(); defer { lock.unlock() }
        S1Home.ensurePrivate()
        JSONL.append(line, to: url, maxBytes: 8 << 20)
    }

    /// JSON body with base64 blobs collapsed (screenshots would bury the
    /// log); non-JSON falls back to a clipped string.
    static func sanitized(_ data: Data, limit: Int = 64_000) -> Any {
        func walk(_ v: Any) -> Any {
            switch v {
            case let s as String:
                if s.count > 4_000, !s.contains(" ") { return "<\(s.count) chars base64>" }
                return s
            case let a as [Any]: return a.map(walk)
            case let d as [String: Any]: return d.mapValues(walk)
            default: return v
            }
        }
        if let obj = try? JSONSerialization.jsonObject(with: data) { return walk(obj) }
        return String(decoding: data.prefix(limit), as: UTF8.self)
    }
}
