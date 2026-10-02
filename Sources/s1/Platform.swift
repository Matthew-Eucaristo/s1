import Foundation

/// Factories that pick the right implementation for the current platform.
/// Everything platform-specific sits behind `#if` guards, so the portable
/// core (gate, loop, log, preflight model, CLI) builds and tests on Linux too.
public enum Platform {
    public static func defaultPerceiver() -> Perceiver {
        #if canImport(ScreenCaptureKit)
        return ScreenCaptureKitPerceiver()
        #else
        return UnavailablePerceiver(reason: "ScreenCaptureKit is unavailable on this platform (macOS 14+ required)")
        #endif
    }

    public static func defaultBackend() -> ActionBackend {
        #if canImport(CoreGraphics)
        return CGEventBackend()
        #else
        return UnavailableBackend(reason: "CGEvent is unavailable on this platform (macOS required)")
        #endif
    }
}
