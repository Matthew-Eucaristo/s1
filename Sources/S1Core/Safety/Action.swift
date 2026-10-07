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
    /// Look something up on the web (the Reasoner's provider runs the
    /// search); the results become this step's outcome.
    case webSearch(query: String)
    // reversible
    case moveMouse(x: Double, y: Double)
    case click(x: Double, y: Double)
    case rightClick(x: Double, y: Double)
    case doubleClick(x: Double, y: Double)
    case drag(fromX: Double, fromY: Double, toX: Double, toY: Double)
    case typeText(String)
    /// Voice editing in the focused text field: delete (`replace` empty) or
    /// replace the last whole-word occurrence of `find`.
    case editText(find: String, replace: String)
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
    /// A System Settings pane (`x-apple.systempreferences:`) or a folder
    /// (`file://`, directories only) — what Mac skills open.
    case openURL(String)
    /// Close the newest notification banner/alert (or all of them) through
    /// Notification Center's own Close / Clear actions.
    case dismissNotification(all: Bool)
    /// Ask an app to quit the way the Dock's Quit does (empty = frontmost):
    /// the app saves, or asks about unsaved changes itself.
    case quitApp(name: String)
    case wait(seconds: Double)
    // irreversible
    case shell(command: String)
    case custom(name: String, params: [String: String] = [:])

    public var actionClass: ActionClass {
        switch self {
        case .captureScreenshot, .verify, .done, .webSearch:
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
        case .editText(let f, let r): return [f, r]
        case .openURL(let u): return [u]
        case .webSearch(let q): return [q]
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

/// Which AX roles accept which verbs — the single source of truth behind
/// the observation markers ([pressable]/[editable]/[scrollable]/
/// [adjustable]/[secure]) the model sees, and the `s1 ax` dump.
public enum AXSemantics {
    /// Roles axPress can meaningfully trigger.
    public static let pressable: Set<String> = [
        "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXLink",
        "AXTab", "AXMenuButton", "AXPopUpButton", "AXRow", "AXCell",
        "AXMenuBarItem", "AXDisclosureTriangle",
    ]
    /// Scroll containers — where the scroll verb makes sense.
    public static let scrollable: Set<String> = [
        "AXScrollArea", "AXTable", "AXOutline", "AXList", "AXWebArea",
    ]
    /// Roles that take text via axSetValue (or focus + typeText).
    public static let editable: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox",
    ]
    /// Adjustable controls — nudge with axAction AXIncrement/AXDecrement.
    public static let adjustable: Set<String> = [
        "AXSlider", "AXStepper", "AXIncrementor", "AXValueIndicator",
        "AXRatingIndicator",
    ]
    /// Password boxes — never typed into; never read for a value.
    public static let secure: Set<String> = ["AXSecureTextField"]

    /// Marker annotations for one node, e.g. "[pressable][secure]".
    public static func markers(for role: String) -> String {
        var s = ""
        if pressable.contains(role) { s += " [pressable]" }
        if editable.contains(role) { s += " [editable]" }
        if scrollable.contains(role) { s += " [scrollable]" }
        if adjustable.contains(role) { s += " [adjustable]" }
        if secure.contains(role) { s += " [secure]" }
        return s
    }
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
