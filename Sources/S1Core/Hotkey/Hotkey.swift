import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

/// A hotkey trigger pattern.
public enum HotkeyPattern: Sendable {
    /// Modifier chord, e.g. ⌃⌥Space: key press while exactly these flags are held.
    case chord(keyCode: UInt16, flags: NSEvent.ModifierFlags)
    /// Double-tap a lone modifier (e.g. either Shift) within `within` seconds.
    case doubleTapModifier(keyCodes: [UInt16], within: TimeInterval)
}

/// Stateless chord matcher — `keyCode` pressed while `flags` (the
/// command/control/option/shift subset) are held, exactly.
public enum ChordMatcher {
    public static func matches(keyCode: UInt16, flags: NSEvent.ModifierFlags,
                               pattern: HotkeyPattern) -> Bool {
        guard case .chord(let wantKey, let wantFlags) = pattern else { return false }
        guard keyCode == wantKey else { return false }
        let held = flags.intersection([.command, .control, .option, .shift])
        return held == wantFlags
    }
}

/// Detects tap-tap on a lone modifier via flagsChanged transitions:
/// press → release → press, second press within `within` of the release.
/// Pure state machine — no AppKit types needed to test it.
public struct ModifierTapTracker: Sendable {
    public var keyCodes: Set<UInt16>
    public var within: TimeInterval
    /// A tap is a quick press: holding Shift (to think, to shift-scroll)
    /// and then tapping once is not a double tap.
    public var maxHold: TimeInterval = 0.4
    private var lastRelease: (keyCode: UInt16, at: TimeInterval)?
    private var pressedAt: TimeInterval?

    public init(keyCodes: [UInt16], within: TimeInterval = 0.35) {
        self.keyCodes = Set(keyCodes)
        self.within = within
    }

    /// Feed each flagsChanged transition. `isDown` = modifier now held.
    /// Returns true when the gesture completes (the second press).
    public mutating func feed(keyCode: UInt16, isDown: Bool, at t: TimeInterval) -> Bool {
        guard keyCodes.contains(keyCode) else { return false }
        if isDown {
            pressedAt = t
            defer { lastRelease = nil }
            if let last = lastRelease, last.keyCode == keyCode, t - last.at <= within {
                return true
            }
            return false
        }
        // Only a short press counts as the first tap.
        if let p = pressedAt, t - p <= maxHold { lastRelease = (keyCode, t) } else { lastRelease = nil }
        pressedAt = nil
        return false
    }

    /// Forget a pending release — any other input between the two taps means
    /// the user was typing, not gesturing (fast capital letters must NOT fire).
    public mutating func reset() { lastRelease = nil; pressedAt = nil }
}

/// Global hotkey listener — a passive CGEvent tap (listen-only, so it never
/// consumes keys; the Mac keeps working normally). Chosen over
/// `NSEvent.addGlobalMonitorForEvents` on purpose: the NSEvent monitor only
/// delivers through AppKit's event path, so plain CLI daemons (no NSApp)
/// silently receive nothing. The event tap works in both CLI and app hosts
/// as long as its run loop source spins — we attach it to the main run loop.
/// Needs Input Monitoring permission (separate TCC bucket from Accessibility).
public final class Hotkey: @unchecked Sendable {
    private let patterns: [HotkeyPattern]
    private let onTrigger: @Sendable () -> Void
    /// Esc pressed by the user (not by s1): cancel what s1 is doing.
    private let onEscape: (@Sendable () -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var trackers: [ModifierTapTracker]
    /// Spamming the gesture toggles once, not on-off-on-off.
    private var lastTrigger: TimeInterval = 0
    static let cooldown: TimeInterval = 0.7

    public init(patterns: [HotkeyPattern], onEscape: (@Sendable () -> Void)? = nil,
                onTrigger: @escaping @Sendable () -> Void) {
        self.patterns = patterns
        self.onEscape = onEscape
        self.onTrigger = onTrigger
        self.trackers = patterns.compactMap {
            if case .doubleTapModifier(let codes, let w) = $0 {
                return ModifierTapTracker(keyCodes: codes, within: w)
            }
            return nil
        }
    }

    /// ⌃⌥Space — free of Spotlight (⌘Space) and Emoji (⌃⌘Space).
    public static let defaultChord = HotkeyPattern.chord(
        keyCode: 49, flags: [.control, .option])
    /// Double-tap either Shift key — unclaimed, ergonomic.
    public static let doubleShift = HotkeyPattern.doubleTapModifier(
        keyCodes: [56 /* left shift */, 60 /* right shift */], within: 0.45)

    /// Install the tap. MUST be called on a thread whose run loop spins —
    /// callers (Serve) route this through the main queue.
    public func start() {
        guard tap == nil else { return }
        // Mouse downs break a pending tap: shift-click, shift-click (extending
        // a selection) must not read as ⇧⇧.
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<Hotkey>.fromOpaque(userInfo).takeUnretainedValue()
                me.handle(type: type, event: event)
                return Unmanaged.passUnretained(event)
            }, userInfo: ctx)
        guard let tap else {
            // Almost always Input Monitoring (separate TCC bucket from
            // Accessibility) — request once so the user lands on the toggle.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
            return
        }
        guard let s = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
            CFMachPortInvalidate(tap)
            self.tap = nil
            return
        }
        source = s
        CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    public func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
    }

    /// Whether the tap is actually installed (false without the TCC grant).
    public var isArmed: Bool { tap != nil }

    /// Runs on the main run loop (tap source lives there).
    private func handle(type: CGEventType, event: CGEvent) {
        // macOS disables taps on timeout/user input — re-enable, keep living.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        // Keys s1 itself posts (its actions) are never gestures or cancels.
        if event.getIntegerValueField(.eventSourceUnixProcessID) == Int64(getpid()) { return }
        let keyCode = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
        let t = Double(event.timestamp) / 1e9   // mach absolute nanos → seconds
        func fire() {
            guard t - lastTrigger >= Self.cooldown else { return }
            lastTrigger = t
            onTrigger()
        }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            for i in trackers.indices { trackers[i].reset() }
        case .keyDown:
            if keyCode == 53, event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).isEmpty {
                onEscape?()
            }
            // Any real key between two modifier taps breaks the gesture —
            // otherwise typing a fast capital letter would fire it.
            for i in trackers.indices { trackers[i].reset() }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(clamping: event.flags.rawValue))
            for p in patterns where ChordMatcher.matches(
                keyCode: keyCode, flags: flags, pattern: p) {
                fire()
                return
            }
        case .flagsChanged:
            // Map the moved keycode to ITS flag — works for trackers on any
            // modifier, not just Shift (56/60 shift, 55/61 cmd, 58/62 opt,
            // 59/63 ctrl per HID key codes).
            let flagMask: CGEventFlags = switch keyCode {
            case 56, 60: .maskShift
            case 55, 61: .maskCommand
            case 58, 62: .maskAlternate
            case 59, 63: .maskControl
            default: []
            }
            let modHeld = event.flags.contains(flagMask)
            var tracked = false
            for i in trackers.indices where trackers[i].keyCodes.contains(keyCode) {
                tracked = true
                if trackers[i].feed(keyCode: keyCode, isDown: modHeld, at: t) {
                    fire()
                    trackers[i] = ModifierTapTracker(
                        keyCodes: Array(trackers[i].keyCodes), within: trackers[i].within)
                    return
                }
            }
            // A different modifier moving also breaks the gesture
            // (Shift-tap → Ctrl-tap → Shift-tap is not double-shift).
            if !tracked { for i in trackers.indices { trackers[i].reset() } }
        default: break
        }
    }

    deinit { stop() }
}
