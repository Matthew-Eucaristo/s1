import Foundation

/// Shared run setup for CLI commands: logger + perceiver + actuator + gate + loop.
public enum S1Runner {
    public static func run(goal: String, policy: any Policy, artifacts: String,
                           maxSteps: Int, threshold: Double, dryRun: Bool,
                           allowIrreversible: Bool, killSwitch: String?) async throws {
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
            ])
        let perceiver = SystemPerceiver(screenshotSink: { img in
            try await logger.saveScreenshot(img)
        })

        let gate = SafetyGate(allowReversible: true, allowIrreversible: allowIrreversible)
        let loop = AgentLoop(config: config, perceiver: perceiver, actuator: actuator, gate: gate)

        print("run dir: \(logger.runDir.path)")
        let report = try await loop.run(goal: goal, policy: policy, logger: logger)
        print("status: \(report.status.rawValue) | steps: \(report.steps) | escalations: \(report.escalations)")

        if report.status != .done { throw S1Error.aborted(report.status.rawValue) }
    }
}
