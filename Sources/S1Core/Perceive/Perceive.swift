import Synchronization
import Foundation
import AppKit
import ScreenCaptureKit
import ApplicationServices

public protocol Perceiver: Sendable {
    func observe(wantScreenshot: Bool) async throws -> Snapshot
}

extension Perceiver {
    /// A screenshot when one can be taken, else the accessibility view alone.
    /// Models that see are a bonus: a missing Screen Recording grant must
    /// never stop a command the AX tree can handle.
    public func observe(preferScreenshot: Bool) async throws -> Snapshot {
        guard preferScreenshot else { return try await observe(wantScreenshot: false) }
        do { return try await observe(wantScreenshot: true) }
        catch { return try await observe(wantScreenshot: false) }
    }
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
        // AX + frontmost reads run on the main actor on purpose: HIServices
        // asserts ("Block was expected to execute on queue com.apple.main-
        // thread") when the AX connection's first contact happens on a
        // cooperative-pool thread — which is exactly where a MenuBarExtra
        // action's Task resumes. Window-list/SCK don't share that rule.
        struct OnMain: Sendable {
            var windows: [WindowInfo]
            var appName: String?
            var appPID: pid_t?
            var secure: Bool
            var tree: AXNode?
            var menus: [MenuCommand] = []
        }
        let m = await MainActor.run { () -> OnMain in
            var o = OnMain(windows: Self.windowList(), appName: nil, appPID: nil,
                           secure: false, tree: nil)
            if let app = NSWorkspace.shared.frontmostApplication {
                o.appName = app.localizedName
                o.appPID = app.processIdentifier
                o.secure = AXReader.focusedElementIsSecure(pid: app.processIdentifier)
                if let tree = AXReader.snapshotTree(pid: app.processIdentifier) {
                    o.tree = tree
                }
                o.menus = MenuReader.commands(pid: app.processIdentifier)
            }
            return o
        }
        var obs = Snapshot(
            timestamp: Date(),
            frontmostApp: m.appName, frontmostPID: m.appPID,
            windows: m.windows,
            axTree: m.tree, screenshotPath: nil)
        obs.secureTextFocused = m.secure
        obs.menus = m.menus
        if let tree = m.tree, let pid = m.appPID {
            AXReader.noteTree(tree, pid: pid)
        }

        obs.appStates = Self.appStates(windows: obs.windows, frontmostPID: obs.frontmostPID)

        // No sink → nothing can consume the image, so skip the capture
        // entirely rather than burning a SCK round-trip for a discarded bitmap.
        if wantScreenshot, let screenshotSink {
            let image = try await Self.captureScreen()
            obs.screenshotPath = try await screenshotSink(image)
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
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
        } catch let e as SCStreamError where e.code == .userDeclined {
            throw S1Error.screenshotFailed(
                "Screen Recording isn't on for s1. Turn it on in System Settings → Privacy & Security, then reopen s1 (macOS applies it at launch).")
        }
        guard !content.displays.isEmpty else {
            throw S1Error.screenshotFailed("no displays")
        }
        // Multi-monitor: the agent acts where the user looks — capture the
        // display holding the main (key-window) screen, not blindly the
        // first display ScreenCaptureKit happens to enumerate.
        let mainID = (NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        let display = content.displays.first(where: { $0.displayID == mainID })
            ?? content.displays[0]
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
    public static let maxNodes = 500
    /// Counted in kept nodes: unlabeled wrapper groups don't use it up, so
    /// a web page 10+ raw levels inside Chrome is still reached.
    public static let maxDepth = 12
    /// Hard stop on raw nesting (wrappers included) against cyclic trees.
    static let maxRawDepth = 48

    /// Bound every AX round-trip so a wedged or unresponsive app can't
    /// stall the loop indefinitely: a healthy app answers in single-digit
    /// milliseconds, so ~1.5s only ever trips on real hangs. Elements
    /// obtained through a timed root inherit the bound, so one call per
    /// root covers the whole walk.
    public static let messagingTimeout: Float = 1.5
    static func bindTimeout(_ el: AXUIElement) {
        AXUIElementSetMessagingTimeout(el, messagingTimeout)
    }

    public static func snapshotTree(pid: pid_t) -> AXNode? {
        let app = AXUIElementCreateApplication(pid)
        bindTimeout(app)
        let entries = visit(app)
        guard !entries.isEmpty else { return nil }
        // Rebuild the tree bottom-up from the pre-order list; the ref is the
        // pre-order index, so `flattened[i].ref == "e\(i)"`.
        var nodes = entries.enumerated().map { i, e in
            AXNode(ref: "e\(i)", role: e.role, title: e.title, desc: e.desc, help: e.help,
                   value: e.value, frame: e.frame.map(CGRectCodable.init), children: [])
        }
        for i in entries.indices.reversed() {
            if let p = entries[i].parent { nodes[p].children.insert(nodes[i], at: 0) }
        }
        return nodes[0]
    }

    /// One kept element of the walk, in pre-order.
    struct Entry {
        var el: AXUIElement
        var parent: Int?
        var role: String, title: String?, desc: String?, help: String?, value: String?
        var frame: CGRect?
    }

    /// The single traversal behind snapshots AND ref re-resolution (refs
    /// are its pre-order indices, so both must walk identically):
    /// - the focused window comes first, then other windows, the menu bar last;
    /// - closed menus aren't opened up (hundreds of items nobody sees);
    /// - unlabeled wrapper groups are skipped, their children kept, so deep
    ///   web pages (Chrome, Electron) fit the depth and node budget;
    /// - content scrolled outside its window is left out.
    static func visit(_ app: AXUIElement) -> [Entry] {
        var out: [Entry] = []
        func add(_ el: AXUIElement, parent: Int?, depth: Int, raw: Int, clip: CGRect?) {
            guard out.count < maxNodes, depth < maxDepth, raw < maxRawDepth else { return }
            let a = nodeAttrs(el)
            var clip = clip
            if a.role == "AXWindow" { clip = a.frame }
            if let c = clip, let f = a.frame, f.width > 0, f.height > 0, !f.intersects(c) { return }
            let labeled = [a.title, a.desc, a.help, a.value].contains { !($0 ?? "").isEmpty }
            let wrapper = !labeled && parent != nil && ["AXGroup", "AXUnknown", "AXSplitGroup"].contains(a.role)
            var me = parent
            if !wrapper {
                out.append(Entry(el: el, parent: parent, role: a.role, title: a.title, desc: a.desc,
                                 help: a.help, value: a.value, frame: a.frame))
                me = out.count - 1
            }
            // A closed menu's items are noise; an open one (selected title) is the UI.
            if a.role == "AXMenuBarItem", copyBool(el, kAXSelectedAttribute) != true { return }
            for k in children(of: el, role: a.role) {
                add(k, parent: me, depth: wrapper ? depth : depth + 1, raw: raw + 1, clip: clip)
            }
        }
        add(app, parent: nil, depth: 0, raw: 0, clip: nil)
        return out
    }

    private static func children(of el: AXUIElement, role: String) -> [AXUIElement] {
        var kids: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success,
              var arr = kids as? [AXUIElement] else { return [] }
        guard role == "AXApplication" else { return arr }
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let f = focused, CFGetTypeID(f) == AXUIElementGetTypeID(),
           let i = arr.firstIndex(where: { CFEqual($0, f) }) {
            arr.insert(arr.remove(at: i), at: 0)
        }
        // Menu bar last: the window is what the user is looking at.
        if let i = arr.firstIndex(where: { attr($0, kAXRoleAttribute) == "AXMenuBar" }) {
            arr.append(arr.remove(at: i))
        }
        return arr
    }

    private static func copyBool(_ el: AXUIElement, _ name: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return (v as? Bool) ?? (v as? NSNumber)?.boolValue
    }

    /// All scalar attributes fetched in ONE IPC round-trip per node via
    /// AXUIElementCopyMultipleAttributeValues — ~7 separate AX calls become 2
    /// (attrs + children), cutting observe latency roughly in half on wide trees.
    private static func scalarAttrs() -> CFArray {
        [kAXRoleAttribute, kAXTitleAttribute, kAXDescriptionAttribute,
         kAXHelpAttribute, kAXValueAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
    }

    /// One node's scalar reads in a single IPC round-trip, with the
    /// per-attribute fallback for apps that fail the multi-copy.
    /// Shared by `walk` (observation trees) and `collect` (re-resolve walks)
    /// so the act path gets the same batching win as the observe path.
    private static func nodeAttrs(_ el: AXUIElement)
        -> (role: String, title: String?, desc: String?, help: String?,
            value: String?, frame: CGRect?) {
        var role = "unknown", title: String?, desc: String?, help: String?,
            value: String?, frame: CGRect? = nil
        var vals: CFArray?
        if AXUIElementCopyMultipleAttributeValues(el, scalarAttrs(),
                                                  AXCopyMultipleAttributeOptions(rawValue: 0),
                                                  &vals) == .success,
           let arr = vals as? [Any], arr.count == 7 {
            role = arr[0] as? String ?? role
            title = arr[1] as? String
            desc = arr[2] as? String
            help = arr[3] as? String
            value = stringifyValue(arr[4])
            frame = extractFrame(pos: arr[5], size: arr[6])
        } else {
            // Older apps can fail the multi-copy — per-attr fallback keeps
            // them observable rather than invisible.
            role = attr(el, kAXRoleAttribute) ?? role
            title = attr(el, kAXTitleAttribute)
            desc = attr(el, kAXDescriptionAttribute)
            help = attr(el, kAXHelpAttribute)
            value = stringValue(el)
            frame = liveFrame(of: el)
        }
        // A secure field's value is a credential-in-progress: never read it
        // at all — not into the snapshot, the step log, or a model prompt.
        // (Some hosts expose the raw text via AXValue despite the role.)
        if role == "AXSecureTextField" { value = nil }
        return (role, title, desc, help, value, frame)
    }

    /// kAXValueAttribute can be a String, NSNumber, AXValue, or garbage —
    /// render the common cases, nil the rest (never force-cast).
    static func stringifyValue(_ v: Any) -> String? {
        if let s = v as? String { return String(s.prefix(200)) }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    /// Position+size arrive as AXValue wrappers (or missing markers on
    /// elements that vend neither) — decode only the real thing.
    static func extractFrame(pos: Any, size: Any) -> CGRect? {
        guard let p = pos as CFTypeRef?, CFGetTypeID(p) == AXValueGetTypeID(),
              let s = size as CFTypeRef?, CFGetTypeID(s) == AXValueGetTypeID()
        else { return nil }
        var point = CGPoint.zero, sz = CGSize.zero
        // The type IDs matched AXValue, but a hostile process could still
        // vendor a value whose inner type isn't CGPoint/CGSize — the getter
        // returns false rather than crash; honour it.
        guard AXValueGetValue((p as! AXValue), .cgPoint, &point),
              AXValueGetValue((s as! AXValue), .cgSize, &sz)
        else { return nil }
        return CGRect(origin: point, size: sz)
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
        guard AXValueGetValue((pv as! AXValue), .cgPoint, &p),
              AXValueGetValue((sv as! AXValue), .cgSize, &s)
        else { return nil }
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
    private final class TreeStore: Sendable {
        private let map = Mutex<[pid_t: AXNode]>([:])
        /// Bounded: long-running companions would otherwise accumulate
        /// trees for apps that quit hours ago.
        func set(_ t: AXNode, pid: pid_t) {
            map.withLock { m in
                if m.count >= 16, m[pid] == nil { m.removeAll(keepingCapacity: true) }
                m[pid] = t
            }
        }
        func get(_ pid: pid_t) -> AXNode? { map.withLock { $0[pid] } }
    }
    static func noteTree(_ tree: AXNode, pid: pid_t) { treeStore.set(tree, pid: pid) }

    /// Whether the app's keyboard focus sits in an AXSecureTextField —
    /// the voice-typing path must never fill a password box.
    public static func focusedElementIsSecure(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        bindTimeout(app)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let el = v, CFGetTypeID(el) == AXUIElementGetTypeID()
        else { return false }
        let role = attr(el as! AXUIElement, kAXRoleAttribute)
        return role == "AXSecureTextField"
    }

    /// Live element lookup behind a ref (`e<n>` = walk-order index in the
    /// snapshot the policy saw). UI mutations between observe and act shift
    /// indices, so when the fresh node at that index doesn't match the
    /// recorded identity we search for the node that does.
    static func element(pid: pid_t, ref: String) -> AXUIElement? {
        guard ref.hasPrefix("e"), let target = Int(ref.dropFirst()) else { return nil }
        let app = AXUIElementCreateApplication(pid)
        bindTimeout(app)
        // One walk that keeps (element, role, title, desc, help, frame) per
        // node — help joins identity so tooltip-named controls re-resolve
        // on drift instead of trusting a stale index.
        let entries = visit(app)

        let orig = treeStore.get(pid)?.flattened
        let o = orig.flatMap { target < $0.count ? $0[target] : nil }
        let candidate = target < entries.count ? entries[target] : nil
        guard let o else { return candidate?.el }   // no baseline: trust the index

        // Same role and same labels → the ref still points at the same widget.
        if let candidate,
           o.role == candidate.role,
           (o.title ?? "") == (candidate.title ?? ""),
           (o.desc ?? "") == (candidate.desc ?? ""),
           (o.help ?? "") == (candidate.help ?? "") {
            return candidate.el
        }
        // Index drifted — or the tree shrank past the ref (a dialog closed
        // and rebuilt its tree shorter). Find the recorded node by identity
        // instead of giving up at the bounds check.
        var best: (AXUIElement, Double)?
        for e in entries {
            guard e.role == o.role else { continue }
            let oLabel = (o.title?.isEmpty == false ? o.title
                          : o.desc?.isEmpty == false ? o.desc : o.help)
            if let ot = oLabel, !ot.isEmpty {
                if e.title == ot || e.desc == ot || e.help == ot { return e.el }
                continue
            }
            if let of = o.frame, let ef = e.frame {
                let d = hypot(ef.midX - (of.x + of.w / 2), ef.midY - (of.y + of.h / 2))
                if d < 24, d < (best?.1 ?? .infinity) { best = (e.el, d) }
            }
        }
        // The recorded node is gone and nothing nearby matches — the element
        // now sitting at the stale index is a DIFFERENT control. Failing the
        // action beats pressing a wrong (possibly destructive) target.
        return best?.0
    }
}
