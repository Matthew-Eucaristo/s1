import Foundation

/// Seam for perception. macOS implements this with ScreenCaptureKit
/// (`ScreenCaptureKitPerceiver`, see Mac/); tests and dry-runs inject fakes.
public protocol Perceiver {
    /// Collects one observation. Should not throw: individual failures belong
    /// in `Observation.errors` so the loop and the log stay honest.
    func observe(runDir: String) -> Observation
}

/// Fallback used on platforms without ScreenCaptureKit (e.g. Linux CI):
/// every observation is empty except for the error explaining why.
public struct UnavailablePerceiver: Perceiver {
    public let reason: String

    public init(reason: String) {
        self.reason = reason
    }

    public func observe(runDir: String) -> Observation {
        Observation(ts: Timestamp.nowISO(), errors: ["perceive: \(reason)"])
    }
}

/// Deterministic perceiver for tests and dry-runs on any platform.
public struct StaticPerceiver: Perceiver {
    public let observation: Observation

    public init(observation: Observation) {
        self.observation = observation
    }

    public init() {
        self.observation = Observation(ts: Timestamp.nowISO(), windowCount: 0)
    }

    public func observe(runDir: String) -> Observation {
        observation
    }
}
