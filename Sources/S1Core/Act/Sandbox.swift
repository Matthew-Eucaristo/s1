import Foundation

/// Anthropic sandbox-runtime (`srt`) — optional seatbelt for the `.shell`
/// action. OFF by default: set `sandbox: "srt"` in ~/.s1/config.json (or
/// `S1_SANDBOX=srt`) and every gated shell command runs inside Seatbelt
/// + a network-filtering proxy instead of bare zsh.
///
/// Install: `npm i -g @anthropic-ai/sandbox-runtime` (needs Node).
/// Policy lives in `~/.s1/srt-settings.json` — editable like every other
/// s1 file; a cautious default is written the first time it's needed.
///
/// https://github.com/anthropics/sandbox-runtime · Apache-2.0
public enum Sandbox {
    /// `~/.s1/srt-settings.json` — the network/filesystem policy srt enforces.
    public static var settingsPath: URL {
        URL(fileURLWithPath: S1Home.path + "/srt-settings.json")
    }

    /// The `srt` binary — global npm install lands in one of these; a
    /// PATH walk covers nvm/volta setups the fixed list misses.
    public static func srtBinary() -> String? {
        let home = NSHomeDirectory()
        let known = [
            home + "/.local/bin/srt",
            "/opt/homebrew/bin/srt",
            "/usr/local/bin/srt",
            home + "/.npm-global/bin/srt",
            home + "/.volta/bin/srt",
            home + "/.nvm/current/bin/srt",
        ]
        for p in known where FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = String(dir) + "/srt"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// The shell command to install srt — surfaced in Settings + `s1 setup`.
    public static let installHint = "npm install -g @anthropic-ai/sandbox-runtime"

    /// Config gate: `sandbox == "srt"` in config.json or `S1_SANDBOX=srt`.
    /// Anything else (missing, "off") is the default — bare zsh like today.
    public static func enabled(cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        let v = env["S1_SANDBOX"] ?? cfg.sandbox ?? ""
        return v == "srt"
    }

    /// First-run policy, written once and then owned by the user.
    /// Deny-by-default network (nothing an agent shell needs reaches out),
    /// and writes restricted to the cwd + caches while credential and
    /// config stores are read-protected. Users relax it by editing the file.
    public static let defaultSettings = """
    {
      "network": {
        "allowedDomains": [],
        "deniedDomains": []
      },
      "filesystem": {
        "denyRead": [
          "~/.ssh",
          "~/.aws",
          "~/.gnupg",
          "~/Library/Keychains",
          "~/.s1/config.json",
          "~/.s1/usage.jsonl"
        ],
        "allowWrite": [
          ".",
          "/tmp",
          "~/Library/Caches"
        ],
        "denyWrite": [
          "~/.s1",
          "~/.ssh",
          "~/.aws",
          "~/.config",
          "~/.zshrc",
          "~/.bashrc"
        ]
      }
    }
    """

    /// Materialize the policy file if it's missing — best effort, never
    /// throws: a write failure just means srt falls back to its defaults.
    @discardableResult
    public static func ensureSettingsFile() -> String {
        let p = settingsPath.path
        if !FileManager.default.fileExists(atPath: p) {
            S1Home.ensurePrivate()
            try? defaultSettings.write(toFile: p, atomically: true, encoding: .utf8)
        }
        return p
    }

    /// Where a gated shell command runs: where s1 was started (a project
    /// folder for `s1 run`), unless that is "/" (launchd, the app) — then
    /// a sandboxed shell gets a scratch folder the policy lets it write
    /// ("." would otherwise mean the whole disk) and a bare one the home
    /// folder, like a new Terminal window.
    public static func workingDirectory(sandboxed: Bool,
                                        cwd: String = FileManager.default.currentDirectoryPath,
                                        home: String = NSHomeDirectory()) -> String {
        guard cwd == "/" || cwd.isEmpty else { return cwd }
        return sandboxed ? home + "/Library/Caches/s1/shell" : home
    }

    /// Wrap a shell command for the srt runtime: `srt --settings <file>
    /// <cmd>` — srt takes the command as argv, so the zsh line is handed
    /// over verbatim with no quoting tricks. Returns nil when srt isn't
    /// installed — the caller decides whether to error or fall back.
    public static func wrap(_ cmd: String) -> (executable: String, args: [String])? {
        guard let bin = srtBinary() else { return nil }
        let settings = ensureSettingsFile()
        return (bin, ["--settings", settings, "/bin/zsh", "-c", cmd])
    }
}
