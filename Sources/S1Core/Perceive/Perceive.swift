import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

public protocol Perceiver: Sendable {
    func observe(wantScreenshot: Bool) async throws -> Observation
}

/// Canned perception for tests — never touches the OS.
public struct NullPerceiver: Perceiver {
    public var observation: Observation
    public init(observation: Observation? = nil) {
        self.observation = observation ?? Observation(
            timestamp: Date(), frontmostApp: "TestApp", frontmostPID: 1,
            windows: [], axTree: nil, screenshotPath: nil)
    }
    public func observe(wantScreenshot: Bool) async throws -> Observation { observation }
}

/// Real macOS perception: window list (CGWindowList), AX tree of the frontmost
/// app, on-demand ScreenCaptureKit screenshot (the reason is always logged —
/// screenshots are not the main path, AX is).
public struct SystemPerceiver: Perceiver {
    /// Where screenshots go; nil → they are not saved to disk.
    public var screenshotSink: (@Sendable (CGImage) async throws -> String)?

    public init(screenshotSink: (@Sendable (CGImage) async throws -> String)? = nil) {
        self.screenshotSink = screenshotSink
    }

    public func observe(wantScreenshot: Bool) async throws -> Observation {
        var obs = Observation(
            timestamp: Date(),
            frontmostApp: nil, frontmostPID: nil,
            windows: Self.windowList(),
            axTree: nil, screenshotPath: nil)

        if let app = NSWorkspace.shared.frontmostApplication {
            obs.frontmostApp = app.localizedName
            obs.frontmostPID = app.processIdentifier
            obs.axTree = AXReader.snapshotTree(pid: app.processIdentifier)
        }

        if wantScreenshot {
            let image = try await Self.captureScreen()
            obs.screenshotPath = try await screenshotSink?(image)
        }
        return obs
    }

    public static func windowList() -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { w in
            guard let pid = w[kCGWindowOwnerPID as String] as? Int32,
                  let owner = w[kCGWindowOwnerName as String] as? String,
                  let boundsDict = w[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return WindowInfo(
                pid: pid, owner: owner,
                title: w[kCGWindowName as String] as? String,
                bounds: CGRectCodable(rect))
        }
    }

    /// One-shot capture via SCScreenshotManager (macOS 14+) — cheaper than
    /// running an SCStream for a stepwise agent loop.
    public static func captureScreen() async throws -> CGImage {
        let content = try await SCShareableContent.excludingDesktopWindows(
            false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw S1Error.screenshotFailed("no displays")
        }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = Int(display.frame.width)
        config.height = Int(display.frame.height)
        config.showsCursor = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }
}

/// Thin AXUIElement reader — builds the condensed AXNode tree. Depth- and
/// count-limited so a huge app can't stall the loop.
public enum AXReader {
    public static let maxNodes = 400
    public static let maxDepth = 8

    public static func snapshotTree(pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        var counter = 0
        return walk(app, depth: 0, counter: &counter)
    }

    static func walk(_ el: AXUIElement, depth: Int, counter: inout Int) -> AXNode? {
        guard depth < maxDepth, counter < maxNodes else { return nil }
        let ref = "e\(counter)"; counter += 1

        var node = AXNode(
            ref: ref,
            role: attr(el, kAXRoleAttribute) ?? "unknown",
            title: attr(el, kAXTitleAttribute),
            value: stringValue(el),
            frame: frame(of: el),
            children: [])

        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
           let arr = kids as? [AXUIElement] {
            node.children = arr.compactMap { walk($0, depth: depth + 1, counter: &counter) }
        }
        return node
    }

    static func attr(_ el: AXUIElement, _ name: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func stringValue(_ el: AXUIElement) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &v) == .success else { return nil }
        if let s = v as? String { return String(s.prefix(200)) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    static func frame(of el: AXUIElement) -> CGRectCodable? {
        var posV: CFTypeRef?
        var sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue(posV as! AXValue, .cgPoint, &p)
        AXValueGetValue(sizeV as! AXValue, .cgSize, &s)
        return CGRectCodable(CGRect(origin: p, size: s))
    }

    /// Re-resolve a ref inside a fresh snapshot of the same app, then perform
    /// a named AX action (AXPress, AXConfirm, ...) on the live element.
    public static func performAXAction(pid: pid_t, ref: String, action: String) -> Bool {
        guard let el = element(pid: pid, ref: ref) else { return false }
        return AXUIElementPerformAction(el, action as CFString) == .success
    }

    /// Set kAXValueAttribute on the element behind a ref.
    public static func setValue(pid: pid_t, ref: String, value: String) -> Bool {
        guard let el = element(pid: pid, ref: ref) else { return false }
        return AXUIElementSetAttributeValue(el, kAXValueAttribute as CFString, value as CFTypeRef) == .success
    }

    /// Live element lookup: walk the app's tree to the same walk-order index
    /// the ref encodes (refs are `e<n>` assigned in walk order).
    static func element(pid: pid_t, ref: String) -> AXUIElement? {
        guard ref.hasPrefix("e"), let target = Int(ref.dropFirst()) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var counter = 0
        var found: AXUIElement?
        findByIndex(app, target: target, counter: &counter, found: &found, depth: 0)
        return found
    }

    static func findByIndex(_ el: AXUIElement, target: Int, counter: inout Int, found: inout AXUIElement?, depth: Int) {
        guard found == nil, depth < maxDepth, counter < maxNodes else { return }
        if counter == target { found = el; return }
        counter += 1
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
              let arr = kids as? [AXUIElement] else { return }
        for k in arr { findByIndex(k, target: target, counter: &counter, found: &found, depth: depth + 1) }
    }
}
