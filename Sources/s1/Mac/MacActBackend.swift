#if canImport(CoreGraphics)
import CoreGraphics
import Foundation

/// Executes gated actions on macOS with Quartz CGEvent.
public final class CGEventBackend: ActionBackend {
    public init() {}

    public func perform(_ action: Action) throws -> String {
        switch action.kind {
        case "move_mouse":
            let point = try point(for: action)
            guard let event = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                                      mouseCursorPosition: point, mouseButton: .left) else {
                throw BackendError.badAction("could not create mouse event")
            }
            event.post(tap: .cghidEventTap)
            return "moved to (\(point.x), \(point.y))"

        case "click", "double_click", "right_click":
            return try click(action)

        case "type_text":
            let text = action.text ?? ""
            let utf16 = Array(text.utf16)
            for isDown in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: isDown) else {
                    throw BackendError.badAction("could not create keyboard event")
                }
                event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                event.post(tap: .cghidEventTap)
            }
            return "typed \(text.count) chars"

        case "key_press", "hotkey":
            return try key(action)

        case "scroll":
            let dy = Int32(action.dy ?? 0)
            let dx = Int32(action.dx ?? 0)
            guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                                      wheel1: dy, wheel2: dx, wheel3: 0) else {
                throw BackendError.badAction("could not create scroll event")
            }
            event.post(tap: .cghidEventTap)
            return "scrolled (\(dx), \(dy))"

        default:
            throw BackendError.unsupported(action.kind)
        }
    }

    // MARK: - Helpers

    private func point(for action: Action) throws -> CGPoint {
        guard let x = action.x, let y = action.y else {
            throw BackendError.badAction("\(action.kind) requires x and y")
        }
        return CGPoint(x: x, y: y)
    }

    private func click(_ action: Action) throws -> String {
        let point = try point(for: action)
        let isRight = action.kind == "right_click"
        let isDouble = action.kind == "double_click"
        let button: CGMouseButton = isRight ? .right : .left
        let downType: CGEventType = isRight ? .rightMouseDown : .leftMouseDown
        let upType: CGEventType = isRight ? .rightMouseUp : .leftMouseUp
        let repetitions = isDouble ? 2 : 1

        for clickIndex in 1...repetitions {
            for eventType in [downType, upType] {
                guard let event = CGEvent(mouseEventSource: nil, mouseType: eventType,
                                          mouseCursorPosition: point, mouseButton: button) else {
                    throw BackendError.badAction("could not create mouse event")
                }
                if isDouble {
                    event.setIntegerValueField(.mouseEventClickState, value: Int64(clickIndex))
                }
                event.post(tap: .cghidEventTap)
            }
        }
        let label = isRight ? "right-click" : (isDouble ? "double-click" : "click")
        return "\(label) at (\(point.x), \(point.y))"
    }

    private func key(_ action: Action) throws -> String {
        let (name, modifiers) = ActionGate.splitKey(action)
        guard let keyCode = Self.keyCodes[name] else {
            throw BackendError.badAction("unknown key '\(name)' (add it to CGEventBackend.keyCodes)")
        }
        var flags: CGEventFlags = []
        for modifier in modifiers {
            switch modifier {
            case "cmd", "command": flags.insert(.maskCommand)
            case "shift": flags.insert(.maskShift)
            case "opt", "option", "alt": flags.insert(.maskAlternate)
            case "ctrl", "control": flags.insert(.maskControl)
            default: break
            }
        }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: isDown) else {
                throw BackendError.badAction("could not create key event")
            }
            event.flags = flags
            event.post(tap: .cghidEventTap)
        }
        let combo = modifiers.isEmpty ? name : (modifiers.sorted() + [name]).joined(separator: "+")
        return "pressed \(combo)"
    }

    /// macOS virtual keycodes (US/ANSI layout).
    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26,
        "-": 27, "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "return": 36, "enter": 36, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42,
        ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "tab": 48, "space": 49, "`": 50, "delete": 51, "backspace": 51, "escape": 53, "esc": 53,
        "cmd": 55, "command": 55, "shift": 56, "capslock": 57, "opt": 58, "option": 58, "alt": 58,
        "ctrl": 59, "control": 59,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100,
        "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "home": 115, "end": 119, "pageup": 116, "pagedown": 121, "forwarddelete": 117,
        "left": 123, "right": 124, "down": 125, "up": 126,
    ]
}
#endif
