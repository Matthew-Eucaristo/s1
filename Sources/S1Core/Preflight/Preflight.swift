import Foundation
import ApplicationServices
import AVFoundation
import CoreGraphics
import IOKit.hid

public struct PermissionReport: Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    public var microphone: Bool
    /// Input Monitoring — needed for the global hotkey. Separate TCC bucket
    /// from Accessibility; a process can have AX yet see zero key events.
    public var inputMonitoring: Bool
    public var notes: [String]

    public init(accessibility: Bool = false, screenRecording: Bool = false,
                microphone: Bool = false, inputMonitoring: Bool = false,
                notes: [String] = []) {
        self.accessibility = accessibility
        self.screenRecording = screenRecording
        self.microphone = microphone
        self.inputMonitoring = inputMonitoring
        self.notes = notes
    }

    public var ready: Bool { accessibility && screenRecording }
}

/// Checks the TCC gates this agent needs and explains what's missing.
/// Invariant encoded here: ScreenCaptureKit only picks up a grant on the
/// NEXT process launch — after granting Screen Recording, relaunch s1.
public enum Preflight {
    public static func check(request: Bool) -> PermissionReport {
        var notes: [String] = []

        // Literal key: kAXTrustedCheckOptionPrompt is a mutable global and not concurrency-safe.
        let axPrompt = ["AXTrustedCheckOptionPrompt": request] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(axPrompt)
        if !ax { notes.append("Accessibility: System Settings → Privacy & Security → Accessibility → enable this process") }

        let screen = CGPreflightScreenCaptureAccess()
        if !screen {
            if request { _ = CGRequestScreenCaptureAccess() }
            notes.append("Screen & System Audio Recording: grant in System Settings, then RELAUNCH — ScreenCaptureKit ignores grants made mid-process")
        }

        var mic = false
        if #available(macOS 14, *) {
            mic = AVCaptureDeviceAuthStatus() == .authorized
        }
        if !mic { notes.append("Microphone: needed only for voice (P4)") }

        var inputMon = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        if !inputMon {
            // IOHIDRequestAccess opens the System Settings prompt once;
            // without the grant, event taps/global monitors see no events.
            if request { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                inputMon = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted }
            notes.append("Input Monitoring: needed for the global hotkey (serve/app)")
        }

        return PermissionReport(accessibility: ax, screenRecording: screen,
                                microphone: mic, inputMonitoring: inputMon, notes: notes)
    }

    public static func describe(_ r: PermissionReport) -> String {
        """
        preflight:
          accessibility       \(r.accessibility ? "granted" : "MISSING")
          screen recording    \(r.screenRecording ? "granted" : "MISSING")
          microphone          \(r.microphone ? "granted" : "missing (voice only)")
          input monitoring    \(r.inputMonitoring ? "granted" : "missing (hotkey)")
        \(r.notes.map { "  ! " + $0 }.joined(separator: "\n"))
        """
    }
}

func AVCaptureDeviceAuthStatus() -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
}
