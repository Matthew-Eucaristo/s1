import AppKit
import Foundation

/// Optional background executor: Cua Driver (MIT, trycua/cua) delivers
/// keys/text/launches to a target pid without stealing focus. Off by
/// default; only gated actions reach it (the SafetyGate runs first), and
/// anything it can't take — or a failed call — goes to the CGEvent path.
/// The AGPL perception extension is never used or bundled.
public enum CuaDriver {
    public static let docs = URL(string: "https://cua.ai/docs/cua-driver")!

    public static func binary(env: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let home = NSHomeDirectory()
        let candidates = [env["CUA_DRIVER_PATH"], "/opt/homebrew/bin/cua-driver", "/usr/local/bin/cua-driver",
                          home + "/.local/bin/cua-driver", home + "/.cua/bin/cua-driver"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// On by default (used whenever `cua-driver` is installed); `executor:
    /// "cgevent"` (or `S1_EXECUTOR=cgevent`) opts out.
    public static func enabled(_ cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        (env["S1_EXECUTOR"] ?? cfg.executor) != "cgevent"
    }

    /// Tool + JSON args for the actions Cua handles; nil = use CGEvent.
    public static func call(for action: Action, pid: pid_t?,
                            bundleID: (String) -> String? = Self.bundleID) -> (tool: String, args: String)? {
        var args: [String: Any] = ["session": "s1"]
        let tool: String
        switch action {
        case .typeText(let text):
            guard let pid else { return nil }
            tool = "type_text"; args["pid"] = Int(pid); args["text"] = text
        case .keyCombo(let keys):
            guard let pid else { return nil }
            tool = "hotkey"; args["pid"] = Int(pid); args["keys"] = keys.map { $0.lowercased() }
        case .openApp(let name):
            guard let id = bundleID(name) else { return nil }
            tool = "launch_app"; args["bundle_id"] = id
        default:
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else { return nil }
        return (tool, String(decoding: data, as: UTF8.self))
    }

    /// Scroll needs no coordinates on the keystroke path — just pid +
    /// direction — so it maps without the window lookup clicks require.
    /// s1's `dy > 0` means content moves DOWN (the wheel rolls up).
    public static func scrollCall(dx: Double, dy: Double, pid: pid_t) -> (tool: String, args: String)? {
        let direction: String, amount: Int
        if abs(dy) >= abs(dx) {
            direction = dy > 0 ? "down" : "up"
            amount = Int((abs(dy) / 120).rounded())
        } else {
            direction = dx > 0 ? "right" : "left"
            amount = Int((abs(dx) / 120).rounded())
        }
        let args: [String: Any] = ["session": "s1", "pid": Int(pid),
                                   "direction": direction, "by": "line",
                                   "amount": max(1, min(amount, 10))]
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else { return nil }
        return ("scroll", String(decoding: data, as: UTF8.self))
    }

    /// One window record from `list_windows` — only the fields the
    /// click-coordinate conversion reads.
    public struct CuaWindow: Sendable {
        public let id: Int
        public let pid: pid_t
        public let x: Double, y: Double, w: Double, h: Double
        public let z: Int
    }

    /// `cua-driver call list_windows` filtered to one app. Returns [] on any
    /// failure — callers fall back to CGEvent rather than trusting nothing.
    public static func windows(binary: String, pid: pid_t, timeout: TimeInterval = 10) -> [CuaWindow] {
        let argsObj: [String: Any] = ["session": "s1", "pid": Int(pid), "on_screen_only": true]
        guard let data = try? JSONSerialization.data(withJSONObject: argsObj, options: [.sortedKeys]),
              let out = try? run(binary, argv: ["call", "list_windows", String(decoding: data, as: UTF8.self)],
                               timeout: timeout),
              let parsed = try? JSONSerialization.jsonObject(with: Data(out.utf8)) else { return [] }
        // The payload may be a bare array or wrapped in {"windows": [...]}.
        let rows: [[String: Any]]
        if let arr = parsed as? [[String: Any]] { rows = arr }
        else if let dict = parsed as? [String: Any],
                let arr = (dict["windows"] ?? dict["result"]) as? [[String: Any]] { rows = arr }
        else { return [] }
        return rows.compactMap { r in
            let b = (r["bounds"] as? [String: Any]) ?? r
            guard let x = Self.num(b["x"]), let y = Self.num(b["y"]),
                  let w = Self.num(b["width"] ?? b["w"]), let h = Self.num(b["height"] ?? b["h"]),
                  let id = Self.num(r["window_id"] ?? r["id"]).map(Int.init) else { return nil }
            return CuaWindow(id: id, pid: pid_t(Int(Self.num(r["pid"]) ?? Double(pid))),
                             x: x, y: y, w: w, h: h,
                             z: Int(Self.num(r["z_index"]) ?? 0))
        }
    }

    static func num(_ v: Any?) -> Double? {
        switch v {
        case let d as Double: return d
        case let i as Int: return Double(i)
        case let s as String: return Double(s)
        default: return nil
        }
    }

    /// screen-point → window-local screenshot px. The window holding the
    /// point is the target; falls back to the topmost (max z) when the
    /// point sits outside every known frame.
    static func windowLocal(_ p: CGPoint, in windows: [CuaWindow])
        -> (x: Double, y: Double, win: CuaWindow)? {
        let w = windows.first { p.x >= $0.x && p.x <= $0.x + $0.w && p.y >= $0.y && p.y <= $0.y + $0.h }
            ?? windows.max { $0.z < $1.z }
        guard let w else { return nil }
        let s = scale(for: p)
        return ((Double(p.x) - w.x) * s, (Double(p.y) - w.y) * s, w)
    }

    /// Backing scale for the display showing `point` — cua's window-local
    /// coordinates are screenshot pixels, not screen points.
    static func scale(for point: CGPoint) -> CGFloat {
        NSScreen.screens.first { $0.frame.contains(point) }?.backingScaleFactor
            ?? NSScreen.main?.backingScaleFactor ?? 2
    }

    public static func bundleID(_ name: String) -> String? {
        AppResolver.resolve(name).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// `cua-driver <argv…>` — argv, never a shell. Bounded wait.
    static func run(_ binary: String, argv: [String], timeout: TimeInterval = 20) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = argv
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        try p.run()
        let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        killer.cancel()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData.isEmpty ? data : errData, as: UTF8.self)
            throw S1Error.aborted("cua-driver \(argv.first ?? "?") failed: \(msg.prefix(200))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CuaActuator: Actuator {
    public let name = "cua-driver"
    let binary: String
    let fallback = CGEventActuator()

    /// Set once Cua Driver reports it lacks its own permissions: every later
    /// call would fail the same way, so this process stops paying for it.
    /// Cleared by a relaunch (after granting) or `resetAvailability()`.
    nonisolated(unsafe) private static var missingPermissions = false
    private static let lock = NSLock()
    public static var needsPermissions: Bool { lock.withLock { missingPermissions } }
    public static func resetAvailability() { lock.withLock { missingPermissions = false } }

    public init(binary: String) { self.binary = binary }

    public func perform(_ action: Action, frontmostPID: pid_t?) async throws -> String {
        if !Self.needsPermissions, let c = try? await cuaCall(for: action, pid: frontmostPID) {
            let bin = binary
            do {
                let out = try await Task.detached { try CuaDriver.run(bin, argv: c) }.value
                DebugTrace.event("cua", ["tool": c[0], "ok": true])
                return "cua \(c[0]): \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"
            } catch {
                DebugTrace.event("cua", ["tool": c[0], "ok": false, "error": "\(error)"])
                if "\(error)".contains("permissions_pending") { Self.lock.withLock { Self.missingPermissions = true } }
                let r = try await fallback.perform(action, frontmostPID: frontmostPID)
                return r + " (cua fallback: \(error.localizedDescription.prefix(120)))"
            }
        }
        return try await fallback.perform(action, frontmostPID: frontmostPID)
    }

    /// Build the `cua-driver` argv for an action — nil means CGEvent takes it.
    /// Click-shape actions need the window-local pixel space cua clicks in:
    /// screen-point → (point − window origin) × backing scale, resolved via
    /// `list_windows`. A lookup failure throws → perform() falls back.
    private func cuaCall(for action: Action, pid: pid_t?) async throws -> [String]? {
        switch action {
        case .scroll(let dx, let dy):
            guard let pid, let c = CuaDriver.scrollCall(dx: dx, dy: dy, pid: pid) else { return nil }
            return ["call", c.tool, c.args]
        case .click, .rightClick, .doubleClick, .drag, .moveMouse:
            return try await clickCall(action, pid: pid)
        default:
            guard let c = CuaDriver.call(for: action, pid: pid) else { return nil }
            return ["call", c.tool, c.args]
        }
    }

    private func clickCall(_ action: Action, pid: pid_t?) async throws -> [String]? {
        // move_cursor speaks desktop screenshot pixels (get_desktop_state
        // space) — needs no pid or window lookup, and its schema rejects
        // top-level `pid` outright.
        if case .moveMouse(let x, let y) = action {
            let s = NSScreen.main?.backingScaleFactor ?? 2
            let args: [String: Any] = ["session": "s1", "scope": "desktop",
                                       "target": ["kind": "display", "display_id": "primary"],
                                       "x": x * Double(s), "y": y * Double(s)]
            guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else { return nil }
            return ["call", "move_cursor", String(decoding: data, as: UTF8.self)]
        }
        guard let pid else { return nil }
        let bin = binary
        let windows = await Task.detached { CuaDriver.windows(binary: bin, pid: pid) }.value
        guard !windows.isEmpty else { return nil }
        func local(_ p: CGPoint) -> (x: Double, y: Double, win: CuaDriver.CuaWindow)? {
            CuaDriver.windowLocal(p, in: windows)
        }

        var args: [String: Any] = ["session": "s1", "pid": Int(pid)]
        let tool: String
        switch action {
        case .click(let x, let y):
            guard let l = local(CGPoint(x: x, y: y)) else { return nil }
            tool = "click"; args["x"] = l.x; args["y"] = l.y
            args["button"] = "left"; args["window_id"] = l.win.id
        case .rightClick(let x, let y):
            guard let l = local(CGPoint(x: x, y: y)) else { return nil }
            tool = "click"; args["x"] = l.x; args["y"] = l.y
            args["button"] = "right"; args["window_id"] = l.win.id
        case .doubleClick(let x, let y):
            // click's `count` field is the documented pixel-path double
            // click — avoids the dedicated double_click tool, whose
            // coordinate space is underdocumented.
            guard let l = local(CGPoint(x: x, y: y)) else { return nil }
            tool = "click"; args["x"] = l.x; args["y"] = l.y
            args["count"] = 2; args["window_id"] = l.win.id
        case .drag(let x, let y, let tx, let ty):
            guard let from = local(CGPoint(x: x, y: y)),
                  let to = local(CGPoint(x: tx, y: ty)) else { return nil }
            // macOS has no background drag — cua requires foreground +
            // window_id; a stolen focus for a drag is still a fair trade
            // vs. not doing it at all, and CGEvent can't drag by pid either.
            tool = "drag"
            args["from_x"] = from.x; args["from_y"] = from.y
            args["to_x"] = to.x; args["to_y"] = to.y
            args["delivery_mode"] = "foreground"; args["window_id"] = from.win.id
        default:
            return nil
        }
        guard let data = try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys]) else { return nil }
        return ["call", tool, String(decoding: data, as: UTF8.self)]
    }
}

public enum Executors {
    /// The live actuator: Cua when opted in and installed, CGEvent otherwise.
    public static func live() -> any Actuator {
        if CuaDriver.enabled(), let b = CuaDriver.binary() { return CuaActuator(binary: b) }
        return CGEventActuator()
    }
}
