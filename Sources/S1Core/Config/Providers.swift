import Foundation

// MARK: - Roles

/// What s1 uses a model for — one model per role, every role optional.
/// With none assigned, s1 runs on its deterministic grammar alone.
/// Seeing the screen isn't a role: it's a capability of the judge or the
/// reasoner (see `Models.seesScreen`).
public enum ModelRole: String, CaseIterable, Codable, Sendable, Identifiable {
    /// System 1's decision model — typed yes/no · choice · score per step
    /// (System One API: Jev, d1, Clef).
    case judge
    /// System 2 — an LLM that plans what the grammar can't and answers questions.
    case reasoner
    /// Cloud speech-to-text. Unassigned = on-device Apple speech.
    case transcribe
    /// Cloud text-to-speech. Unassigned = Apple voices.
    case speak

    public var id: String { rawValue }

    /// The wire protocol a provider must speak to fill this role.
    public var api: ProviderAPI {
        switch self {
        case .judge: .systemOne
        case .reasoner: .chat
        case .transcribe, .speak: .audio
        }
    }

    /// Roles a newly connected provider fills automatically when they're
    /// empty. Speech stays on-device until chosen — audio leaves the Mac
    /// only by explicit choice.
    public var autoAssigns: Bool { self == .judge || self == .reasoner }

    /// `S1_JUDGE=provider/model` (or `off`) overrides the config file.
    public var envName: String { "S1_\(rawValue.uppercased())" }
}

/// The three wire shapes s1 speaks.
public enum ProviderAPI: String, Codable, Sendable {
    /// OpenAI-compatible `/chat/completions` (+ `/models`).
    case chat
    /// System One API — `POST …/v1/systemone`.
    case systemOne
    /// OpenAI-compatible `/audio/transcriptions` + `/audio/speech`.
    case audio
}

// MARK: - Catalog

/// A model a provider offers, with the roles it's good for.
public struct ModelOption: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Display name — defaults to the id.
    public var name: String?
    public var roles: [ModelRole]
    /// Roles this model is the provider's default pick for.
    public var recommended: [ModelRole]?
    /// Reads images — the judge or reasoner then sees the screen.
    public var vision: Bool?
    /// Provider-side TTS voice ("troy", "alloy").
    public var voice: String?
    /// Download size for local models ("3.3 GB").
    public var size: String?
    /// One line on why you'd pick it.
    public var note: String?

    public init(_ id: String, name: String? = nil, roles: [ModelRole],
                recommended: [ModelRole]? = nil, vision: Bool? = nil, voice: String? = nil,
                size: String? = nil, note: String? = nil) {
        self.id = id; self.name = name; self.roles = roles
        self.recommended = recommended; self.vision = vision; self.voice = voice
        self.size = size; self.note = note
    }

    public var displayName: String { name ?? id }
    public func isRecommended(for role: ModelRole) -> Bool { recommended?.contains(role) ?? false }
}

/// A provider s1 knows how to talk to — the catalog entry behind "Add
/// Provider". Base URLs may carry `{field}` placeholders filled from the
/// connected instance (`{account}` for Cloudflare) and `{model}`.
public struct ProviderTemplate: Codable, Sendable, Equatable, Identifiable {
    public struct Field: Codable, Sendable, Equatable {
        public var id: String
        public var label: String
        public var placeholder: String?
        public init(id: String, label: String, placeholder: String? = nil) {
            self.id = id; self.label = label; self.placeholder = placeholder
        }
    }

    public enum Kind: String, Codable, Sendable {
        /// Hosted API behind a key.
        case cloud
        /// A server on this Mac (or your LAN) — no key needed.
        case local
        /// Any OpenAI-compatible server the user points at.
        case custom
    }

    public var id: String
    public var name: String
    public var kind: Kind
    /// One line under the name in "Add Provider".
    public var summary: String
    /// Where to get an API key.
    public var keyURL: String?
    /// Key-field prompt ("gsk_…").
    public var keyHint: String?
    public var chat: String?
    public var systemOne: String?
    /// Defaults to `chat` — OpenAI-compatible audio lives beside chat.
    public var audio: String?
    public var fields: [Field]
    public var models: [ModelOption]
    /// `GET {chat}/models` returns a usable list — the pickers offer it.
    public var listsModels: Bool
    /// SF Symbol for the provider's badge (monogram when nil).
    public var symbol: String?

    public init(id: String, name: String, kind: Kind, summary: String,
                keyURL: String? = nil, keyHint: String? = nil,
                chat: String? = nil, systemOne: String? = nil, audio: String? = nil,
                fields: [Field] = [], models: [ModelOption] = [],
                listsModels: Bool = false, symbol: String? = nil) {
        self.id = id; self.name = name; self.kind = kind; self.summary = summary
        self.keyURL = keyURL; self.keyHint = keyHint
        self.chat = chat; self.systemOne = systemOne; self.audio = audio
        self.fields = fields; self.models = models
        self.listsModels = listsModels; self.symbol = symbol
    }

    public var needsKey: Bool { kind == .cloud }
}

public enum ProviderCatalog {
    /// Every provider s1 ships knowledge of. Order is the "Add Provider"
    /// order — recommended pair first, then cloud, then local.
    public static let all: [ProviderTemplate] = [
        .init(id: "typesafe", name: "TypeSafe", kind: .cloud,
              summary: "Jev, the recommended Judge (System 1)",
              keyURL: "https://typesafe.ai", keyHint: "TypeSafe API key",
              systemOne: "https://api.typesafe.ai",
              models: [.init("jev-latest", name: "Jev", roles: [.judge], recommended: [.judge], vision: false,
                             note: "calibrated yes/no · choice · score")]),
        .init(id: "opencode", name: "OpenCode Go", kind: .cloud,
              summary: "DeepSeek V4.1 Flash, the recommended Reasoner (System 2)",
              keyURL: "https://opencode.ai", keyHint: "OpenCode Go subscription key",
              chat: "https://opencode.ai/zen/go/v1",
              models: [
                .init("deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash", roles: [.reasoner],
                      recommended: [.reasoner], vision: false, note: "fast, cheap, strong at plans"),
                .init("deepseek-v4-flash-vision-exp", name: "DeepSeek V4 Flash Vision", roles: [.reasoner],
                      vision: true, note: "sees the screen, experimental"),
                .init("deepseek-v4-pro", name: "DeepSeek V4 Pro", roles: [.reasoner], vision: false,
                      note: "slower, deeper reasoning"),
              ],
              listsModels: true),
        .init(id: "openai", name: "OpenAI", kind: .cloud,
              summary: "GPT Reasoners, transcription and natural voices",
              keyURL: "https://platform.openai.com/api-keys", keyHint: "sk-…",
              chat: "https://api.openai.com/v1",
              models: [
                .init("gpt-5-mini", name: "GPT-5 mini", roles: [.reasoner], recommended: [.reasoner], vision: true),
                .init("gpt-5", name: "GPT-5", roles: [.reasoner], vision: true),
                .init("gpt-4o-mini-transcribe", roles: [.transcribe], recommended: [.transcribe]),
                .init("gpt-4o-mini-tts", roles: [.speak], recommended: [.speak], voice: "alloy"),
              ],
              listsModels: true),
        .init(id: "openrouter", name: "OpenRouter", kind: .cloud,
              summary: "Every major model behind one key, Claude included",
              keyURL: "https://openrouter.ai/keys", keyHint: "sk-or-…",
              chat: "https://openrouter.ai/api/v1",
              models: [
                .init("google/gemini-2.5-flash", name: "Gemini 2.5 Flash", roles: [.reasoner],
                      recommended: [.reasoner], vision: true, note: "fast, sees the screen"),
                .init("anthropic/claude-sonnet-4.5", name: "Claude Sonnet 4.5", roles: [.reasoner], vision: true),
                .init("openai/gpt-5", name: "GPT-5", roles: [.reasoner], vision: true),
                .init("openai/gpt-oss-120b", name: "gpt-oss-120b", roles: [.reasoner], vision: false, note: "text only"),
              ],
              listsModels: true),
        .init(id: "groq", name: "Groq", kind: .cloud,
              summary: "Fast open Reasoners, Whisper and Orpheus voices",
              keyURL: "https://console.groq.com/keys", keyHint: "gsk_…",
              chat: "https://api.groq.com/openai/v1",
              models: [
                .init("meta-llama/llama-4-scout-17b-16e-instruct", name: "Llama 4 Scout", roles: [.reasoner],
                      recommended: [.reasoner], vision: true, note: "fast, sees the screen"),
                .init("openai/gpt-oss-120b", name: "gpt-oss-120b", roles: [.reasoner], vision: false, note: "text only"),
                .init("whisper-large-v3-turbo", name: "Whisper Large v3 Turbo", roles: [.transcribe],
                      recommended: [.transcribe], note: "fast"),
                .init("whisper-large-v3", name: "Whisper Large v3", roles: [.transcribe], note: "most accurate"),
                .init("canopylabs/orpheus-v1-english", name: "Orpheus English", roles: [.speak],
                      recommended: [.speak], voice: "troy"),
                .init("canopylabs/orpheus-v1-indonesian", name: "Orpheus Indonesian", roles: [.speak],
                      voice: "troy"),
              ],
              listsModels: true),
        .init(id: "gemini", name: "Google Gemini", kind: .cloud,
              summary: "Gemini through Google AI Studio",
              keyURL: "https://aistudio.google.com/apikey", keyHint: "AI Studio API key",
              chat: "https://generativelanguage.googleapis.com/v1beta/openai",
              models: [
                .init("gemini-2.5-flash", name: "Gemini 2.5 Flash", roles: [.reasoner],
                      recommended: [.reasoner], vision: true),
              ],
              listsModels: true),
        .init(id: "xai", name: "xAI", kind: .cloud,
              summary: "Grok models",
              keyURL: "https://console.x.ai", keyHint: "xai-…",
              chat: "https://api.x.ai/v1",
              models: [.init("grok-4-fast", name: "Grok 4 Fast", roles: [.reasoner], recommended: [.reasoner], vision: true)],
              listsModels: true),
        .init(id: "deepseek", name: "DeepSeek", kind: .cloud,
              summary: "DeepSeek's own API",
              keyURL: "https://platform.deepseek.com/api_keys", keyHint: "sk-…",
              chat: "https://api.deepseek.com",
              models: [.init("deepseek-flash", name: "DeepSeek V4.1 Flash", roles: [.reasoner],
                             recommended: [.reasoner], vision: false)],
              listsModels: true),
        .init(id: "liquid", name: "Liquid AI", kind: .cloud,
              summary: "d1, a Judge that also sees the screen (paid tier)",
              keyURL: "https://console.liquid.ai", keyHint: "liquid_…",
              systemOne: "https://api.liquid.ai/decisions",
              models: [
                .init("d1:free", name: "d1 (free tier, text only)", roles: [.judge], recommended: [.judge], vision: false),
                .init("d1", name: "d1", roles: [.judge], vision: true),
              ]),
        .init(id: "cloudflare", name: "Cloudflare Workers AI", kind: .cloud,
              summary: "Clef Judges (open weights) and Llama Reasoners",
              keyURL: "https://dash.cloudflare.com/profile/api-tokens", keyHint: "API token",
              chat: "https://api.cloudflare.com/client/v4/accounts/{account}/ai/v1",
              systemOne: "https://api.cloudflare.com/client/v4/accounts/{account}/ai/run/@cf/cloudflare/{model}",
              fields: [.init(id: "account", label: "Account ID", placeholder: "32-character account id")],
              models: [
                .init("clef-flash", name: "Clef Flash", roles: [.judge], recommended: [.judge], vision: true),
                .init("clef", name: "Clef", roles: [.judge], vision: true, note: "larger"),
                .init("@cf/meta/llama-4-scout-17b-16e-instruct", name: "Llama 4 Scout", roles: [.reasoner],
                      recommended: [.reasoner], vision: true),
              ]),
        .init(id: "ollama", name: "Ollama", kind: .local,
              summary: "Open models on this Mac: private, offline, free",
              chat: "http://localhost:11434/v1", systemOne: "http://localhost:11434",
              models: [
                .init("clef-flash", roles: [.judge], vision: true, size: "9 GB", note: "judge that sees the screen"),
                .init("nimble", roles: [.judge], vision: false, size: "9.5 GB", note: "calibrated text judge"),
                .init("tev1:0.8b", roles: [.judge], vision: false, size: "811 MB", note: "tiny, poorly calibrated"),
                .init("qwen3-vl:8b", roles: [.reasoner], vision: true, size: "6.1 GB",
                      note: "best local reasoner that sees, fits 16 GB"),
                .init("gemma3:4b", roles: [.reasoner], vision: true, size: "3.3 GB", note: "light, sees the screen"),
                .init("qwen3:8b", roles: [.reasoner], vision: false, size: "5.2 GB", note: "text only"),
                .init("gpt-oss:20b", roles: [.reasoner], vision: false, size: "13 GB", note: "text only, needs the RAM"),
              ],
              listsModels: true, symbol: "desktopcomputer"),
        .init(id: "lmstudio", name: "LM Studio", kind: .local,
              summary: "Any model loaded in LM Studio's local server",
              chat: "http://localhost:1234/v1", listsModels: true, symbol: "macwindow"),
        .init(id: "custom", name: "Custom Server", kind: .custom,
              summary: "Any OpenAI-compatible endpoint: vLLM, MLX, Speaches, your own",
              listsModels: true, symbol: "server.rack"),
    ]

    public static func template(_ id: String) -> ProviderTemplate? { all.first { $0.id == id } }
}

// MARK: - Connected providers

/// A connected provider as stored in `config.json` → `providers` (an
/// ordered list). The template defaults to the id, so most entries are
/// just `{"id": "groq"}`. The API key never lives here — it's in the
/// Keychain under the id.
public struct ProviderConfig: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    /// Catalog template ("ollama"); nil = the id itself.
    public var template: String?
    public var name: String?
    /// Base URL overrides — a remote Ollama, a custom server.
    public var chat: String?
    public var systemOne: String?
    public var audio: String?
    /// Template field values (`account` for Cloudflare).
    public var values: [String: String]?

    public init(id: String, template: String? = nil, name: String? = nil, chat: String? = nil,
                systemOne: String? = nil, audio: String? = nil, values: [String: String]? = nil) {
        self.id = id; self.template = template; self.name = name; self.chat = chat
        self.systemOne = systemOne; self.audio = audio; self.values = values
    }
}

/// A provider instance with its template and overrides folded together —
/// what everything outside this file works with.
public struct Provider: Sendable, Equatable, Identifiable {
    public let id: String
    public let template: ProviderTemplate
    public let config: ProviderConfig

    public init(template: ProviderTemplate, config: ProviderConfig) {
        self.id = config.id; self.template = template; self.config = config
    }

    public var name: String { config.name ?? template.name }
    public var kind: ProviderTemplate.Kind { template.kind }
    /// Cloud providers can't answer without a key; local and custom servers may.
    public var needsKey: Bool { template.needsKey }

    /// Base URL for an API, placeholders filled. nil = this provider doesn't
    /// speak it, or a required field (Cloudflare account) is still empty.
    public func base(_ api: ProviderAPI, model: String = "") -> String? {
        let raw: String? = switch api {
        case .chat: config.chat ?? template.chat
        case .systemOne: config.systemOne ?? template.systemOne
        case .audio: config.audio ?? template.audio ?? config.chat ?? template.chat
        }
        guard var url = raw?.trimmingCharacters(in: .whitespaces), !url.isEmpty else { return nil }
        for f in template.fields {
            guard let v = config.values?[f.id]?.trimmingCharacters(in: .whitespaces), !v.isEmpty else {
                if url.contains("{\(f.id)}") { return nil }
                continue
            }
            url = url.replacingOccurrences(of: "{\(f.id)}", with: v)
        }
        if url.contains("{model}") {
            guard !model.isEmpty else { return nil }
            url = url.replacingOccurrences(of: "{model}", with: model)
        }
        return url
    }

    /// Every base answers on loopback — nothing leaves the Mac.
    public var isLocal: Bool {
        let bases = [ProviderAPI.chat, .systemOne].compactMap { base($0, model: "m") }
        return !bases.isEmpty && bases.allSatisfy(Endpoints.isLocal)
    }

    /// Can this provider fill `role` at all?
    public func supports(_ role: ModelRole) -> Bool {
        guard base(role.api, model: "m") != nil else { return false }
        if template.models.contains(where: { $0.roles.contains(role) }) { return true }
        // Listing providers and custom servers can serve the reasoner with
        // whatever they list; audio only on servers the user set up for it.
        switch role.api {
        case .chat: return template.listsModels
        case .audio: return template.kind == .custom
        case .systemOne: return template.kind == .custom || template.kind == .local
        }
    }

    public var roles: [ModelRole] { ModelRole.allCases.filter(supports) }

    public func models(for role: ModelRole) -> [ModelOption] {
        template.models.filter { $0.roles.contains(role) }
    }

    public func recommended(for role: ModelRole) -> ModelOption? {
        template.models.first { $0.isRecommended(for: role) }
    }

    public func option(_ model: String) -> ModelOption? {
        template.models.first { $0.id == model }
    }

    /// Keychain account holding this provider's key.
    public var keyAccount: String { id }
    /// `S1_GROQ_KEY` — env override for scripts and CI.
    public var keyEnv: String {
        "S1_" + id.uppercased().map { $0.isLetter || $0.isNumber ? String($0) : "_" }.joined() + "_KEY"
    }
}

/// A role assignment: `provider/model`. The model id may itself contain
/// slashes (`openrouter/anthropic/claude-sonnet-4.5`) — split on the first.
public struct ModelRef: Sendable, Hashable, Codable, CustomStringConvertible {
    public var provider: String
    public var model: String

    public init(provider: String, model: String) { self.provider = provider; self.model = model }

    public init?(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let slash = t.firstIndex(of: "/") else { return nil }
        let p = String(t[..<slash]), m = String(t[t.index(after: slash)...])
        guard !p.isEmpty, !m.isEmpty else { return nil }
        provider = p; model = m
    }

    public var description: String { "\(provider)/\(model)" }

    public init(from decoder: Decoder) throws {
        let s = try decoder.singleValueContainer().decode(String.self)
        guard let r = ModelRef(s) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                debugDescription: "expected provider/model, got \(s)"))
        }
        self = r
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(description)
    }
}

// MARK: - Resolution

/// Providers + role assignments — the single model-selection surface the
/// app, the CLI, and the agent loop all read.
public enum Models {
    public typealias Secret = @Sendable (Provider) -> String?

    /// Keychain, with `S1_<PROVIDER>_KEY` winning.
    public static let keychain: Secret = { p in
        if let k = ProcessInfo.processInfo.environment[p.keyEnv], !k.isEmpty { return k }
        return SecretStore.get(account: p.keyAccount)
    }

    /// Provider instance by id: a connected entry, else a bare catalog
    /// template (so `S1_REASONER=groq/…` + `S1_GROQ_KEY` works unconnected).
    public static func provider(_ id: String, config: S1Config = .load()) -> Provider? {
        if let c = config.providers?.first(where: { $0.id == id }) {
            let t = ProviderCatalog.template(c.template ?? id) ?? ProviderCatalog.template("custom")!
            return Provider(template: t, config: c)
        }
        guard let t = ProviderCatalog.template(id), t.kind != .custom else { return nil }
        return Provider(template: t, config: ProviderConfig(id: id))
    }

    /// Connected providers, in the order they were added.
    public static func connected(config: S1Config = .load()) -> [Provider] {
        (config.providers ?? []).compactMap { provider($0.id, config: config) }
    }

    /// What a role is assigned to — env first, then the file. nil = off.
    public static func assignment(_ role: ModelRole, config: S1Config = .load(),
                                  env: [String: String] = ProcessInfo.processInfo.environment) -> ModelRef? {
        if let e = env[role.envName] { return ModelRef(e) }   // "off" doesn't parse → nil
        return config.models?[role.rawValue].flatMap(ModelRef.init)
    }

    /// A role resolved to something callable.
    public struct Resolved: Sendable {
        public var role: ModelRole
        public var ref: ModelRef
        public var provider: Provider
        public var endpoint: Endpoint
    }

    public enum Problem: Error, Equatable, Sendable, CustomStringConvertible {
        case unknownProvider(String)
        case unsupported(provider: String, role: ModelRole)
        case missingField(provider: String)
        case missingKey(provider: String)

        public var description: String {
            switch self {
            case .unknownProvider(let p): "provider “\(p)” isn't connected"
            case .unsupported(let p, let r): "\(p) can't serve the \(r.rawValue) role"
            case .missingField(let p): "\(p) needs its account details"
            case .missingKey(let p): "\(p) has no API key"
            }
        }
    }

    /// Full resolution with the reason when it fails — doctor and the UI
    /// say *why* a role is idle instead of just showing it off.
    public static func resolve(_ role: ModelRole, config: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment,
                               secret: Secret = keychain) -> Result<Resolved, Problem>? {
        guard let ref = assignment(role, config: config, env: env) else { return nil }
        guard let p = provider(ref.provider, config: config) else {
            return .failure(.unknownProvider(ref.provider))
        }
        guard let base = p.base(role.api, model: ref.model) else {
            return .failure(p.template.fields.isEmpty ? .unsupported(provider: p.name, role: role)
                                                      : .missingField(provider: p.name))
        }
        let key = secret(p)
        if p.needsKey, (key ?? "").isEmpty { return .failure(.missingKey(provider: p.name)) }
        let ctx = env["S1_NUM_CTX"].flatMap(Int.init) ?? (role == .reasoner ? 8192 : 4096)
        let ep = Endpoint(baseURL: base, model: ref.model, apiKey: key, numCtx: ctx)
        return .success(Resolved(role: role, ref: ref, provider: p, endpoint: ep))
    }

    /// The callable endpoint for a role, or nil when it's off or can't
    /// answer yet. A role that can't answer is treated as off — optional
    /// caution and escalation never become a gate.
    public static func endpoint(_ role: ModelRole, config: S1Config = .load(),
                                env: [String: String] = ProcessInfo.processInfo.environment,
                                secret: Secret = keychain) -> Endpoint? {
        guard case .success(let r)? = resolve(role, config: config, env: env, secret: secret) else { return nil }
        return r.endpoint
    }

    // MARK: seeing the screen

    /// Screenshots may go to models at all (config `vision`, default on;
    /// `S1_VISION=off` for one command).
    public static func visionEnabled(config: S1Config = .load(),
                                     env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let e = env["S1_VISION"]?.lowercased() { return !["0", "off", "false", "no"].contains(e) }
        return config.vision ?? true
    }

    /// Can the model on this role read images? The catalog knows its own
    /// models; anything else is judged by its name.
    public static func canSee(_ role: ModelRole, config: S1Config = .load(),
                              env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard role == .judge || role == .reasoner,
              let ref = assignment(role, config: config, env: env) else { return false }
        if let v = provider(ref.provider, config: config)?.option(ref.model)?.vision { return v }
        return role == .judge ? SystemOneClient.acceptsImages(model: ref.model) : looksVisual(ref.model)
    }

    /// Where the screen goes: S1's judge when it can see, S2 when it can —
    /// and nowhere (accessibility tree only) when neither can, or sharing is off.
    public static func seesScreen(_ role: ModelRole, config: S1Config = .load(),
                                  env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        visionEnabled(config: config, env: env) && canSee(role, config: config, env: env)
    }

    /// Name heuristic for models outside the catalog (live lists, custom ids).
    static func looksVisual(_ model: String) -> Bool {
        let m = model.lowercased()
        let tokens = m.split { !($0.isLetter || $0.isNumber || $0 == ".") }.map(String.init)
        if tokens.contains(where: { $0 == "vl" || $0.hasSuffix("vl") || $0 == "vision" || $0.hasSuffix("v") && $0.hasPrefix("glm") }) {
            return true
        }
        let families = ["gpt-4o", "gpt-4.1", "gpt-5", "o3", "o4-mini", "claude", "gemini", "gemma3", "gemma-3",
                        "llava", "pixtral", "mistral-small-3", "llama-4", "llama4", "grok-4", "grok-2-vision",
                        "minicpm-v", "moondream", "qwen-vl", "internvl", "kimi-vl", "phi-4-multimodal"]
        return families.contains { m.contains($0) }
    }

    // MARK: editing (config in memory — callers save)

    public static func assign(_ role: ModelRole, _ ref: ModelRef?, in config: inout S1Config) {
        var m = config.models ?? [:]
        m[role.rawValue] = ref?.description
        config.models = m.isEmpty ? nil : m
        if role == .speak, let ref, let v = provider(ref.provider, config: config)?.option(ref.model)?.voice {
            config.cloudVoice = v
        }
    }

    /// Add (or update) a provider instance, then fill the empty auto roles
    /// with its recommended models. Returns the roles it took over.
    @discardableResult
    public static func connect(_ entry: ProviderConfig, in config: inout S1Config) -> [ModelRole] {
        let id = entry.id
        var ps = config.providers ?? []
        if let i = ps.firstIndex(where: { $0.id == id }) { ps[i] = entry } else { ps.append(entry) }
        config.providers = ps
        guard let p = provider(id, config: config) else { return [] }
        var took: [ModelRole] = []
        for role in ModelRole.allCases where role.autoAssigns && config.models?[role.rawValue] == nil {
            if let m = p.recommended(for: role) {
                assign(role, ModelRef(provider: id, model: m.id), in: &config)
                took.append(role)
            }
        }
        return took
    }

    /// Remove a provider instance and every role pointed at it.
    public static func disconnect(_ id: String, in config: inout S1Config) {
        config.providers?.removeAll { $0.id == id }
        if config.providers?.isEmpty == true { config.providers = nil }
        for role in ModelRole.allCases where assignment(role, config: config, env: [:])?.provider == id {
            assign(role, nil, in: &config)
        }
    }

    /// Roles currently pointed at a provider.
    public static func roles(of id: String, config: S1Config = .load()) -> [ModelRole] {
        ModelRole.allCases.filter { assignment($0, config: config, env: [:])?.provider == id }
    }

    /// A fresh instance id for another copy of a template ("ollama-2").
    public static func newID(for template: String, config: S1Config) -> String {
        let taken = Set((config.providers ?? []).map(\.id))
        guard taken.contains(template) else { return template }
        var n = 2
        while taken.contains("\(template)-\(n)") { n += 1 }
        return "\(template)-\(n)"
    }

    /// Slug for a custom server's id from its display name.
    public static func slug(_ name: String) -> String {
        let s = name.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return s.isEmpty ? "custom" : s
    }
}

// MARK: - Checks + live model lists

public enum ProviderCheck {
    public enum Outcome: Sendable, Equatable {
        case ok(String)
        case failed(String)

        public var ok: Bool { if case .ok = self { return true }; return false }
        public var message: String { switch self { case .ok(let m), .failed(let m): m } }
    }

    /// One real round trip proving the key + server work. Chat providers
    /// list their models; judge-only providers answer a tiny question.
    public static func run(_ p: Provider, key: String?) async -> Outcome {
        let started = Date()
        func ms() -> String { "\(Int(Date().timeIntervalSince(started) * 1000)) ms" }
        if p.needsKey, (key ?? "").isEmpty { return .failed("needs an API key") }
        if p.base(.chat) != nil {
            switch await ModelList.fetch(p, key: key) {
            case .success(let ids):
                return .ok(ids.isEmpty ? "connected · \(ms())" : "\(ids.count) models · \(ms())")
            case .failure(let e): return .failed(e.message)
            }
        }
        let model = p.recommended(for: .judge)?.id ?? p.models(for: .judge).first?.id ?? ""
        guard let base = p.base(.systemOne, model: model) else {
            return .failed(p.template.fields.isEmpty ? "no endpoint" : "fill in \(p.template.fields.map(\.label).joined(separator: ", "))")
        }
        do {
            let r = try await SystemOneClient(endpoint: Endpoint(baseURL: base, model: model, apiKey: key),
                                              timeout: 30)
                .evaluate(state: .string("The user said: open TextEdit."),
                          questions: ["ok": .noul("Does the user want to open an app?")])
            let p = r.answers["ok"]?.noul.map { String(format: "%.2f", $0) } ?? "?"
            return .ok("\(r.model ?? model) answered p=\(p) · \(ms())")
        } catch {
            return .failed(ModelList.Failure.describe(error))
        }
    }

    /// Is a role's assigned model actually there? Listing providers prove
    /// it from `/models`; the rest are trusted once the provider checks out.
    public static func role(_ r: Models.Resolved) async -> Outcome {
        switch r.role.api {
        case .systemOne:
            do {
                let res = try await SystemOneClient(endpoint: r.endpoint, timeout: 60)
                    .evaluate(state: .string("The user said: open TextEdit."),
                              questions: ["ok": .noul("Does the user want to open an app?")])
                let p = res.answers["ok"]?.noul.map { String(format: "%.2f", $0) } ?? "?"
                return .ok("answered p=\(p)")
            } catch {
                return .failed(ModelList.Failure.describe(error))
            }
        case .chat, .audio:
            guard r.provider.template.listsModels else { return await run(r.provider, key: r.endpoint.apiKey) }
            switch await ModelList.fetch(r.provider, key: r.endpoint.apiKey) {
            case .success(let ids):
                return ids.isEmpty || ModelList.contains(ids, r.ref.model)
                    ? .ok("ready")
                    : .failed("“\(r.ref.model)” isn't offered by \(r.provider.name)")
            case .failure(let e): return .failed(e.message)
            }
        }
    }
}

public enum ModelList {
    public struct Failure: Error, Sendable {
        public var message: String
        static func describe(_ e: Error) -> String {
            let s = e.localizedDescription
            if s.contains("401") || s.contains("403") { return "key rejected" }
            if (e as? URLError)?.code == .cannotConnectToHost || (e as? URLError)?.code == .timedOut {
                return "server unreachable"
            }
            return s
        }
    }

    /// Model ids a provider reports. OpenAI shape `{"data":[{"id"}]}`,
    /// Ollama shape `{"models":[{"name"}]}` (tried at the server root).
    public static func fetch(_ p: Provider, key: String?) async -> Result<[String], Failure> {
        guard let chat = p.base(.chat) else { return .failure(.init(message: "no chat endpoint")) }
        var urls = [chat + "/models"]
        if chat.hasSuffix("/v1") { urls.append(String(chat.dropLast(3)) + "/api/tags") }
        var last = Failure(message: "server unreachable")
        for s in urls {
            guard let url = URL(string: s) else { continue }
            var req = URLRequest(url: url)
            req.timeoutInterval = 6
            if let key, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 { return .failure(.init(message: "key rejected")) }
                guard code == 200 else { last = .init(message: "HTTP \(code)"); continue }
                return .success(parse(data))
            } catch {
                last = .init(message: Failure.describe(error))
            }
        }
        return .failure(last)
    }

    static func parse(_ data: Data) -> [String] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var names: [String] = []
        if let d = obj["data"] as? [[String: Any]] { names += d.compactMap { $0["id"] as? String } }
        if let m = obj["models"] as? [[String: Any]] {
            names += m.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Tags match loosely: "nimble" finds "nimble:latest".
    public static func contains(_ ids: [String], _ want: String) -> Bool {
        let w = want.lowercased()
        return ids.contains { n in
            let s = n.lowercased()
            return s == w || s.hasPrefix(w + ":") || w.hasPrefix(s + ":")
        }
    }
}

public enum Endpoints {
    public static func isLocal(_ base: String) -> Bool {
        guard let host = URL(string: base)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}
