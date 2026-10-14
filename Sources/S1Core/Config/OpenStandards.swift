import Foundation

/// One MCP server s1 may start (stdio): `{"command": "npx", "args": [...],
/// "env": {...}}` — the shape Claude Desktop, Cursor and others use, so an
/// existing entry can be pasted as is. `autoApprove` lists tools that may
/// run without asking even when the server doesn't mark them read-only.
public struct MCPServerConfig: Codable, Sendable, Equatable {
    public var command: String
    public var args: [String]?
    public var env: [String: String]?
    public var disabled: Bool?
    public var autoApprove: [String]?

    public init(command: String, args: [String]? = nil, env: [String: String]? = nil,
                disabled: Bool? = nil, autoApprove: [String]? = nil) {
        self.command = command; self.args = args; self.env = env
        self.disabled = disabled; self.autoApprove = autoApprove
    }
}

/// OpenTelemetry export: OTLP/HTTP (JSON) traces of runs, steps and model
/// calls. Off unless `endpoint` is set here or `S1_OTEL=on` with the
/// standard `OTEL_EXPORTER_OTLP_ENDPOINT`. Prompts and replies are never
/// sent unless `content` is true.
public struct TelemetryConfig: Codable, Sendable, Equatable {
    /// Base URL ("http://localhost:4318"); `/v1/traces` is appended.
    public var endpoint: String?
    /// Extra headers (an auth token for a hosted collector).
    public var headers: [String: String]?
    /// Include goal text, model replies and action details (nil = off).
    public var content: Bool?

    public init(endpoint: String? = nil, headers: [String: String]? = nil, content: Bool? = nil) {
        self.endpoint = endpoint; self.headers = headers; self.content = content
    }
}

/// JSON-schema structured output for the Reasoner: on unless config or
/// `S1_STRUCTURED=off` says otherwise.
public enum StructuredOutput {
    public static func enabled(_ cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let e = env["S1_STRUCTURED"]?.lowercased() { return !["0", "off", "false", "no"].contains(e) }
        return cfg.structuredOutput ?? true
    }
}
