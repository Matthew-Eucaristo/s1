import Foundation
import ApplicationServices
import CoreGraphics

public struct PermissionReport: Sendable {
    public var accessibility: Bool
    public var screenRecording: Bool
    public var microphone: Bool
    public var notes: [String]

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

        return PermissionReport(accessibility: ax, screenRecording: screen,
                                microphone: mic, notes: notes)
    }

    public static func describe(_ r: PermissionReport) -> String {
        """
        preflight:
          accessibility       \(r.accessibility ? "granted" : "MISSING")
          screen recording    \(r.screenRecording ? "granted" : "MISSING")
          microphone          \(r.microphone ? "granted" : "missing (voice only)")
        \(r.notes.map { "  ! " + $0 }.joined(separator: "\n"))
        """
    }
}

import AVFoundation

func AVCaptureDeviceAuthStatus() -> AVAuthorizationStatus {
    AVCaptureDevice.authorizationStatus(for: .audio)
}
