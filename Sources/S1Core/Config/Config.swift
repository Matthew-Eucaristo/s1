import Foundation

/// User configuration at `~/.s1/config.json` — one plain file the app and
/// the CLI share. Environment variables win over the file, CLI flags win
/// over both.
///
/// ```json
/// {
///   "providers": [{ "id": "typesafe" }, { "id": "opencode" }, { "id": "ollama" }],
///   "models": {
///     "judge": "typesafe/jev-latest",
///     "reasoner": "opencode/deepseek-v4.1-flash"
///   },
///   "locale": "auto",
///   "speak": true
/// }
/// ```
///
/// Keys never live here — `s1 connect <provider>` (or Settings → Models)
/// puts them in the login Keychain.
public struct S1Config: Codable, Sendable {
    /// Connected providers, in the order they were added.
    public var providers: [ProviderConfig]?
    /// Role → `provider/model`. A missing role is off (speech roles fall
    /// back to on-device Apple speech).
    public var models: [String: String]?
    /// Provider-side TTS voice for the `speak` role ("troy", "alloy").
    public var cloudVoice: String?
    /// Let models that can read images see the screen (nil = on).
    public var vision: Bool?
    /// Let the Reasoner search the web when its provider or model can (nil = on).
    public var webSearch: Bool?
    /// Ask the Reasoner for JSON-schema output where the provider has it
    /// (nil = on; providers without it are detected and skipped).
    public var structuredOutput: Bool?
    /// Give the Reasoner the user's agent files: AGENTS.md and Agent Skills
    /// (SKILL.md) from ~/.s1, ~/.agents and ~/.claude (nil = off).
    public var agentFiles: Bool?
    /// MCP servers whose tools the Reasoner may use, by name — the same
    /// shape MCP clients use (`command` + `args` + `env`). nil = none.
    public var mcpServers: [String: MCPServerConfig]?
    /// OpenTelemetry trace export (nil = off).
    public var telemetry: TelemetryConfig?

    public var locale: String?
    public var speak: Bool?
    /// Extra words/phrases the STT should bias toward (app names, jargon).
    /// Apple's contextual-strings limit is 100 total — s1 prepends installed
    /// app names after these, so user entries always win.
    public var vocabulary: [String]?
    /// Last-run goals — the app's command field suggests these first.
    public var recent: [String]?
    /// The app's floating notch HUD (status pill under the camera notch).
    public var notchHUD: Bool?
    /// Apple TTS voice identifier ("" / nil = best installed voice per language).
    public var voice: String?
    /// Action executor: nil/"cua" = Cua Driver when installed (default), "cgevent" = never Cua.
    public var executor: String?
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
    /// → the app opens the setup wizard.
    public var onboarded: Bool?

    public init() {}

    public static var path: String { S1Home.path + "/config.json" }

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
        // ~/.s1 holds run artifacts with goal text + screenshots — owner-only, like ~/.ssh.
        S1Home.ensurePrivate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Like `load`, but a file that exists and doesn't parse is an error,
    /// not an empty config — anything that saves must not replace a
    /// hand-edited file with a typo by `{}` (every provider and role gone).
    /// Missing or blank = empty config.
    public static func loadForWriting(from path: String = S1Config.path) throws -> S1Config {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              !String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return S1Config() }
        do { return try JSONDecoder().decode(S1Config.self, from: data) } catch {
            throw S1Error.actionFailed(
                "\(path) isn't valid (\(Self.decodeProblem(error))) — fix it by hand or move it away; s1 left it as it is")
        }
    }

    /// Where a decode failed, in a few words ("vision: expected a Bool").
    static func decodeProblem(_ error: Error) -> String {
        switch error as? DecodingError {
        case .typeMismatch(let t, let c)?, .valueNotFound(let t, let c)?:
            let at = c.codingPath.map(\.stringValue).joined(separator: ".")
            return "\(at.isEmpty ? "top level" : at): expected \(t)"
        case .dataCorrupted(let c)?:
            return c.underlyingError.map { ($0 as NSError).localizedDescription } ?? c.debugDescription
        default:
            return error.localizedDescription
        }
    }

    /// Load → mutate → save in one step, so concurrent writers (app panes,
    /// CLI) only ever touch the keys they own. Throws, saving nothing, when
    /// the file on disk can't be read.
    public static func update(at path: String = S1Config.path, _ body: (inout S1Config) -> Void) throws {
        var c = try loadForWriting(from: path)
        body(&c)
        try c.save(to: path)
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
}
