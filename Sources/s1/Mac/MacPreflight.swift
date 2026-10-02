#if os(macOS)
import ApplicationServices
import CoreGraphics
import Foundation

/// macOS TCC preflight: Screen Recording (for screenshots and window info)
/// and Accessibility (for synthetic input and the AX tree). A fresh Mac VM
/// usually has neither granted.
enum MacPreflight {
    static func runChecks(request: Bool) -> [PreflightCheck] {
        var checks: [PreflightCheck] = []

        let version = ProcessInfo.processInfo.operatingSystemVersion
        checks.append(PreflightCheck(
            name: "macOS version",
            status: version.majorVersion >= 14 ? .ok : .missing,
            detail: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion) (ScreenCaptureKit screenshot API needs 14+)"
        ))

        let screenRecording = CGPreflightScreenCaptureAccess()
        if request && !screenRecording {
            _ = CGRequestScreenCaptureAccess()
        }
        checks.append(PreflightCheck(
            name: "Screen Recording",
            status: screenRecording ? .ok : .missing,
            detail: screenRecording ? "granted" : "NOT granted — screenshots and the window list will fail",
            fix: "System Settings → Privacy & Security → Screen Recording → enable \(terminalName()), then restart it"
        ))

        let accessibility = AXIsProcessTrusted()
        if request && !accessibility {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        checks.append(PreflightCheck(
            name: "Accessibility",
            status: accessibility ? .ok : .missing,
            detail: accessibility ? "granted" : "NOT granted — synthetic input (CGEvent) and the AX tree will not work",
            fix: "System Settings → Privacy & Security → Accessibility → enable \(terminalName()), then restart it"
        ))

        return checks
    }

    static func terminalName() -> String {
        ProcessInfo.processInfo.environment["TERM_PROGRAM"] ?? "your terminal app"
    }
}
#endif
