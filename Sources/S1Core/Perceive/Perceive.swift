import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

public protocol Perceiver: Sendable {
    func observe(wantScreenshot: Bool) async throws -> Snapshot
}

/// Canned perception for tests — never touches the OS.
public struct NullPerceiver: Perceiver {
    public var observation: Snapshot
    public init(observation: Snapshot? = nil) {
        self.observation = observation ?? Snapshot(
            timestamp: Date(), frontmostApp: "TestApp", frontmostPID: 1,
            windows: [], axTree: nil, screenshotPath: nil)
    }
    public func observe(wantScreenshot: Bool) async throws -> Snapshot { observation }
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

    public func observe(wantScreenshot: Bool) async throws -> Snapshot {
        var obs = Snapshot(
            timestamp: Date(),
            frontmostApp: nil, frontmostPID: nil,
            windows: Self.windowList(),
            axTree: nil, screenshotPath: nil)

        if let app = NSWorkspace.shared.frontmostApplication {
            obs.frontmostApp = app.localizedName
            obs.frontmostPID = app.processIdentifier
            if let tree = AXReader.snapshotTree(pid: app.processIdentifier) {
                obs.axTree = tree
                AXReader.noteTree(tree, pid: app.processIdentifier)
            }
        }

        obs.appStates = Self.appStates(windows: obs.windows, frontmostPID: obs.frontmostPID)

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

    /// Surface state of every running GUI app — the agent's "what's on this
    /// Mac" view, joined from NSWorkspace + the window list. Cheap: no AX
    /// trees here (the frontmost app's tree is already captured separately).
    public static func appStates(windows: [WindowInfo], frontmostPID: pid_t?,
                                 maxApps: Int = 20, maxTitlesPerApp: Int = 4) -> [AppState] {
        let apps: [(name: String, pid: Int32)] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .map { ($0.localizedName ?? "?", $0.processIdentifier) }
        return joinAppStates(apps: apps, windows: windows, frontmostPID: frontmostPID,
                             maxApps: maxApps, maxTitlesPerApp: maxTitlesPerApp)
    }

    /// The join, decoupled from NSWorkspace so tests can feed fixtures.
    static func joinAppStates(apps: [(name: String, pid: Int32)], windows: [WindowInfo],
                              frontmostPID: pid_t?, maxApps: Int, maxTitlesPerApp: Int) -> [AppState] {
        var titles: [Int32: [String]] = [:]
        for w in windows {
            if let t = w.title, !t.isEmpty, titles[w.pid, default: []].count < maxTitlesPerApp {
                titles[w.pid, default: []].append(t)
            }
        }
        var states = apps.map { a in
            AppState(name: a.name, pid: a.pid,
                     isActive: a.pid == frontmostPID,
                     windowTitles: titles[a.pid] ?? [])
        }
        states.sort { $0.isActive && !$1.isActive || ($0.isActive == $1.isActive && $0.name < $1.name) }
        return Array(states.prefix(maxApps))
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
        // Filter rect is in points; the config wants pixels — multiply by the
        // display's pixel scale (Apple's own sample pattern) or Retina shots
        // come out half-res.
        let scale = CGFloat(filter.pointPixelScale)
        config.width = Int(filter.contentRect.width * scale)
        config.height = Int(filter.contentRect.height * scale)
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
            desc: attr(el, kAXDescriptionAttribute),
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
        guard let r = liveFrame(of: el) else { return nil }
        return CGRectCodable(r)
    }

    /// AX position+size of a live element — nil whenever either attribute is
    /// missing or not an AXValue (some apps vend odd types; never force-cast).
    static func liveFrame(of el: AXUIElement) -> CGRect? {
        var posV: CFTypeRef?
        var sizeV: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &posV) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sizeV) == .success,
              let pv = posV, let sv = sizeV,
              CFGetTypeID(pv) == AXValueGetTypeID(), CFGetTypeID(sv) == AXValueGetTypeID()
        else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        AXValueGetValue((pv as! AXValue), .cgPoint, &p)
        AXValueGetValue((sv as! AXValue), .cgSize, &s)
        return CGRect(origin: p, size: s)
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

    /// Generic attribute write on a live element (e.g. AXFocused).
    public static func setAttribute(pid: pid_t, ref: String, attr: String, value: CFTypeRef) -> Bool {
        guard let el = element(pid: pid, ref: ref) else { return false }
        return AXUIElementSetAttributeValue(el, attr as CFString, value) == .success
    }

    /// Screen frame of the live element behind a ref (for click fallbacks).
    public static func frameOf(pid: pid_t, ref: String) -> CGRect? {
        guard let el = element(pid: pid, ref: ref) else { return nil }
        return liveFrame(of: el)
    }

    /// The most recently observed data-tree per app — used by `element` to
    /// detect index drift when the UI changed between decide and act.
    private static let treeStore = TreeStore()
    private final class TreeStore: @unchecked Sendable {
        private let lock = NSLock()
        private var map: [pid_t: AXNode] = [:]
        func set(_ t: AXNode, pid: pid_t) { lock.lock(); map[pid] = t; lock.unlock() }
        func get(_ pid: pid_t) -> AXNode? { lock.lock(); defer { lock.unlock() }; return map[pid] }
    }
    static func noteTree(_ tree: AXNode, pid: pid_t) { treeStore.set(tree, pid: pid) }

    /// Live element lookup behind a ref (`e<n>` = walk-order index in the
    /// snapshot the policy saw). UI mutations between observe and act shift
    /// indices, so when the fresh node at that index doesn't match the
    /// recorded identity we search for the node that does.
    static func element(pid: pid_t, ref: String) -> AXUIElement? {
        guard ref.hasPrefix("e"), let target = Int(ref.dropFirst()) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        // One walk that keeps (element, role, title, frame) per node.
        var entries: [(el: AXUIElement, role: String, title: String?, frame: CGRect?)] = []
        var counter = 0
        collect(app, counter: &counter, depth: 0, into: &entries)
        guard target < entries.count else { return nil }

        let candidate = entries[target]
        let orig = treeStore.get(pid)?.flattened
        guard let origNode = orig, target < origNode.count else { return candidate.el }
        let o = origNode[target]
        // Same role and same title → the ref still points at the same widget.
        if o.role == candidate.role, (o.title ?? "") == (candidate.title ?? "") {
            return candidate.el
        }
        // Index drifted — find the recorded node by identity instead.
        var best: (AXUIElement, Double)?
        for e in entries {
            guard e.role == o.role else { continue }
            if let ot = o.title, !ot.isEmpty {
                if e.title == ot { return e.el }
                continue
            }
            if let of = o.frame, let ef = e.frame {
                let d = hypot(ef.midX - (of.x + of.w / 2), ef.midY - (of.y + of.h / 2))
                if d < 24, d < (best?.1 ?? .infinity) { best = (e.el, d) }
            }
        }
        return best?.0 ?? candidate.el   // worst case: trust the index
    }

    static func collect(_ el: AXUIElement, counter: inout Int, depth: Int,
                        into entries: inout [(el: AXUIElement, role: String, title: String?, frame: CGRect?)]) {
        guard depth < maxDepth, counter < maxNodes else { return }
        counter += 1
        entries.append((el, attr(el, kAXRoleAttribute) ?? "unknown",
                        attr(el, kAXTitleAttribute), liveFrame(of: el)))
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
              let arr = kids as? [AXUIElement] else { return }
        for k in arr { collect(k, counter: &counter, depth: depth + 1, into: &entries) }
    }
}
