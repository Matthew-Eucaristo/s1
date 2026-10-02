import Foundation

/// The safety gate. All rules live here in one place so they can be reviewed
/// and audited. v0 classifies an action as:
///
/// - `.destructive` when the policy explicitly marks it (`destructive: true`),
///   when delete/backspace is combined with cmd/opt (file-deletion shortcuts),
///   or when enter/return is pressed (commit: may send a message, submit a
///   form, or confirm a dialog — not reversible).
/// - `.unknown` for any action kind outside the whitelist, or a malformed
///   key action without a key name.
/// - `.safe` otherwise (typing, moving, clicking — nothing is committed until
///   a gated commit key is pressed).
///
/// Destructive actions are rejected unless `allowDestructive` is passed
/// (CLI: `--allow-destructive`). Unknown actions are always rejected.
public enum ActionGate {
    /// Only these action kinds may ever run. Anything else fails closed.
    public static let whitelist: Set<String> = [
        "move_mouse", "click", "double_click", "right_click",
        "type_text", "key_press", "hotkey", "scroll", "wait",
    ]

    static let deleteKeys: Set<String> = ["delete", "backspace", "forwarddelete", "forward_delete"]
    static let commitKeys: Set<String> = ["enter", "return"]
    static let modifierNames: Set<String> = ["cmd", "command", "shift", "opt", "option", "alt", "ctrl", "control"]
    static let destructiveModifiers: Set<String> = ["cmd", "command", "opt", "option", "alt"]

    /// Normalizes the accepted key/modifier shapes into (key, modifiers):
    ///   {"kind": "key_press", "key": "delete", "modifiers": ["cmd"]}
    ///   {"kind": "key_press", "key": "cmd+delete"}
    ///   {"kind": "hotkey", "keys": ["cmd", "shift", "delete"]}
    public static func splitKey(_ action: Action) -> (key: String, modifiers: Set<String>) {
        var raw: [String]
        if action.kind == "hotkey" {
            raw = (action.keys ?? []).map { $0.lowercased() }
        } else {
            var parts = (action.key ?? "").lowercased()
                .split(separator: "+")
                .map(String.init)
            if parts.isEmpty { parts = [""] }
            raw = (action.modifiers ?? []).map { $0.lowercased() } + parts
        }
        let modifiers = Set(raw.filter { modifierNames.contains($0) })
        let nonModifiers = raw.filter { !modifierNames.contains($0) }
        return (nonModifiers.last ?? "", modifiers)
    }

    /// Returns the risk class and a human-readable reason (audit trail).
    public static func classify(_ action: Action) -> (risk: Risk, reason: String) {
        guard whitelist.contains(action.kind) else {
            return (.unknown, "action kind '\(action.kind)' is not in the whitelist")
        }
        if action.destructive == true {
            return (.destructive, "policy explicitly marked this action destructive")
        }
        if action.kind == "key_press" || action.kind == "hotkey" {
            let (key, mods) = splitKey(action)
            if key.isEmpty {
                return (.unknown, "\(action.kind) requires a key name")
            }
            if deleteKeys.contains(key) && !mods.intersection(destructiveModifiers).isEmpty {
                return (.destructive, "delete/backspace with cmd/opt = file-deletion shortcut")
            }
            if commitKeys.contains(key) {
                return (.destructive, "enter/return = commit (may send a message, submit a form, or confirm a dialog)")
            }
        }
        return (.safe, "ok")
    }

    /// Full decision used by the actuator: classifies, then applies the
    /// allow-destructive policy.
    public static func decide(_ action: Action, allowDestructive: Bool) -> GateDecision {
        let (risk, reason) = classify(action)
        switch risk {
        case .unknown:
            return GateDecision(allowed: false, risk: risk, reason: reason)
        case .destructive where !allowDestructive:
            return GateDecision(
                allowed: false,
                risk: risk,
                reason: reason + " | rejected: pass allowDestructive (CLI --allow-destructive) to permit"
            )
        default:
            return GateDecision(allowed: true, risk: risk, reason: reason)
        }
    }
}
