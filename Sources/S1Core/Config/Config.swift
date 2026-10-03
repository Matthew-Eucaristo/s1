import Foundation

/// User configuration at `~/.s1/config.json` — the easy-swap knob for brains.
/// Change the model by editing the file (or letting the app write it);
/// environment variables still win over the file, CLI flags win over both.
///
/// ```json
/// {
///   "vlm":   { "base": "http://localhost:11434/v1", "model": "gemma3:4b" },
///   "s2":    { "base": "http://localhost:11434/v1", "model": "gemma3:4b" },
///   "locale": "id-ID",
///   "speak":  true,
///   "vocabulary": ["s1", "Warp", "Linear"]
/// }
/// ```
public struct S1Config: Codable, Sendable {
    public struct ModelEndpoint: Codable, Sendable {
        public var base: String?
        public var model: String?
        public var key: String?
        public var numCtx: Int?
        public init(base: String? = nil, model: String? = nil,
                    key: String? = nil, numCtx: Int? = nil) {
            self.base = base; self.model = model; self.key = key; self.numCtx = numCtx
        }
    }

    public var vlm: ModelEndpoint?
    public var s2: ModelEndpoint?
    public var locale: String?
    public var speak: Bool?
    /// Extra words/phrases the STT should bias toward (app names, jargon).
    /// Apple's contextual-strings limit is 100 total — s1 prepends installed
    /// app names after these, so user entries always win.
    public var vocabulary: [String]?

    public init(vlm: ModelEndpoint? = nil, s2: ModelEndpoint? = nil,
                locale: String? = nil, speak: Bool? = nil,
                vocabulary: [String]? = nil) {
        self.vlm = vlm; self.s2 = s2; self.locale = locale; self.speak = speak
        self.vocabulary = vocabulary
    }

    public static var path: String { NSHomeDirectory() + "/.s1/config.json" }

    /// Missing or malformed file → empty config (defaults apply). Never throws:
    /// config is a convenience, not a gate.
    public static func load(from path: String = S1Config.path) -> S1Config {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let c = try? JSONDecoder().decode(S1Config.self, from: data) else {
            return S1Config()
        }
        return c
    }

    public func save(to path: String = S1Config.path) throws {
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
    }
}

/// Resolved model endpoints — precedence: explicit arg > env var > config file > built-in default.
public enum Endpoints {
    public static func vlm(base: String? = nil, model: String? = nil,
                           env: [String: String] = ProcessInfo.processInfo.environment,
                           config: S1Config = .load()) -> Endpoint {
        Endpoint(
            baseURL: base ?? env["S1_VLM_BASE"] ?? config.vlm?.base ?? "http://localhost:11434/v1",
            model: model ?? env["S1_VLM_MODEL"] ?? config.vlm?.model ?? "gemma3:4b",
            apiKey: env["S1_VLM_KEY"] ?? config.vlm?.key,
            numCtx: env["S1_NUM_CTX"].flatMap(Int.init) ?? config.vlm?.numCtx ?? 8192)
    }

    public static func s2(env: [String: String] = ProcessInfo.processInfo.environment,
                          config: S1Config = .load()) -> Endpoint {
        Endpoint(
            baseURL: env["S1_S2_BASE"] ?? config.s2?.base ?? "http://localhost:11434/v1",
            model: env["S1_S2_MODEL"] ?? config.s2?.model ?? "gemma3:4b",
            apiKey: env["S1_S2_KEY"] ?? config.s2?.key,
            numCtx: env["S1_NUM_CTX"].flatMap(Int.init) ?? config.s2?.numCtx ?? 8192)
    }
}
