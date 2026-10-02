import Foundation
import AppKit
import ApplicationServices

public protocol Actuator: Sendable {
    var name: String { get }
    /// Executes a gated action; returns a short outcome summary for the log.
    /// `pid` is the frontmost app's pid when AX refs need re-resolving.
    func perform(_ action: Action, frontmostPID: pid_t?) async throws -> String
}

/// Logs every action, touches nothing. The default whenever `--dry-run`.
public struct DryRunActuator: Actuator {
    public let name = "dry-run"
    public init() {}
    public func perform(_ action: Action, frontmostPID: pid_t?) async throws -> String {
        "[dry-run] \(action)"
    }
}

/// Real input via CGEvent + AX actions. Requires Accessibility permission.
public struct CGEventActuator: Actuator {
    public let name = "cgevent"
    public init() {}

    public func perform(_ action: Action, frontmostPID: pid_t?) async throws -> String {
        switch action {
        case .moveMouse(let x, let y):
            let p = CGPoint(x: x, y: y)
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            return "mouse -> (\(x), \(y))"

        case .click(let x, let y):
            let p = CGPoint(x: x, y: y)
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(60_000)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            return "click (\(x), \(y))"

        case .typeText(let text):
            try postUnicode(text)
            return "typed \(text.count) chars"

        case .keyCombo(let keys):
            try postKeyCombo(keys)
            return "keyCombo \(keys.joined(separator: "+"))"

        case .scroll(let dx, let dy):
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 2, wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0)?
                .post(tap: .cghidEventTap)
            return "scroll (\(dx), \(dy))"

        case .axPress(let ref):
            guard let pid = frontmostPID else { throw S1Error.axFailed("no frontmost pid") }
            if AXReader.performAXAction(pid: pid, ref: ref, action: "AXPress") {
                return "AXPress \(ref)"
            }
            // Text areas and some controls reject AXPress but accept focus +
            // a real click — try that before declaring the action failed.
            _ = AXReader.setAttribute(pid: pid, ref: ref,
                                      attr: kAXFocusedAttribute, value: kCFBooleanTrue!)
            guard let f = AXReader.frameOf(pid: pid, ref: ref) else {
                throw S1Error.axFailed("AXPress failed on \(ref)")
            }
            let p = CGPoint(x: f.midX, y: f.midY)
            let src = CGEventSource(stateID: .hidSystemState)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(60_000)
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                    mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            return "focused+clicked \(ref) @(\(Int(p.x)),\(Int(p.y)))"

        case .axSetValue(let ref, let value):
            guard let pid = frontmostPID else { throw S1Error.axFailed("no frontmost pid") }
            guard AXReader.setValue(pid: pid, ref: ref, value: value) else {
                throw S1Error.axFailed("set value failed on \(ref)")
            }
            return "AXSetValue \(ref) = \"\(value.prefix(30))\""

        case .openApp(let name):
            try await openApp(named: name)
            return "opened \(name)"

        case .wait(let s):
            try await Task.sleep(for: .seconds(s))
            return "waited \(s)s"

        case .captureScreenshot, .verify, .done:
            return "no-op (handled by loop)"

        case .shell(let cmd):
            // Gate already required human confirmation to get here.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            try p.run()
            return "shell: \(cmd)"

        case .custom(let n, _):
            throw S1Error.aborted("custom action '\(n)' has no actuator implementation")
        }
    }

    /// Unicode-safe typing (works for Indonesian diacritics etc.).
    func postUnicode(_ text: String) throws {
        let src = CGEventSource(stateID: .hidSystemState)
        let utf16 = Array(text.utf16)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
            throw S1Error.aborted("cannot create keyboard events")
        }
        down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    func postKeyCombo(_ keys: [String]) throws {
        var flags = CGEventFlags()
        var key: String?
        for k in keys {
            switch k.lowercased() {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: key = k
            }
        }
        guard let k = key, let code = Self.keyCodes[k.lowercased()] else {
            throw S1Error.aborted("unknown key in combo \(keys)")
        }
        let src = CGEventSource(stateID: .hidSystemState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        down?.post(tap: .cghidEventTap)
        usleep(50_000)
        up?.post(tap: .cghidEventTap)
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]

    func openApp(named name: String) async throws {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: name) ??
            URL(fileURLWithPath: "/System/Applications/\(name).app").exists ??
            URL(fileURLWithPath: "/Applications/\(name).app").exists {
            try await ws.openApplication(at: url, configuration: .init())
        } else {
            throw S1Error.aborted("app not found: \(name)")
        }
    }
}

extension URL {
    var exists: URL? { FileManager.default.fileExists(atPath: path) ? self : nil }
}
