import Foundation

/// One preflight check result. `missing` fails the preflight (exit code 1);
/// `skipped` does not (it means "not applicable on this platform").
public struct PreflightCheck: Equatable {
    public enum Status: String {
        case ok
        case missing
        case skipped
    }

    public let name: String
    public let status: Status
    public let detail: String
    public let fix: String?

    public init(name: String, status: Status, detail: String, fix: String? = nil) {
        self.name = name
        self.status = status
        self.detail = detail
        self.fix = fix
    }
}

/// Portable preflight model + report formatting. The macOS-specific checks
/// (Screen Recording / Accessibility TCC) live in Mac/MacPreflight.swift.
public enum Preflight {
    public static var platformName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(Linux)
        return "Linux"
        #else
        return "unknown"
        #endif
    }

    /// Exit code: 1 when something is missing, 0 otherwise.
    public static func exitCode(_ checks: [PreflightCheck]) -> Int32 {
        checks.contains { $0.status == .missing } ? 1 : 0
    }

    public static func format(_ checks: [PreflightCheck]) -> String {
        let icons: [PreflightCheck.Status: String] = [
            .ok: "OK  ",
            .missing: "MISS",
            .skipped: "SKIP",
        ]
        var lines = ["s1 preflight"]
        for check in checks {
            lines.append("  [\(icons[check.status] ?? check.status.rawValue)] \(check.name): \(check.detail)")
            if let fix = check.fix, check.status != .ok {
                lines.append("          fix: \(fix)")
            }
        }
        if checks.contains(where: { $0.status == .missing }) {
            lines.append("result: some checks failed — fix them before `run` (dry-run still works).")
        } else {
            lines.append("result: all good.")
        }
        return lines.joined(separator: "\n")
    }

    /// Checks for non-macOS platforms: everything is skipped.
    public static func nonMacOSChecks(platformName: String) -> [PreflightCheck] {
        [PreflightCheck(name: "platform",
                        status: .skipped,
                        detail: "not macOS (\(platformName)) — TCC checks are macOS-only")]
    }
}
