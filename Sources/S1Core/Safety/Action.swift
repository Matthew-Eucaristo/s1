import Foundation

/// How risky an action is. Drives the safety gate.
public enum ActionClass: String, Codable, Sendable {
    /// Pure observation — always allowed.
    case read
    /// Allowed, but logged (can be undone by the user).
    case reversible
    /// Requires explicit opt-in (`--allow-irreversible`) plus human confirmation.
    case irreversible
}

/// A single executable step. Everything the agent can do goes through this enum
/// so the safety gate can classify it before it touches the machine.
public enum Action: Codable, Sendable, Equatable {
    // read-only
    case captureScreenshot(reason: String)
    case verify(expectation: String)
    case done(summary: String)
    // reversible
    case moveMouse(x: Double, y: Double)
    case click(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case typeText(String)
    case keyCombo(keys: [String])
    case scroll(dx: Double, dy: Double)
    case axPress(ref: String)
    case axSetValue(ref: String, value: String)
    /// Named accessibility action on a node — AXShowMenu (popups/context
    /// menus), AXIncrement/AXDecrement (sliders, steppers), AXConfirm/
    /// AXCancel (dialogs), AXPick (menu items), AXRaise/AXOpen (windows).
    case axAction(ref: String, name: String)
    /// Boolean AX attribute write — AXSelected (rows), AXFocused,
    /// AXExpanded (disclosures), AXMain/AXMinimized (windows).
    case axSetAttribute(ref: String, attr: String, value: Bool)
    case openApp(name: String)
    case wait(seconds: Double)
    // irreversible
    case shell(command: String)
    case custom(name: String, params: [String: String] = [:])

    public var actionClass: ActionClass {
        switch self {
        case .captureScreenshot, .verify, .done:
            return .read
        case .shell, .custom:
            return .irreversible
        default:
            return .reversible
        }
    }

    /// Text payloads that get pattern-scanned by the gate's deny list.
    var textPayloads: [String] {
        switch self {
        case .typeText(let t): return [t]
        case .axSetValue(_, let v): return [v]
        case .keyCombo(let k): return k
        case .shell(let c): return [c]
        case .custom(let n, let p): return [n] + p.values
        // The app being opened matters too — "Passwords"/"Keychain" is a
        // credential surface, not just a launch.
        case .openApp(let n): return [n]
        // Model-controlled AX action/attribute names get scanned too.
        case .axAction(_, let name): return [name]
        case .axSetAttribute(_, let attr, _): return [attr]
        default: return []
        }
    }
}

/// What the perceiver produces each step. Codable so it can be logged verbatim.
public struct WindowInfo: Codable, Sendable {
    public var pid: Int32
    public var owner: String
    public var title: String?
    public var bounds: CGRectCodable
}

public struct CGRectCodable: Codable, Sendable {
    public var x, y, w, h: Double
    public init(_ r: CGRect) { x = r.origin.x; y = r.origin.y; w = r.size.width; h = r.size.height }
}

/// Condensed accessibility-tree node. `ref` is stable within one snapshot
/// (`e0`, `e1`, ... in walk order) — refs must be re-resolved after mutation.
public struct AXNode: Codable, Sendable {
    public var ref: String
    public var role: String
    public var title: String?
    /// AXDescription — where icon-only buttons keep their human label
    /// ("Save", "Bold") when AXTitle is empty.
    public var desc: String?
    /// AXHelp — the tooltip string; the last-resort human label for
    /// controls that expose neither a title nor a description.
    public var help: String?
    public var value: String?
    public var frame: CGRectCodable?
    public var children: [AXNode]

    /// Depth-first flatten for ref lookup and serialization.
    public var flattened: [AXNode] {
        [self] + children.flatMap(\.flattened)
    }
}

/// One running app's surface state — what Spotlight-like awareness looks
/// like: every visible app plus its window titles, not just the frontmost.
public struct AppState: Codable, Sendable {
    public var name: String
    public var pid: Int32
    public var isActive: Bool          // frontmost
    public var windowTitles: [String]  // non-empty, capped
}

public struct Snapshot: Codable, Sendable {
    public var timestamp: Date
    public var frontmostApp: String?
    public var frontmostPID: Int32?
    public var windows: [WindowInfo]
    public var axTree: AXNode?
    public var appStates: [AppState] = []
    public var screenshotPath: String?
    /// True while an AXSecureTextField (password input) has keyboard focus —
    /// the gate routes keystrokes to a human instead of typing into it.
    public var secureTextFocused: Bool = false

    /// One-line digest for the step log.
    public var summary: String {
        var s = frontmostApp ?? "none"
        s += " | windows:\(windows.count)"
        if let t = axTree { s += " | ax:\(t.flattened.count) nodes" }
        if screenshotPath != nil { s += " | shot" }
        return s
    }
}
