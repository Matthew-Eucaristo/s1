#if canImport(ScreenCaptureKit)
import ApplicationServices
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

/// macOS perception: screenshot + window list via ScreenCaptureKit, plus a
/// best-effort Accessibility (AX) summary. Requires macOS 14+ for
/// `SCScreenshotManager` and the Screen Recording / Accessibility TCC
/// permissions — check with `s1-cli preflight` first.
public final class ScreenCaptureKitPerceiver: Perceiver {
    public init() {}

    public func observe(runDir: String) -> Observation {
        let box = ResultBox()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let collected = await ScreenCaptureKitPerceiver.collect(runDir: runDir)
            box.set(collected)
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + 10) == .timedOut {
            return Observation(ts: Timestamp.nowISO(),
                               errors: ["perceive: ScreenCaptureKit collection timed out after 10s"])
        }

        var observation = Observation(ts: Timestamp.nowISO())
        if let collected = box.get() {
            observation.screenshot = collected.screenshot
            observation.windowCount = collected.windowCount
            observation.windowTitles = collected.windowTitles
            observation.errors = collected.errors
        } else {
            observation.errors = ["perceive: collection produced no result"]
        }
        observation.axFocusedApp = AXSummary.focusedApp()
        return observation
    }

    private static func collect(runDir: String) async -> Collected {
        var collected = Collected()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            collected.windowCount = content.windows.count
            collected.windowTitles = content.windows.prefix(20).compactMap { $0.title }

            guard let display = content.displays.first else {
                collected.errors.append("screenshot: no display found")
                return collected
            }
            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter,
                                                                   configuration: configuration)
            let url = URL(fileURLWithPath: runDir, isDirectory: true)
                .appendingPathComponent("shot-\(Int(Date().timeIntervalSince1970 * 1000)).png")
            if Self.writePNG(image, to: url) {
                collected.screenshot = url.path
            } else {
                collected.errors.append("screenshot: failed to write PNG to \(url.path)")
            }
        } catch {
            collected.errors.append("perceive: \(error)")
        }
        return collected
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,
                                                                "public.png" as CFString,
                                                                1, nil) else {
            return false
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination)
    }
}

/// Best-effort AX summary (focused app title). v0 stays deliberately shallow;
/// a full recursive tree is future work. Requires the Accessibility permission.
enum AXSummary {
    static func focusedApp() -> String? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedRef)
        guard status == .success, let focusedRef else { return nil }
        let focusedApp = unsafeBitCast(focusedRef, to: AXUIElement.self)
        var titleRef: CFTypeRef?
        let titleStatus = AXUIElementCopyAttributeValue(focusedApp, kAXTitleAttribute as CFString, &titleRef)
        guard titleStatus == .success, let title = titleRef as? String else { return nil }
        return title
    }
}

/// Result handed back from the detached collection task.
private struct Collected {
    var screenshot: String?
    var windowCount: Int?
    var windowTitles: [String] = []
    var errors: [String] = []
}

/// Tiny locked box so the detached task can hand its result back without
/// mutating a captured local variable from concurrent code.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Collected?

    func set(_ newValue: Collected) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Collected? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
#endif
