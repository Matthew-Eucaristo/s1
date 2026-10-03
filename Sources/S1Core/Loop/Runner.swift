import Foundation

/// libproc isn't in Swift's Darwin module — declare it directly. Links from
/// libsystem_kernel like the standard tooling (ps, lsof) uses.
@_silgen_name("proc_pidpath")
private func procPidPath(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?,
                         _ buffersize: UInt32) -> Int32

/// Shared run setup for CLI commands: logger + perceiver + actuator + gate + loop.
public enum S1Runner {
    /// Pid file marking a live agent run. Two agents typing at once is the
    /// disaster this prevents: any process can check screen ownership.
    public static let lockPath = NSHomeDirectory() + "/.s1/run.pid"

    /// True while another process holds the run lock. Stale files after a
    /// crash expire via pid-liveness AND identity: a recycled pid owned by
    /// an unrelated process is not an s1 run.
    public static func anotherRunActive() -> Bool {
        guard let txt = try? String(contentsOfFile: lockPath, encoding: .utf8),
              let other = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
              other != ProcessInfo.processInfo.processIdentifier,
              pidLooksLikeS1(other) else { return false }
        return true
    }

    /// Is this pid a live s1 binary or the S1 app? Liveness alone lies on
    /// pid reuse — check the executable path too.
    public static func pidLooksLikeS1(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard procPidPath(pid, &buf, UInt32(buf.count)) > 0 else { return true }
        // Couldn't read the path (foreign process, permission) — liveness
        // was proven, so assume busy rather than racing a real agent.
        let path = String(cString: buf).lowercased()
        return path.hasSuffix("/s1") || path.contains("/s1.app/") || path.contains("/s1-cli")
    }

    @discardableResult
    public static func run(goal: String, policy: any Policy, artifacts: String,
                           maxSteps: Int, threshold: Double, dryRun: Bool,
                           allowIrreversible: Bool, killSwitch: String?,
                           s2: (any Reasoner)? = nil,
                           onStep: (@Sendable (StepRecord) -> Void)? = nil) async throws -> (report: RunReport, logger: RunLogger) {
        if !dryRun {
            if anotherRunActive() {
                let txt = (try? String(contentsOfFile: lockPath, encoding: .utf8)) ?? "?"
                throw S1Error.busy("another s1 run is in progress (pid \(txt.trimmingCharacters(in: .whitespacesAndNewlines))) — wait for it or stop it first")
            }
            try? FileManager.default.createDirectory(
                atPath: (lockPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
            try? String(ProcessInfo.processInfo.processIdentifier).write(
                toFile: lockPath, atomically: true, encoding: .utf8)
        }
        defer { try? FileManager.default.removeItem(atPath: lockPath) }
        var config = LoopConfig()
        config.maxSteps = maxSteps
        config.confidenceThreshold = threshold
        config.dryRun = dryRun
        config.killSwitchPath = killSwitch

        let root = URL(fileURLWithPath: artifacts)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let actuator: any Actuator = dryRun ? DryRunActuator() : CGEventActuator()

        let logger = try RunLogger(
            goal: goal, root: root,
            config: [
                "policy": policy.name,
                "actuator": actuator.name,
                "threshold": String(threshold),
                "maxSteps": String(maxSteps),
                "allowIrreversible": String(allowIrreversible),
                "s2": s2?.name ?? "none",
            ], onStep: onStep)
        let perceiver = SystemPerceiver(screenshotSink: { img in
            try await logger.saveScreenshot(img)
        })

        let gate = SafetyGate(allowReversible: true, allowIrreversible: allowIrreversible)
        let loop = AgentLoop(config: config, perceiver: perceiver, actuator: actuator,
                             gate: gate, s2: s2)

        print("run dir: \(logger.runDir.path)")
        let report = try await loop.run(goal: goal, policy: policy, logger: logger)
        print("status: \(report.status.rawValue) | steps: \(report.steps) | escalations: \(report.escalations)")
        return (report, logger)
    }
}
