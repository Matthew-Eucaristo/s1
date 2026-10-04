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
            guard let ev = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: p, mouseButton: .left) else {
                throw S1Error.aborted("cannot create mouse event")
            }
            ev.post(tap: .cghidEventTap)
            return "mouse -> (\(x), \(y))"

        case .click(let x, let y):
            let p = CGPoint(x: x, y: y)
            let src = CGEventSource(stateID: .hidSystemState)
            guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                    mouseCursorPosition: p, mouseButton: .left),
                  let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                    mouseCursorPosition: p, mouseButton: .left) else {
                // A nil event must fail loudly — logging "click" for a click
                // that never posted is phantom evidence.
                throw S1Error.aborted("cannot create click events")
            }
            down.post(tap: .cghidEventTap)
            usleep(60_000)
            up.post(tap: .cghidEventTap)
            return "click (\(x), \(y))"

        case .rightClick(let x, let y):
            let p = CGPoint(x: x, y: y)
            let src = CGEventSource(stateID: .hidSystemState)
            guard let down = CGEvent(mouseEventSource: src, mouseType: .rightMouseDown,
                    mouseCursorPosition: p, mouseButton: .right),
                  let up = CGEvent(mouseEventSource: src, mouseType: .rightMouseUp,
                    mouseCursorPosition: p, mouseButton: .right) else {
                throw S1Error.aborted("cannot create right-click events")
            }
            down.post(tap: .cghidEventTap)
            usleep(60_000)
            up.post(tap: .cghidEventTap)
            return "rightClick (\(x), \(y))"

        case .doubleClick(let x, let y):
            let p = CGPoint(x: x, y: y)
            let src = CGEventSource(stateID: .hidSystemState)
            // Click state 1 then 2 — without the second press carrying
            // clickState=2, apps see two singles (Finder won't "open").
            for state: Int64 in [1, 2] {
                guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                        mouseCursorPosition: p, mouseButton: .left),
                      let up = CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                        mouseCursorPosition: p, mouseButton: .left) else {
                    throw S1Error.aborted("cannot create double-click events")
                }
                down.setIntegerValueField(.mouseEventClickState, value: state)
                up.setIntegerValueField(.mouseEventClickState, value: state)
                down.post(tap: .cghidEventTap)
                usleep(60_000)
                up.post(tap: .cghidEventTap)
                usleep(60_000)
            }
            return "doubleClick (\(x), \(y))"

        case .drag(let fx, let fy, let tx, let ty):
            let from = CGPoint(x: fx, y: fy), to = CGPoint(x: tx, y: ty)
            let src = CGEventSource(stateID: .hidSystemState)
            guard let down = CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                    mouseCursorPosition: from, mouseButton: .left) else {
                throw S1Error.aborted("cannot create drag events")
            }
            down.post(tap: .cghidEventTap)
            usleep(80_000)
            // Interpolated drag points — drop targets that watch the
            // trajectory (reordering, Dock) need real movement, not a
            // teleport from press to release.
            let steps = 8
            for i in 1...steps {
                let t = Double(i) / Double(steps)
                let mid = CGPoint(x: fx + (tx - fx) * t, y: fy + (ty - fy) * t)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseDragged,
                        mouseCursorPosition: mid, mouseButton: .left)?
                    .post(tap: .cghidEventTap)
                usleep(20_000)
            }
            CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                    mouseCursorPosition: to, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            return "drag (\(Int(fx)),\(Int(fy))) -> (\(Int(tx)),\(Int(ty)))"

        case .typeText(let text):
            try actTimeChecks(payload: text)
            try postUnicode(text)
            return "typed \(text.count) chars"

        case .keyCombo(let keys):
            try actTimeChecks(payload: nil)
            try postKeyCombo(keys)
            return "keyCombo \(keys.joined(separator: "+"))"

        case .scroll(let dx, let dy):
            // Convention: positive dy scrolls content DOWN (like a browser's
            // scrollY), documented in the decision prompt. CGEvent wheel1 is
            // the opposite sign — positive wheel1 moves content up.
            // Model output is untrusted: Int32() traps on NaN/1e30 — clamp
            // to a sane wheel range so a weird reply scrolls oddly instead
            // of crashing the run.
            func clamp(_ v: Double) -> Int32 {
                guard v.isFinite else { return 0 }
                return Int32(max(-32_000, min(32_000, v.rounded())))
            }
            CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                    wheelCount: 2, wheel1: clamp(-dy), wheel2: clamp(-dx), wheel3: 0)?
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
            if AXReader.setValue(pid: pid, ref: ref, value: value) {
                return "AXSetValue \(ref) = \"\(value.prefix(30))\""
            }
            // Ref index shifted or the node refuses AX value writes — focus the
            // element (click its frame if needed) and type the value for real.
            _ = AXReader.setAttribute(pid: pid, ref: ref,
                                      attr: kAXFocusedAttribute, value: kCFBooleanTrue!)
            if let f = AXReader.frameOf(pid: pid, ref: ref) {
                let p = CGPoint(x: f.midX, y: f.midY)
                let src = CGEventSource(stateID: .hidSystemState)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseDown,
                        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
                usleep(60_000)
                CGEvent(mouseEventSource: src, mouseType: .leftMouseUp,
                        mouseCursorPosition: p, mouseButton: .left)?.post(tap: .cghidEventTap)
            }
            try actTimeChecks(payload: value)
            try postUnicode(value)
            return "focused+typed \(value.count) chars (AXSetValue refused)"

        case .axAction(let ref, let name):
            guard let pid = frontmostPID else { throw S1Error.axFailed("no frontmost pid") }
            guard CGEventActuator.allowedAXActions.contains(name) else {
                throw S1Error.axFailed("AX action '\(name)' is not allowed")
            }
            guard AXReader.performAXAction(pid: pid, ref: ref, action: name) else {
                throw S1Error.axFailed("\(name) failed on \(ref)")
            }
            return "\(name) \(ref)"

        case .axSetAttribute(let ref, let attr, let value):
            guard let pid = frontmostPID else { throw S1Error.axFailed("no frontmost pid") }
            guard CGEventActuator.allowedAXAttributes.contains(attr) else {
                throw S1Error.axFailed("AX attribute '\(attr)' is not allowed")
            }
            let cf: CFTypeRef = value ? kCFBooleanTrue : kCFBooleanFalse
            guard AXReader.setAttribute(pid: pid, ref: ref, attr: attr, value: cf) else {
                throw S1Error.axFailed("set \(attr) failed on \(ref)")
            }
            return "\(attr)=\(value) \(ref)"

        case .openApp(let name):
            try await openApp(named: name)
            return "opened \(name)"

        case .wait(let s):
            // Model output is untrusted: .seconds(NaN) traps. The loop and
            // replay cap before calling, but a direct perform must be safe.
            guard s.isFinite, s > 0 else { return "wait skipped (invalid \(s)s)" }
            // Same 5-min ceiling the loop applies — a scripted absurdity
            // shouldn't park a run for days either.
            let capped = min(s, 300)
            try await Task.sleep(for: .seconds(capped))
            return "waited \(capped)s"

        case .captureScreenshot(let r):
            return "captured screenshot (\(r))"
        case .verify, .done:
            return "no-op (handled by loop)"

        case .shell(let cmd):
            // Gate already required human confirmation to get here.
            // Wait (bounded) so the outcome line tells the truth — a fire-
            // and-forget launch would log success before anything ran.
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", cmd]
            try p.run()
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: killer)
            p.waitUntilExit()
            killer.cancel()
            guard p.terminationReason == .exit else { return "shell: \(cmd) (killed at 30s)" }
            return "shell: \(cmd) (exit \(p.terminationStatus))"

        case .custom(let n, _):
            throw S1Error.aborted("custom action '\(n)' has no actuator implementation")
        }
    }

    /// AX actions the model may fire by name. Whitelisted so a crafted
    /// reply can't reach arbitrary AX actions — these are all standard
    /// user-facing verbs (menu open, slider nudge, dialog confirm/cancel,
    /// row pick, window raise).
    static let allowedAXActions: Set<String> = [
        "AXPress", "AXShowMenu", "AXIncrement", "AXDecrement",
        "AXConfirm", "AXCancel", "AXPick", "AXRaise", "AXOpen",
        "AXShowAlternateUI", "AXShowDefaultUI",
    ]

    /// Boolean AX attributes the model may write — selection, focus,
    /// disclosure state, window state. Never AXValue (that path is
    /// axSetValue, which carries a deny-listed text payload).
    static let allowedAXAttributes: Set<String> = [
        "AXSelected", "AXFocused", "AXExpanded", "AXMain",
        "AXMinimized", "AXFrontmost",
    ]

    /// Act-time re-checks: the loop gates against the observe-time
    /// snapshot, but the screen can change in the seconds a model decision
    /// takes. Two things are re-read live right before keystrokes post:
    /// (a) a password prompt grabbing focus — a secure field errors the
    /// step rather than swallowing the text; (b) frontmost flipping to a
    /// terminal — the payload then gets the command-level scan the loop
    /// applied to whatever was frontmost when it decided. Either refusal
    /// errors the step; the next observe re-gates honestly.
    private func actTimeChecks(payload: String?) throws {
        let sys = AXUIElementCreateSystemWide()
        AXReader.bindTimeout(sys)
        var v: CFTypeRef?
        if AXUIElementCopyAttributeValue(sys, kAXFocusedUIElementAttribute as CFString, &v) == .success,
           let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() {
            var role: CFTypeRef?
            if AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &role) == .success,
               (role as? String) == "AXSecureTextField" {
                throw S1Error.axFailed("secure text field grabbed focus — keystrokes refused")
            }
        }
        if let payload,
           let front = NSWorkspace.shared.frontmostApplication?.localizedName,
           SafetyGate.terminalApps.contains(front),
           case .needsHuman(let r) = SafetyGate.evaluateTerminalPayload(payload) {
            throw S1Error.axFailed("keystrokes refused: \(r)")
        }
    }

    /// Unicode-safe typing (works for Indonesian diacritics etc.).
    /// One CGEvent carries a bounded unicode string — longer text is chunked
    /// so paragraphs aren't silently truncated mid-glyph.
    func postUnicode(_ text: String) throws {
        let src = CGEventSource(stateID: .hidSystemState)
        var buf = ""
        var chunks: [String] = []
        for c in text {   // Character-wise: surrogate pairs never get split
            if buf.utf16.count + String(c).utf16.count > 200 {
                chunks.append(buf); buf = ""
            }
            buf.append(c)
        }
        if !buf.isEmpty { chunks.append(buf) }
        for chunk in chunks {
            let utf16 = Array(chunk.utf16)
            guard let down = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: false) else {
                throw S1Error.aborted("cannot create keyboard events")
            }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            down.post(tap: .cghidEventTap)
            up.post(tap: .cghidEventTap)
            usleep(10_000)
        }
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
        up?.flags = flags   // modifiers stay "held" through the release
        down?.post(tap: .cghidEventTap)
        usleep(50_000)
        up?.post(tap: .cghidEventTap)
    }

    static let keyCodes: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
        "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32,
        "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
        "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25, "0": 29,
        "return": 36, "enter": 36, "tab": 48, "space": 49, "spacebar": 49,
        "delete": 51, "backspace": 51, "del": 51, "escape": 53, "esc": 53,
        "minus": 27, "equal": 24, "leftbracket": 33, "rightbracket": 30, "backslash": 42,
        "semicolon": 41, "quote": 39, "comma": 43, "period": 47, "slash": 44, "grave": 50,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98,
        "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "home": 115, "end": 119, "pageup": 116, "pgup": 116,
        "pagedown": 121, "pgdn": 121, "forwarddelete": 117, "fwddelete": 117,
        "left": 123, "leftarrow": 123, "right": 124, "rightarrow": 124,
        "down": 125, "downarrow": 125, "up": 126, "uparrow": 126,
    ]

    func openApp(named name: String) async throws {
        let ws = NSWorkspace.shared
        guard let url = AppResolver.resolve(name) else {
            throw S1Error.aborted("app not found: \(name)")
        }
        // "open X" means "use X" — an app opened in the background never
        // comes forward, and the next typeText lands in whatever had
        // focus. Activate explicitly; it also covers the already-running
        // relaunch path.
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        try await ws.openApplication(at: url, configuration: cfg)
        // openApplication returns before the window server flips frontmost —
        // the next observe would still see the OLD app and could inject
        // keystrokes into it (or miss a terminal's command scan). Wait,
        // bounded, until the opened app actually owns the keyboard.
        let wanted = url.standardizedFileURL
        for _ in 0..<40 {   // ~2s max
            if ws.frontmostApplication?.bundleURL?.standardizedFileURL == wanted { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}

/// Resolves spoken/typed app names to installed app URLs — exact, then
/// fuzzy (bigram similarity) so dictation mangles like "teks edit" still
/// find TextEdit.
enum AppResolver {
    static func resolve(_ name: String) -> URL? {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: name) ??
            URL(fileURLWithPath: "/System/Applications/\(name).app").exists ??
            URL(fileURLWithPath: "/Applications/\(name).app").exists {
            return url
        }
        var best: (URL, Double)? = nil
        // Same directory set the STT vocabulary learns from — resolve and
        // recognition must agree on what "installed" means.
        for dir in InstalledApps.appDirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let stem = String(n.dropLast(4))
                let score = similarity(name, stem)
                if score > (best?.1 ?? 0.49) {
                    best = (URL(fileURLWithPath: "\(dir)/\(n)"), score)
                }
            }
        }
        // Spotlight index finds apps living outside the standard dirs
        // (e.g. ~/bin, per-user installs) — same fuzzy gate applies.
        for url in spotlightApps() {
            let score = similarity(name, url.deletingPathExtension().lastPathComponent)
            if score > (best?.1 ?? 0.49) { best = (url, score) }
        }
        return best?.0
    }

    /// `mdfind` over the Spotlight index for installed applications.
    /// Returns paths; caller scores them. Fails soft (nil) when mdfind is
    /// unavailable or exceeds `timeout` — resolution simply falls back to
    /// the directory scan.
    static func spotlightApps(timeout: TimeInterval = 3) -> [URL] {
        let p = Process()
        let out = Pipe()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        p.arguments = ["kMDItemKind == 'Application'"]
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            // A wedged Spotlight index can stall mdfind far beyond a step's
            // patience — enforce the advertised bound.
            let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            killer.cancel()
            guard p.terminationStatus == 0, p.terminationReason == .exit else { return [] }
            return String(decoding: data, as: UTF8.self)
                .split(separator: "\n")
                .filter { $0.hasSuffix(".app") }
                .map { URL(fileURLWithPath: String($0)) }
        } catch { return [] }
    }

    /// Dice coefficient over character bigrams of normalized strings.
    static func similarity(_ a: String, _ b: String) -> Double {
        func grams(_ s: String) -> Set<String> {
            let c = Array(s.lowercased().components(separatedBy: .alphanumerics.inverted).joined())
            guard c.count > 1 else { return Set(c.map(String.init)) }
            return Set((0..<c.count - 1).map { String(c[$0...$0 + 1]) })
        }
        let (ga, gb) = (grams(a), grams(b))
        guard !ga.isEmpty, !gb.isEmpty else { return 0 }
        let dice = 2.0 * Double(ga.intersection(gb).count) / Double(ga.count + gb.count)
        // Containment beats bigrams for short names: "word" ⊂ "microsoft
        // word" should still resolve, "edit" ⊂ "textedit" likewise.
        let (na, nb) = (normalized(a), normalized(b))
        if na.count >= 3, nb.count >= 3, nb.contains(na) || na.contains(nb) {
            return max(dice, 0.75)
        }
        return dice
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased().components(separatedBy: .alphanumerics.inverted).joined()
    }
}

extension URL {
    var exists: URL? { FileManager.default.fileExists(atPath: path) ? self : nil }
}
