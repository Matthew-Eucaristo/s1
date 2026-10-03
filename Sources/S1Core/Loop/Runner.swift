import Foundation

/// Shared run setup for CLI commands: logger + perceiver + actuator + gate + loop.
public enum S1Runner {
    /// Pid file marking a live agent run. Two agents typing at once is the
    /// disaster this prevents: any process can check screen ownership.
    public static let lockPath = NSHomeDirectory() + "/.s1/run.pid"

    /// True while another process holds the run lock (stale files after a
    /// crash expire via pid-liveness).
    public static func anotherRunActive() -> Bool {
        guard let txt = try? String(contentsOfFile: lockPath, encoding: .utf8),
              let other = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
              other != ProcessInfo.processInfo.processIdentifier,
              kill(other, 0) == 0 else { return false }
        return true
    }

    @discardableResult
    public static func run(goal: String, policy: any Policy, artifacts: String,
                           maxSteps: Int, threshold: Double, dryRun: Bool,
                           allowIrreversible: Bool, killSwitch: String?,
                           s2: (any Reasoner)? = nil,
                           onStep: (@Sendable (StepRecord) -> Void)? = nil) async throws -> (report: RunReport, logger: RunLogger) {
        if !dryRun {
            if let txt = try? String(contentsOfFile: lockPath, encoding: .utf8),
               let other = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
               other != ProcessInfo.processInfo.processIdentifier, kill(other, 0) == 0 {
                throw S1Error.busy("another s1 run is in progress (pid \(other)) — wait for it or stop it first")
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
