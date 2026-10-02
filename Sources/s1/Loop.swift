import Foundation

/// The see -> decide -> act -> record loop.
public enum Loop {
    /// Runs up to `steps` iterations, stopping early when the policy returns
    /// `nil`. Every step is appended to `<runDir>/steps.jsonl`; the returned
    /// records mirror the log. Throws only if the log itself cannot be written
    /// (the audit trail must never silently fail).
    @discardableResult
    public static func run(policy: Policy,
                           steps: Int,
                           runDir: String,
                           actuator: Actuator,
                           perceiver: Perceiver,
                           log: StepsLog? = nil) throws -> [StepRecord] {
        let stepsLog: StepsLog
        if let providedLog = log {
            stepsLog = providedLog
        } else {
            stepsLog = try StepsLog(runDir: runDir)
        }

        var records: [StepRecord] = []
        for step in 0..<max(0, steps) {
            let observation = perceiver.observe(runDir: runDir)
            guard let action = policy.next(observation: observation, step: step, history: records) else {
                break
            }
            let execution = actuator.execute(action)
            let record = StepRecord(
                ts: Timestamp.nowISO(),
                step: step,
                observation: observation,
                action: action,
                gate: execution.gate,
                result: execution.result,
                confidence: action.confidence
            )
            try stepsLog.append(record)
            records.append(record)
        }
        return records
    }
}
