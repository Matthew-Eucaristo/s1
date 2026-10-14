import Foundation

/// Where keystrokes would land: the frontmost app, its focused window and
/// the focused element. `window`/`element` are AX element hashes (CFHash
/// agrees with CFEqual), so they say "same live element or not" and mean
/// nothing outside the run that read them.
public struct FocusMark: Codable, Sendable, Equatable {
    public var pid: Int32
    public var app: String?
    public var window: Int?
    public var windowTitle: String?
    public var element: Int?
    public var role: String?
    public var label: String?

    public init(pid: Int32, app: String? = nil, window: Int? = nil, windowTitle: String? = nil,
                element: Int? = nil, role: String? = nil, label: String? = nil) {
        self.pid = pid; self.app = app; self.window = window; self.windowTitle = windowTitle
        self.element = element; self.role = role; self.label = label
    }

    /// What moved from `self` (where the run aimed) to `now`, or nil when it
    /// is still the same place. A side that couldn't be read counts as
    /// unchanged: a window still opening after a launch isn't a move. The
    /// element only counts inside the same window, and only when `element`
    /// is asked for (a menu command follows the window, not the field).
    public func drift(to now: FocusMark, element checkElement: Bool = true) -> String? {
        if now.pid != pid { return "\(now.app ?? "another app") came to the front" }
        guard let w = window, let nw = now.window else { return nil }
        if w != nw { return "the focus moved to \(now.windowName)" }
        if checkElement, let e = element, let ne = now.element, e != ne {
            return "the focus moved to \(now.elementName)"
        }
        return nil
    }

    var windowName: String {
        if let t = windowTitle, !t.isEmpty { return "the “\(t)” window" }
        return "another window"
    }

    var elementName: String {
        let kind: String = switch role {
        case "AXTextArea": "a text area"
        case "AXTextField", "AXComboBox": "a text field"
        case "AXSearchField": "a search field"
        case "AXSecureTextField": "a password field"
        case "AXWebArea": "the page"
        case "AXButton": "a button"
        default: "another control"
        }
        if let l = label, !l.isEmpty { return "\(kind) “\(l)”" }
        return kind
    }
}

/// Keys go wherever focus is when they're sent. A run that waits (or thinks
/// for a while) between deciding and typing must still type where it aimed:
/// if the user switched windows or opened Find meanwhile, the step goes back
/// to them instead of typing into the wrong place and reporting done.
public enum FocusGuard {
    /// How much of the focus an action depends on: nil = none, false = the
    /// window (menu commands), true = the focused element (keys and text).
    static func depth(_ a: Action) -> Bool? {
        switch a {
        // axSetValue can fall back to clicking and typing (Act.swift).
        case .typeText, .editText, .axSetValue: return true
        case .keyCombo(let keys):
            // Media keys go to the system, not the focused app.
            return keys.allSatisfy { CGEventActuator.mediaKeys[$0.lowercased()] != nil } ? nil : true
        case .menuItem: return false
        default: return nil
        }
    }

    /// Steps that leave focus where it was, so the target from before them
    /// still stands after them (a wait, a search, a decision with no action).
    public static func keepsFocus(_ a: Action?) -> Bool {
        switch a {
        case nil, .wait?, .webSearch?, .captureScreenshot?, .verify?: return true
        default: return false
        }
    }

    /// The reason to hand `action` back to the user, or nil to go ahead.
    /// `aimed` is where the run meant the keys to go, `now` where they'd land.
    public static func check(_ action: Action, aimed: FocusMark?, now: FocusMark?) -> String? {
        guard let deep = depth(action), let aimed, let now,
              let moved = aimed.drift(to: now, element: deep) else { return nil }
        let what = switch action {
        case .menuItem: "choosing the menu command"
        default: "typing"
        }
        return "\(moved) while I was working, so I stopped before \(what) there; "
            + "put the focus back and ask again"
    }
}
