import Foundation

/// Shared run setup for CLI commands: logger + perceiver + actuator + gate + loop.
public enum S1Runner {
    @discardableResult
    public static func run(goal: String, policy: any Policy, artifacts: String,
                           maxSteps: Int, threshold: Double, dryRun: Bool,
                           allowIrreversible: Bool, killSwitch: String?,
                           s2: (any Reasoner)? = nil,
                           onStep: (@Sendable (StepRecord) -> Void)? = nil) async throws -> (report: RunReport, logger: RunLogger) {
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
