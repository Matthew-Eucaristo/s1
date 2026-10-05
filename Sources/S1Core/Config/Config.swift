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
///   "vocabulary": ["s1", "Warp", "Linear"],
///   "vlmScreenshot": true
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
    /// Last-run goals — the app's command field suggests these first.
    public var recent: [String]?
    /// Whether the VLM brain attaches a screenshot per step (app toggle).
    public var vlmScreenshot: Bool?
    /// The app's chosen System 1 ("auto" | "ax" | "vlm") — persisted so a
    /// restart keeps the brain the user picked.
    public var brain: String?
    /// Whether the app escalates low-confidence steps to S2.
    public var useS2: Bool?
    /// The app's floating notch HUD (status pill under the camera notch).
    public var notchHUD: Bool?
    /// Optional GUI-grounding specialist for click targets (see `Grounder`).
    public var grounder: ModelEndpoint?
    /// S1 decision model (System One API: Ollama `/v1/systemone`, TypeSafe
    /// Jev, Cloudflare Clef). nil = default (`nimble` when pulled); an
    /// empty model = judge off.
    public var decision: ModelEndpoint?
    /// TTS voice identifier ("" / nil = best installed voice per language).
    public var voice: String?
    /// Action executor: nil/"cua" = Cua Driver when installed (default), "cgevent" = never Cua.
    public var executor: String?
    /// Optional cloud STT / TTS (nil = on-device Apple speech).
    public var stt: ModelEndpoint?
    public var tts: ModelEndpoint?
    /// Cloud TTS voice name (provider-specific, e.g. "troy", "alloy").
    public var ttsCloudVoice: String?
    /// Persistent memory (~/.s1/memory.md + ~/.s1/memory/ topics); nil = on.
    public var memory: Bool?
    /// Voice interrupt (barge-in): while a run or the TTS reply is in
    /// flight a sustained voice burst aborts it — nil/true = on.
    public var voiceInterrupt: Bool?
    /// Turn-end detector: "auto" (Apple SpeechDetector when the modern
    /// transcriber runs, energy endpointer otherwise), "energy" (RMS
    /// endpointer only — deterministic, no detector module).
    public var vad: String?
    /// Endpointer/detector sensitivity: "low" | "medium" | "high".
    public var vadSensitivity: String?
    /// Shell sandbox: nil/"off" = gated shell actions run under plain zsh
    /// (default); "srt" = wrap them in Anthropic sandbox-runtime — Seatbelt
    /// fs rules + network proxy from ~/.s1/srt-settings.json.
    public var sandbox: String?
    /// First-run onboarding completed (or deliberately skipped). nil/false
    /// → the app opens the setup wizard; the CLI nags once at `s1 status`.
    public var onboarded: Bool?
    /// Which built-in defaults this file was written under (nil = pre-hosted).
    public var defaultsVersion: Int?
    public static let currentDefaults = 3

    public init(vlm: ModelEndpoint? = nil, s2: ModelEndpoint? = nil,
                locale: String? = nil, speak: Bool? = nil,
                vocabulary: [String]? = nil, recent: [String]? = nil,
                vlmScreenshot: Bool? = nil, brain: String? = nil,
                useS2: Bool? = nil, notchHUD: Bool? = nil,
                grounder: ModelEndpoint? = nil) {
        self.vlm = vlm; self.s2 = s2; self.locale = locale; self.speak = speak
        self.vocabulary = vocabulary
        self.recent = recent
        self.vlmScreenshot = vlmScreenshot
        self.brain = brain
        self.useS2 = useS2
        self.notchHUD = notchHUD
        self.grounder = grounder
    }

    public static var path: String { NSHomeDirectory() + "/.s1/config.json" }

    /// Missing or malformed file → empty config (defaults apply). Never throws:
    /// config is a convenience, not a gate.
    public static func load(from path: String = S1Config.path) -> S1Config {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              var c = try? JSONDecoder().decode(S1Config.self, from: data) else {
            return S1Config()
        }
        c.migrateToHostedDefaults()
        return c
    }

    /// Files written before the hosted defaults pinned the old local ones
    /// (the app always saves every field). Move only untouched old defaults
    /// — local nimble judge, local gemma3:4b S2, S2 off — to Jev + OpenCode
    /// Go; anything the user picked themselves stays. Keys are kept.
    public mutating func migrateToHostedDefaults() {
        let v = defaultsVersion ?? 0
        guard v < Self.currentDefaults else { return }
        defaultsVersion = Self.currentDefaults
        migrateVisionOff(from: v)
        guard v < 2 else { return }
        if let d = decision, Endpoints.isLocal(d.base ?? "http://localhost:11434"), d.model == "nimble" {
            decision = .init(base: Endpoints.defaultDecisionBase, model: Endpoints.defaultDecisionModel, key: d.key)
        }
        if let s = s2, Endpoints.isLocal(s.base ?? "http://localhost:11434/v1"), (s.model ?? "gemma3:4b") == "gemma3:4b" {
            s2 = .init(base: Endpoints.defaultS2Base, model: Endpoints.defaultS2Model, key: s.key, numCtx: s.numCtx)
            if useS2 == false { useS2 = true }
        }
    }

    /// v3: vision + grounder are opt-in — an untouched local gemma3:4b VLM
    /// (the old default) becomes "off" so Auto stays on the AX grammar.
    private mutating func migrateVisionOff(from v: Int) {
        guard v < 3, let m = vlm, Endpoints.isLocal(m.base ?? "http://localhost:11434/v1"),
              (m.model ?? "gemma3:4b") == "gemma3:4b" else { return }
        vlm = .init(base: m.base, model: "", key: m.key, numCtx: m.numCtx)
    }

    public func save(to path: String = S1Config.path) throws {
        let url = URL(fileURLWithPath: path)
        // ~/.s1 holds credentials + run artifacts — owner-only, like ~/.ssh.
        S1Home.ensurePrivate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(self).write(to: url, options: .atomic)
        // The file can carry API keys — keep it owner-only (600), like
        // ~/.ssh/config. Non-destructive: silently skip if chmod fails.
        if vlm?.key != nil || s2?.key != nil || grounder?.key != nil {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }
}

/// Resolved model endpoints — precedence: explicit arg > env var > config file > built-in default.
public enum Endpoints {
    public static func vlm(base: String? = nil, model: String? = nil,
                           env: [String: String] = ProcessInfo.processInfo.environment,
                           config: S1Config = .load(),
        secret: (ModelRole) -> String? = Endpoints.keychainSecret) -> Endpoint {
        let b = base ?? env["S1_VLM_BASE"] ?? config.vlm?.base ?? "http://localhost:11434/v1"
        let s2Base = env["S1_S2_BASE"] ?? config.s2?.base ?? defaultS2Base
        // Same provider as S2 (e.g. one OpenCode Go subscription) → one key.
        let shared = sameHost(b, s2Base) ? (env["S1_S2_KEY"] ?? secret(.s2) ?? config.s2?.key) : nil
        return Endpoint(
            baseURL: b,
            model: model ?? env["S1_VLM_MODEL"] ?? config.vlm?.model ?? "",
            apiKey: env["S1_VLM_KEY"] ?? secret(.vlm) ?? config.vlm?.key ?? shared,
            // 4k covers the decision prompt (AX digest + format) with room —
            // 8k just doubles the KV allocation on tight 16GB machines.
            numCtx: env["S1_NUM_CTX"].flatMap(Int.init) ?? config.vlm?.numCtx ?? 4096)
    }

    public static func s2(env: [String: String] = ProcessInfo.processInfo.environment,
                          config: S1Config = .load(),
        secret: (ModelRole) -> String? = Endpoints.keychainSecret) -> Endpoint {
        Endpoint(
            baseURL: env["S1_S2_BASE"] ?? config.s2?.base ?? defaultS2Base,
            model: env["S1_S2_MODEL"] ?? config.s2?.model ?? defaultS2Model,
            apiKey: env["S1_S2_KEY"] ?? secret(.s2) ?? config.s2?.key,
            numCtx: env["S1_NUM_CTX"].flatMap(Int.init) ?? config.s2?.numCtx ?? 8192)
    }

    /// Grounder endpoint, or nil when no grounding model is configured —
    /// opt-in: a model the user never pulled must not sit in the click path.
    /// Base defaults to the VLM's server (same Ollama, one more model).
    public static func grounder(env: [String: String] = ProcessInfo.processInfo.environment,
                                config: S1Config = .load(),
        secret: (ModelRole) -> String? = Endpoints.keychainSecret) -> Endpoint? {
        guard let model = env["S1_GROUNDER_MODEL"] ?? config.grounder?.model,
              !model.isEmpty else { return nil }
        return Endpoint(
            baseURL: env["S1_GROUNDER_BASE"] ?? config.grounder?.base
                ?? env["S1_VLM_BASE"] ?? config.vlm?.base ?? "http://localhost:11434/v1",
            model: model,
            apiKey: env["S1_GROUNDER_KEY"] ?? secret(.grounder) ?? config.grounder?.key,
            numCtx: config.grounder?.numCtx ?? 4096)
    }
    /// Keychain lookup for a role's API key — the default secret source.
    public static func keychainSecret(_ role: ModelRole) -> String? {
        SecretStore.get(account: role.rawValue)
    }

    /// Hosted defaults: TypeSafe Jev judges S1 steps, OpenCode Go serves
    /// S2 (DeepSeek V4.1 Flash, OpenAI chat-completions). Local Ollama
    /// models stay selectable in Settings but aren't the default.
    public static let defaultDecisionBase = "https://api.typesafe.ai"
    public static let defaultDecisionModel = "jev-latest"
    public static let defaultS2Base = "https://opencode.ai/zen/go/v1"
    public static let defaultS2Model = "deepseek-v4.1-flash"

    /// Decision-model endpoint, or nil when the judge is off. Base is the
    /// server root: `http://localhost:11434` (Ollama ≥ 0.35),
    /// `https://api.typesafe.ai` (Jev), or a full Cloudflare
    /// `…/ai/run/@cf/cloudflare/clef` URL.
    ///
    /// Unset → hosted Jev. An empty or "off" model turns the judge off. A
    /// hosted judge with no API key, or a local Ollama model that isn't
    /// pulled yet, resolves to nil instead of failing every step — the judge
    /// is optional caution, never a gate.
    public static func decision(env: [String: String] = ProcessInfo.processInfo.environment,
                                config: S1Config = .load(),
                                secret: (ModelRole) -> String? = Endpoints.keychainSecret,
                                installed: () -> [String]? = Endpoints.localModels) -> Endpoint? {
        let model = (env["S1_DECISION_MODEL"] ?? config.decision?.model ?? defaultDecisionModel)
            .trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty, model.lowercased() != "off" else { return nil }
        let base = env["S1_DECISION_BASE"] ?? config.decision?.base ?? defaultDecisionBase
        let key = env["S1_DECISION_KEY"] ?? secret(.decision) ?? config.decision?.key
        if isLocal(base) {
            if let have = installed(), !ModelPull.contains(have, model) { return nil }
        } else if (key ?? "").isEmpty {
            return nil
        }
        return Endpoint(baseURL: base, model: model, apiKey: key)
    }

    /// `ollama list`, or nil when the Ollama CLI isn't here to ask (a remote
    /// or containerized server can't be checked, so it's trusted).
    public static func localModels() -> [String]? {
        ModelPull.ollamaBinary() == nil ? nil : ModelPull.installed()
    }

    static func sameHost(_ a: String, _ b: String) -> Bool {
        guard let x = URL(string: a)?.host?.lowercased(), let y = URL(string: b)?.host?.lowercased(),
              !isLocal(a) else { return false }
        return x == y
    }

    public static func isLocal(_ base: String) -> Bool {
        guard let host = URL(string: base)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}


public extension S1Config {
    /// Voice-interrupt resolution: `S1_VOICE_INTERRUPT` (0/false/off) wins,
    /// then config.json, default on.
    static func voiceInterruptEnabled(env: [String: String] = ProcessInfo.processInfo.environment,
                                      config: S1Config = .load()) -> Bool {
        if let e = env["S1_VOICE_INTERRUPT"]?.lowercased() {
            return !(e == "0" || e == "false" || e == "off")
        }
        return config.voiceInterrupt ?? true
    }

    /// Drop a role's plaintext `key` from config.json once the Keychain owns
    /// it — a key must not linger in a file after moving to the Keychain.
    static func stripPlaintextKey(_ role: ModelRole, path: String = S1Config.path) throws {
        guard FileManager.default.fileExists(atPath: path) else { return }
        var c = S1Config.load(from: path)
        switch role {
        case .vlm: guard c.vlm?.key != nil else { return }; c.vlm?.key = nil
        case .s2: guard c.s2?.key != nil else { return }; c.s2?.key = nil
        case .grounder: guard c.grounder?.key != nil else { return }; c.grounder?.key = nil
        case .decision: guard c.decision?.key != nil else { return }; c.decision?.key = nil
        case .stt: guard c.stt?.key != nil else { return }; c.stt?.key = nil
        case .tts: guard c.tts?.key != nil else { return }; c.tts?.key = nil
        }
        try c.save(to: path)
    }
}
