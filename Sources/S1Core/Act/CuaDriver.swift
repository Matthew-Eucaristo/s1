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

    /// Whether config/env opted into the Cua executor.
    public static func enabled(_ cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        (env["S1_EXECUTOR"] ?? cfg.executor) == "cua"
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

    public static func bundleID(_ name: String) -> String? {
        AppResolver.resolve(name).flatMap { Bundle(url: $0)?.bundleIdentifier }
    }

    /// `cua-driver <tool> '<json>'` — argv, never a shell. Bounded wait.
    static func run(_ binary: String, tool: String, args: String, timeout: TimeInterval = 20) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = [tool, args]
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
            throw S1Error.aborted("cua-driver \(tool) failed: \(msg.prefix(200))")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

public struct CuaActuator: Actuator {
    public let name = "cua-driver"
    let binary: String
    let fallback = CGEventActuator()

    public init(binary: String) { self.binary = binary }

    public func perform(_ action: Action, frontmostPID: pid_t?) async throws -> String {
        guard let c = CuaDriver.call(for: action, pid: frontmostPID) else {
            return try await fallback.perform(action, frontmostPID: frontmostPID)
        }
        let bin = binary
        do {
            let out = try await Task.detached { try CuaDriver.run(bin, tool: c.tool, args: c.args) }.value
            DebugTrace.event("cua", ["tool": c.tool, "ok": true])
            return "cua \(c.tool): \(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160))"
        } catch {
            DebugTrace.event("cua", ["tool": c.tool, "ok": false, "error": "\(error)"])
            let r = try await fallback.perform(action, frontmostPID: frontmostPID)
            return r + " (cua fallback: \(error.localizedDescription.prefix(120)))"
        }
    }
}

public enum Executors {
    /// The live actuator: Cua when opted in and installed, CGEvent otherwise.
    public static func live() -> any Actuator {
        if CuaDriver.enabled(), let b = CuaDriver.binary() { return CuaActuator(binary: b) }
        return CGEventActuator()
    }
}
