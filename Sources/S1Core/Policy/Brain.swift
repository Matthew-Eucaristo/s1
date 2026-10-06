import Foundation

/// The one place that turns role assignments into brains — the app, the
/// CLI and the always-on daemon all build their agent here, so they can
/// never disagree about what "auto" means.
///
/// S1 is the deterministic grammar, judged step by step when a judge is
/// assigned; S2 takes the steps below the threshold. Seeing the screen is
/// a capability, not a role: the judge gets screenshots when it can read
/// them, S2 gets one with each escalation when it can, and with neither
/// s1 works from the accessibility tree alone.
public enum Brain {
    public static func policy(config: S1Config = .load(),
                              env: [String: String] = ProcessInfo.processInfo.environment) -> any Policy {
        JudgedPolicy.wrapIfConfigured(AXPolicy(),
                                      endpoint: Models.endpoint(.judge, config: config, env: env),
                                      images: Models.seesScreen(.judge, config: config, env: env))
    }

    public static func reasoner(config: S1Config = .load(),
                                env: [String: String] = ProcessInfo.processInfo.environment) -> (any Reasoner)? {
        Models.endpoint(.reasoner, config: config, env: env).map {
            LLMReasoner(endpoint: $0, vision: Models.seesScreen(.reasoner, config: config, env: env))
        }
    }

    /// One line for logs and `s1 config`: what S1 and S2 are right now.
    public static func describe(config: S1Config = .load(),
                                env: [String: String] = ProcessInfo.processInfo.environment) -> String {
        func tag(_ r: ModelRole) -> String { Models.seesScreen(r, config: config, env: env) ? " (sees screen)" : "" }
        let judge = Models.endpoint(.judge, config: config, env: env).map { " + judge \($0.model)\(tag(.judge))" } ?? ""
        let s2 = Models.endpoint(.reasoner, config: config, env: env).map { "\($0.model)\(tag(.reasoner))" } ?? "off"
        return "S1 grammar\(judge) · S2 \(s2)"
    }
}
