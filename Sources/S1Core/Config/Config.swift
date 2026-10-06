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
        // ~/.s1 holds run artifacts with goal text + screenshots — owner-only, like ~/.ssh.
        S1Home.ensurePrivate()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
    }

    /// Load → mutate → save in one step, so concurrent writers (app panes,
    /// CLI) only ever touch the keys they own.
    public static func update(at path: String = S1Config.path, _ body: (inout S1Config) -> Void) throws {
        var c = load(from: path)
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
