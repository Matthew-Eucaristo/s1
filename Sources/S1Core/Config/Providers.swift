import Foundation

/// One named endpoint preset — the "just pick it from the menu" entry.
/// Everything a role needs to connect: base URL, model, and a hint line
/// the UI can show under the label.
public struct ProviderPreset: Codable, Sendable, Equatable {
    /// Stable id — user file entries with the same id replace the builtin.
    public var id: String
    /// Menu label, e.g. "OpenCode Go · DeepSeek V4.1 Flash".
    public var label: String
    /// Which role this preset feeds: decision | s2 | vlm | grounder | stt | tts.
    public var role: String
    public var base: String
    public var model: String
    /// Free-text hint (where to get a key, what to replace in the URL).
    public var note: String?
    /// Shown first / marked as the default pick.
    public var recommended: Bool?
    /// Provider-side voice name for TTS presets ("troy", "alloy") —
    /// unrelated to the local Apple voice picker. nil elsewhere.
    public var voice: String?
    /// Provider family id ("groq", "openai", "gemini") — presets sharing a
    /// family appear as one provider in the Connect list, with a pill per
    /// role they cover. nil = its own single-role family.
    public var family: String?

    public init(id: String, label: String, role: String, base: String,
                model: String, note: String? = nil, recommended: Bool? = nil,
                voice: String? = nil, family: String? = nil) {
        self.id = id; self.label = label; self.role = role
        self.base = base; self.model = model
        self.note = note; self.recommended = recommended
        self.voice = voice; self.family = family
    }
}

/// A provider as the user thinks of it: one account, one API key, several
/// roles it can fill. Derived by grouping presets on `family` — the
/// Connect list in Settings renders these with a pill per covered role.
public struct ProviderFamily: Sendable, Equatable {
    public var id: String
    /// Display name — "Groq", "OpenAI". Derived from the first preset's
    /// label (text before " · "), or titlecased id when that's empty.
    public var name: String
    /// Setup hint lifted from the family's most informative note.
    public var note: String?
    /// Every preset in the family — the "Connect" action applies them all.
    public var presets: [ProviderPreset]
    /// Role tags for the pills, in fixed display order.
    public var roles: [String] {
        let order = ["decision", "vlm", "grounder", "s2", "stt", "tts"]
        let have = Set(presets.map(\.role))
        return order.filter { have.contains($0) }
    }

    /// Keychain account for this provider's own key — distinct from the
    /// per-role accounts the runtime reads, so one provider's key never
    /// makes another provider look connected.
    public var keyAccount: String { "provider.\(id)" }

    /// Does `base` (a role's live endpoint) belong to this provider for
    /// that role? Host + port match against the family's presets, so a
    /// role pointed at TypeSafe never shows up as "in use" on Liquid's card.
    public func owns(role: String, base: String) -> Bool {
        guard let mine = Self.hostPort(base) else { return false }
        return presets.contains { $0.role == role && Self.hostPort($0.base) == mine }
    }

    static func hostPort(_ s: String) -> String? {
        guard let u = URL(string: s), let h = u.host?.lowercased(), !h.isEmpty else { return nil }
        return u.port.map { "\(h):\($0)" } ?? h
    }
}

/// The provider catalog as DATA — `~/.s1/providers.json` is a plain JSON
/// array the user can edit, extend, or override without touching code.
/// Same convention as snippets.json: the file replaces nothing on disk
/// until written; builtin entries always exist, user entries with a
/// matching `id` replace them, new ids append after the builtins.
public enum Providers {
    public static var path: URL { URL(fileURLWithPath: S1Home.path + "/providers.json") }

    /// Roles the catalog knows — file entries with an unknown role get
    /// flagged by `s1 doctor` instead of silently doing nothing.
    public static let roles: Set<String> = [
        "decision", "s2", "vlm", "grounder", "stt", "tts",
    ]

    /// Shipped defaults — every endpoint s1 can use, with the model that
    /// works best out of the box. Only the `note` fields that need real
    /// setup steps carry them.
    public static let builtin: [ProviderPreset] = [
        // S1 decision judge — typed yes/no · choice · score.
        .init(id: "typesafe-jev", label: "TypeSafe · Jev (recommended)",
              role: "decision", base: Endpoints.defaultDecisionBase,
              model: Endpoints.defaultDecisionModel,
              note: "get a key at typesafe.ai", recommended: true,
              family: "typesafe"),
        .init(id: "liquid-d1-free", label: "Liquid AI · d1 free tier (vision)",
              role: "decision", base: "https://api.liquid.ai/decisions",
              model: "d1:free", note: "console.liquid.ai, `liquid_…` key",
              family: "liquid"),
        .init(id: "liquid-d1", label: "Liquid AI · d1 (vision)",
              role: "decision", base: "https://api.liquid.ai/decisions", model: "d1",
              note: "console.liquid.ai, `liquid_…` key", family: "liquid"),
        .init(id: "cf-clef-flash", label: "Cloudflare · Clef Flash (Workers AI, vision)",
              role: "decision",
              base: "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/ai/run/@cf/cloudflare/clef-flash",
              model: "clef-flash", note: "API token; replace <ACCOUNT_ID>",
              family: "cloudflare"),
        .init(id: "cf-clef", label: "Cloudflare · Clef (Workers AI, vision)",
              role: "decision",
              base: "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/ai/run/@cf/cloudflare/clef",
              model: "clef", note: "API token; replace <ACCOUNT_ID>",
              family: "cloudflare"),
        .init(id: "cf-llama", label: "Cloudflare · Workers AI Llama (OpenAI-compat)",
              role: "s2",
              base: "https://api.cloudflare.com/client/v4/accounts/<ACCOUNT_ID>/ai/v1",
              model: "@cf/meta/llama-3.3-70b-instruct-fp8-fast",
              note: "API token; replace <ACCOUNT_ID>", family: "cloudflare"),
        .init(id: "ollama-nimble", label: "Local · Ollama nimble 9B (advanced)",
              role: "decision", base: "http://localhost:11434", model: "nimble",
              family: "ollama"),
        .init(id: "ollama-tev1", label: "Local · Ollama tev1 4B (advanced)",
              role: "decision", base: "http://localhost:11434", model: "tev1",
              family: "ollama"),
        .init(id: "ollama-clef-flash", label: "Local · Ollama clef-flash 9B (advanced)",
              role: "decision", base: "http://localhost:11434", model: "clef-flash",
              family: "ollama"),
        .init(id: "off", label: "Off (AX-only decisions)", role: "decision",
              base: Endpoints.defaultDecisionBase, model: "", family: "builtin"),

        // S2 reasoning.
        .init(id: "opencode-flash", label: "OpenCode Go · DeepSeek V4.1 Flash (recommended)",
              role: "s2", base: Endpoints.defaultS2Base,
              model: Endpoints.defaultS2Model,
              note: "subscription key from opencode.ai", recommended: true,
              family: "opencode"),
        .init(id: "opencode-pro", label: "OpenCode Go · DeepSeek V4 Pro",
              role: "s2", base: Endpoints.defaultS2Base, model: "deepseek-v4-pro",
              note: "subscription key from opencode.ai", family: "opencode"),
        .init(id: "deepseek-flash", label: "DeepSeek API · V4.1 Flash",
              role: "s2", base: "https://api.deepseek.com", model: "deepseek-flash",
              family: "deepseek"),
        .init(id: "openrouter", label: "OpenRouter", role: "s2",
              base: "https://openrouter.ai/api/v1", model: "openai/gpt-oss-120b",
              note: "openrouter.ai key — any model id works", family: "openrouter"),
        .init(id: "openrouter-claude", label: "OpenRouter · Claude", role: "s2",
              base: "https://openrouter.ai/api/v1", model: "anthropic/claude-sonnet-4.5",
              note: "OpenRouter key — Claude has no OpenAI-compatible API of its own",
              family: "openrouter"),
        .init(id: "openrouter-gpt", label: "OpenRouter · GPT", role: "s2",
              base: "https://openrouter.ai/api/v1", model: "openai/gpt-5",
              family: "openrouter"),
        .init(id: "openrouter-gemini", label: "OpenRouter · Gemini", role: "s2",
              base: "https://openrouter.ai/api/v1", model: "google/gemini-2.5-flash",
              family: "openrouter"),
        .init(id: "openai", label: "OpenAI", role: "s2",
              base: "https://api.openai.com/v1", model: "gpt-5-mini",
              note: "platform.openai.com API key", family: "openai"),
        .init(id: "gemini", label: "Google · Gemini (AI Studio)", role: "s2",
              base: "https://generativelanguage.googleapis.com/v1beta/openai",
              model: "gemini-2.5-flash", note: "aistudio.google.com API key",
              family: "gemini"),
        .init(id: "xai", label: "xAI · Grok", role: "s2",
              base: "https://api.x.ai/v1", model: "grok-4-fast",
              note: "console.x.ai API key", family: "xai"),
        .init(id: "groq", label: "Groq", role: "s2",
              base: "https://api.groq.com/openai/v1", model: "openai/gpt-oss-120b",
              family: "groq"),
        .init(id: "ollama-gemma", label: "Local · Ollama (advanced)", role: "s2",
              base: "http://localhost:11434/v1", model: "gemma3:4b",
              family: "ollama"),

        // STT — OpenAI-compatible /v1/audio/transcriptions.
        .init(id: "stt-apple", label: "Off · on-device Apple (default)", role: "stt",
              base: "", model: "", recommended: true, family: "builtin"),
        .init(id: "stt-groq-turbo", label: "Groq · Whisper Large v3 Turbo (fast)", role: "stt",
              base: "https://api.groq.com/openai/v1", model: "whisper-large-v3-turbo",
              note: "console.groq.com key", family: "groq"),
        .init(id: "stt-groq", label: "Groq · Whisper Large v3 (most accurate)", role: "stt",
              base: "https://api.groq.com/openai/v1", model: "whisper-large-v3",
              note: "console.groq.com key", family: "groq"),
        .init(id: "stt-openai", label: "OpenAI · gpt-4o-mini-transcribe", role: "stt",
              base: "https://api.openai.com/v1", model: "gpt-4o-mini-transcribe",
              family: "openai"),
        .init(id: "stt-local", label: "Local · OpenAI-compatible server (Speaches, NVIDIA NIM…)",
              role: "stt", base: "http://localhost:8000/v1",
              model: "Systran/faster-whisper-large-v3", family: "local"),

        // TTS — OpenAI-compatible /v1/audio/speech.
        .init(id: "tts-apple", label: "Off · Apple voices (default)", role: "tts",
              base: "", model: "", recommended: true, family: "builtin"),
        .init(id: "tts-groq", label: "Groq · Orpheus English", role: "tts",
              base: "https://api.groq.com/openai/v1", model: "canopylabs/orpheus-v1-english",
              note: "console.groq.com key", voice: "troy", family: "groq"),
        .init(id: "tts-groq-id", label: "Groq · Orpheus Indonesian", role: "tts",
              base: "https://api.groq.com/openai/v1", model: "canopylabs/orpheus-v1-indonesian",
              note: "console.groq.com key", voice: "troy", family: "groq"),
        .init(id: "tts-openai", label: "OpenAI · gpt-4o-mini-tts", role: "tts",
              base: "https://api.openai.com/v1", model: "gpt-4o-mini-tts", voice: "alloy",
              family: "openai"),
        .init(id: "tts-local", label: "Local · OpenAI-compatible server", role: "tts",
              base: "http://localhost:8000/v1", model: "tts-1", family: "local"),
    ]

    /// Builtin ∪ user file. User entries sharing a builtin `id` replace it
    /// in place (keeping the menu order stable); new ids append at the end
    /// of their role group. A `_comment`-keyed object is skipped so the
    /// file can carry a header note.
    public static func all() -> [ProviderPreset] {
        merge(file())
    }

    /// The merge itself — separated from disk so tests can drive it.
    static func merge(_ user: [ProviderPreset]) -> [ProviderPreset] {
        var out = builtin
        for p in user {
            if let i = out.firstIndex(where: { $0.id == p.id }) {
                out[i] = p
            } else {
                // Insert after the last builtin of the same role so each
                // role's menu stays contiguous.
                if let j = out.lastIndex(where: { $0.role == p.role }) {
                    out.insert(p, at: j + 1)
                } else {
                    out.append(p)
                }
            }
        }
        return out
    }

    /// Presets for one role — what the settings menus render.
    public static func presets(role: ModelRole) -> [ProviderPreset] {
        all().filter { $0.role == role.rawValue }
    }

    /// Providers grouped for the Connect list — one row per family, pills
    /// for the roles it covers. First-seen order follows the catalog, so
    /// recommended providers float to the top. "builtin" (the on-device /
    /// off rows) is excluded — there's nothing to connect.
    public static func families() -> [ProviderFamily] {
        var order: [String] = []
        var grouped: [String: [ProviderPreset]] = [:]
        for p in all() {
            let f = p.family ?? p.id
            if grouped[f] == nil { order.append(f); grouped[f] = [] }
            grouped[f]?.append(p)
        }
        return order.compactMap { id in
            guard id != "builtin", let ps = grouped[id] else { return nil }
            // Display name = text before " · " in the first real label,
            // falling back to a titlecased id.
            let name = ps.lazy.map(\.label)
                .first { !$0.isEmpty }?
                .components(separatedBy: " · ").first ?? id.capitalized
            return ProviderFamily(id: id, name: name,
                                  note: ps.lazy.compactMap(\.note).first,
                                  presets: ps)
        }
    }

    /// Raw user file entries (empty when the file is absent/malformed).
    public static func file() -> [ProviderPreset] {
        guard let d = try? Data(contentsOf: path) else { return [] }
        return (try? JSONDecoder().decode([ProviderPreset].self, from: d)) ?? []
    }

    /// Writes every entry of `presets` — used by `s1 doctor --write-defaults`
    /// and the "Open providers.json" affordance so the file exists with
    /// something meaningful in it.
    public static func ensureFile() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try? save(builtin)
    }

    public static func save(_ presets: [ProviderPreset]) throws {
        S1Home.ensurePrivate()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(presets).write(to: path, options: .atomic)
    }

    /// Light structural validation — `s1 doctor` surfaces these as
    /// findings instead of a decode failure silently zeroing the file.
    public static func validate(_ presets: [ProviderPreset]) -> [String] {
        var issues: [String] = []
        var seen = Set<String>()
        for p in presets {
            if p.id.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("a preset has an empty id")
            } else if !seen.insert(p.id).inserted {
                issues.append("duplicate id '\(p.id)'")
            }
            if !roles.contains(p.role) {
                issues.append("'\(p.id)': unknown role '\(p.role)' (expected \(roles.sorted().joined(separator: ", ")))")
            }
            if p.label.trimmingCharacters(in: .whitespaces).isEmpty {
                issues.append("'\(p.id)': empty label")
            }
            // An empty base is only meaningful for the on-device/off rows.
            if !p.base.isEmpty && URL(string: p.base)?.scheme == nil {
                issues.append("'\(p.id)': base '\(p.base)' is not a URL")
            }
        }
        return issues
    }
}
