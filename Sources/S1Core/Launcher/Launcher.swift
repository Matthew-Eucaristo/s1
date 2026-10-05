import AppKit
import ApplicationServices
import Foundation

/// One row in the ⌥Space launcher.
public struct LauncherItem: Identifiable, Sendable, Equatable {
    public enum Kind: String, Sendable { case app, snippet, clip, calc, window, recent, ask, command, file, spotlight, web }
    public var kind: Kind
    public var title: String
    public var subtitle: String
    /// App path, snippet/clip text, calc result, layout raw value, or goal.
    public var payload: String
    public var id: String { "\(kind.rawValue):\(title):\(payload.prefix(80))" }

    public init(kind: Kind, title: String, subtitle: String = "", payload: String) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.payload = payload
    }
}

/// Raycast/Alfred-style search: apps, snippets, clipboard history, window
/// layouts, a calculator, recent goals — and "Ask s1" as the fallback that
/// hands anything else to the agent.
public enum Launcher {
    /// 1 = prefix, 0.9 = word prefix, 0.75 = substring, 0.45 = in-order
    /// subsequence ("vsc" → Visual Studio Code), 0 = no match.
    public static func score(_ query: String, _ text: String) -> Double {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        let t = text.lowercased()
        guard !q.isEmpty else { return 0 }
        if t.hasPrefix(q) { return 1 }
        if t.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(where: { $0.hasPrefix(q) }) { return 0.9 }
        if t.contains(q) { return 0.75 }
        var it = t.makeIterator()
        for c in q where c != " " {
            var found = false
            while let n = it.next() { if n == c { found = true; break } }
            if !found { return 0 }
        }
        return 0.45
    }

    public static func search(_ query: String, apps: [(name: String, path: String)],
                              snippets: [Snippet], clips: [String], recents: [String],
                              files: [String] = [], rates: FX.Rates? = nil,
                              limit: Int = 11) -> [LauncherItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if q.isEmpty {
            let base = Array((clips.prefix(4).map { clipItem($0) }
                + recents.prefix(4).map { LauncherItem(kind: .recent, title: $0, subtitle: "Recent command", payload: $0) })
                .prefix(limit))
            return base.isEmpty
                ? [LauncherItem(kind: .command, title: "Edit Snippets…", subtitle: "Type to search apps, snippets, clipboard, windows, math — or ask s1", payload: "editSnippets")]
                : base
        }
        var scored: [(Double, LauncherItem)] = []
        if let v = Calc.evaluate(q) {
            let s = Calc.format(v)
            scored.append((2, LauncherItem(kind: .calc, title: "= \(s)", subtitle: "Enter copies the result", payload: s)))
        }
        if let c = Convert.item(q, rates: rates) { scored.append((2, c)) }
        for f in files {
            let url = URL(fileURLWithPath: f)
            let dir = url.deletingLastPathComponent().path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            scored.append((max(score(q, url.lastPathComponent), 0.5) * 0.85,
                           LauncherItem(kind: .file, title: url.lastPathComponent, subtitle: dir, payload: f)))
        }
        for a in apps {
            let sc = score(q, a.name)
            if sc > 0 { scored.append((sc + 0.05, LauncherItem(kind: .app, title: a.name, subtitle: "Application", payload: a.path))) }
        }
        for l in WindowLayout.allCases {
            let sc = max(score(q, l.title), score(q, "window " + l.title))
            if sc >= 0.75 { scored.append((sc, LauncherItem(kind: .window, title: "Window: \(l.title)", subtitle: "Front window", payload: l.rawValue))) }
        }
        for s in snippets {
            let sc = max(score(q, s.keyword), score(q, s.text) * 0.8)
            if sc > 0.4 { scored.append((sc, LauncherItem(kind: .snippet, title: s.keyword, subtitle: String(s.text.prefix(60)), payload: s.text))) }
        }
        for c in clips where c.lowercased().contains(q.lowercased()) {
            scored.append((0.6, clipItem(c)))
        }
        for r in recents {
            let sc = score(q, r)
            if sc >= 0.75 { scored.append((sc * 0.7, LauncherItem(kind: .recent, title: r, subtitle: "Recent command", payload: r))) }
        }
        if score(q, "snippets") >= 0.9 || score(q, "edit snippets") >= 0.9 {
            scored.append((0.5, LauncherItem(kind: .command, title: "Edit Snippets…", subtitle: "~/.s1/snippets.json", payload: "editSnippets")))
        }
        // Stable sort: ties keep insertion order (calc, apps, windows, …).
        let top = scored.enumerated().sorted { a, b in
            a.element.0 != b.element.0 ? a.element.0 > b.element.0 : a.offset < b.offset
        }.map(\.element.1)
        var seen = Set<String>()
        let unique = top.filter { seen.insert($0.id).inserted }
        return Array(unique.prefix(limit - 3)) + [
            LauncherItem(kind: .ask, title: "Ask s1: \(q)", subtitle: "Run as a command", payload: q),
            LauncherItem(kind: .spotlight, title: "Search Spotlight for “\(q)”", subtitle: "Spotlight", payload: q),
            LauncherItem(kind: .web, title: "Search the web for “\(q)”", subtitle: "Default browser", payload: q),
        ]
    }

    static func clipItem(_ c: String) -> LauncherItem {
        let one = c.replacingOccurrences(of: "\n", with: " ⏎ ")
        return LauncherItem(kind: .clip, title: String(one.prefix(80)), subtitle: "Clipboard · \(c.count) chars", payload: c)
    }

    /// Installed apps from the standard dirs (same set STT vocabulary uses).
    public static func installedApps() -> [(name: String, path: String)] {
        var out: [(String, String)] = []
        var seen = Set<String>()
        for dir in InstalledApps.appDirs + ["/System/Applications/Utilities", "/Applications/Utilities"] {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                let stem = String(n.dropLast(4))
                if seen.insert(stem).inserted { out.append((stem, "\(dir)/\(n)")) }
            }
        }
        return out.sorted { $0.0 < $1.0 }
    }
}

// MARK: - Snippets

public struct Snippet: Codable, Sendable, Equatable {
    public var keyword: String
    public var text: String
    public init(keyword: String, text: String) { self.keyword = keyword; self.text = text }
}

public enum Snippets {
    public static var path: URL { URL(fileURLWithPath: S1Home.path + "/snippets.json") }

    /// Ready out of the box; the file (once saved) replaces them entirely.
    public static let defaults: [Snippet] = [
        Snippet(keyword: "today", text: "{date}"),
        Snippet(keyword: "now", text: "{datetime}"),
        Snippet(keyword: "time", text: "{time}"),
        Snippet(keyword: "isodate", text: "{isodate}"),
        Snippet(keyword: "sig", text: "Best regards,\n{name}"),
        Snippet(keyword: "thanks", text: "Thanks so much! Let me know if you have any questions."),
        Snippet(keyword: "ty", text: "Thank you!"),
        Snippet(keyword: "omw", text: "On my way!"),
        Snippet(keyword: "brb", text: "Be right back."),
        Snippet(keyword: "call", text: "Are you free for a quick call this week? A few times that work for me:\n- \n- "),
        Snippet(keyword: "followup", text: "Hi! Just following up on my previous message. Any update when you have a moment?"),
        Snippet(keyword: "lgtm", text: "Looks good to me, thanks!"),
        Snippet(keyword: "quote", text: "> {clipboard}"),
        Snippet(keyword: "codeblock", text: "```\n{clipboard}\n```"),
        Snippet(keyword: "uuid", text: "{uuid}"),
        Snippet(keyword: "shrug", text: "¯\\_(ツ)_/¯"),
        Snippet(keyword: "terimakasih", text: "Terima kasih banyak!"),
        Snippet(keyword: "salam", text: "Salam,\n{name}"),
    ]

    public static func load() -> [Snippet] {
        guard let d = try? Data(contentsOf: path) else { return defaults }
        return (try? JSONDecoder().decode([Snippet].self, from: d)) ?? defaults
    }

    public static func save(_ snippets: [Snippet]) throws {
        S1Home.ensurePrivate()
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(snippets.filter { !$0.keyword.trimmingCharacters(in: .whitespaces).isEmpty })
            .write(to: path, options: .atomic)
    }

    /// Writes the defaults so "Edit Snippets…" opens something useful.
    public static func ensureFile() {
        guard !FileManager.default.fileExists(atPath: path.path) else { return }
        try? save(defaults)
    }

    /// `{date}`, `{time}`, `{datetime}`, `{isodate}`, `{weekday}`, `{name}`,
    /// `{uuid}`, `{clipboard}` placeholders.
    public static func expand(_ text: String, now: Date = Date(), clipboard: String? = nil) -> String {
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .none
        let tf = DateFormatter(); tf.dateStyle = .none; tf.timeStyle = .short
        let wf = DateFormatter(); wf.dateFormat = "EEEE"
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withFullDate]
        return text
            .replacingOccurrences(of: "{datetime}", with: df.string(from: now) + " " + tf.string(from: now))
            .replacingOccurrences(of: "{isodate}", with: iso.string(from: now))
            .replacingOccurrences(of: "{date}", with: df.string(from: now))
            .replacingOccurrences(of: "{time}", with: tf.string(from: now))
            .replacingOccurrences(of: "{weekday}", with: wf.string(from: now))
            .replacingOccurrences(of: "{name}", with: NSFullUserName())
            .replacingOccurrences(of: "{uuid}", with: UUID().uuidString.lowercased())
            .replacingOccurrences(of: "{clipboard}", with: clipboard ?? "")
    }
}

// MARK: - Clipboard

public enum ClipboardPolicy {
    /// nspasteboard.org markers password managers set — never record those.
    static let privateTypes: Set<String> = ["org.nspasteboard.ConcealedType", "org.nspasteboard.TransientType",
                                            "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword"]

    public static func shouldRecord(types: [String], text: String?) -> Bool {
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.count <= 20_000 else { return false }
        return privateTypes.isDisjoint(with: types)
    }
}

// MARK: - Calculator

/// `2+3*4`, `(1.5+2)^2`, `15% * 80`. A tiny recursive-descent parser —
/// NSExpression raises uncatchable ObjC exceptions on bad input.
public enum Calc {
    public static func evaluate(_ s: String) -> Double? {
        let src = s.replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: ",", with: "")
        guard src.contains(where: { "+-*/^%".contains($0) }), src.contains(where: \.isNumber),
              src.allSatisfy({ "0123456789.+-*/^%() ".contains($0) }) else { return nil }
        var p = Parser(chars: Array(src.filter { $0 != " " }))
        guard let v = p.expr(), p.i == p.chars.count, v.isFinite else { return nil }
        return v
    }

    public static func format(_ v: Double) -> String {
        if v == v.rounded(), abs(v) < 1e15 { return String(Int64(v)) }
        return String(format: "%.10g", v)
    }

    struct Parser {
        let chars: [Character]; var i = 0
        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }
        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1; guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }
        mutating func term() -> Double? {
            guard var v = power() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1; guard let r = power() else { return nil }
                v = c == "*" ? v * r : v / r
            }
            return v
        }
        mutating func power() -> Double? {
            guard let b = unary() else { return nil }
            if peek() == "^" { i += 1; guard let e = power() else { return nil }; return pow(b, e) }
            return b
        }
        mutating func unary() -> Double? {
            if peek() == "-" { i += 1; return unary().map { -$0 } }
            if peek() == "+" { i += 1; return unary() }
            guard var v = atom() else { return nil }
            if peek() == "%" { i += 1; v /= 100 }
            return v
        }
        mutating func atom() -> Double? {
            if peek() == "(" {
                i += 1; guard let v = expr(), peek() == ")" else { return nil }
                i += 1; return v
            }
            let start = i
            while let c = peek(), c.isNumber || c == "." { i += 1 }
            return i > start ? Double(String(chars[start..<i])) : nil
        }
    }
}

// MARK: - Window management

public enum WindowLayout: String, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center

    public var title: String {
        switch self {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .maximize: "Maximize"
        case .center: "Center"
        }
    }

    /// Target frame inside `visible` (top-left-origin coordinates, like AX).
    public func frame(in v: CGRect, current: CGSize) -> CGRect {
        switch self {
        case .leftHalf: CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
        case .rightHalf: CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
        case .topHalf: CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height / 2)
        case .bottomHalf: CGRect(x: v.minX, y: v.midY, width: v.width, height: v.height / 2)
        case .maximize: v
        case .center:
            CGRect(x: v.midX - min(current.width, v.width) / 2, y: v.midY - min(current.height, v.height) / 2,
                   width: min(current.width, v.width), height: min(current.height, v.height))
        }
    }
}

public enum WindowOps {
    /// Move/resize the focused window of `pid` via Accessibility.
    @MainActor
    public static func apply(_ layout: WindowLayout, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        var w: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &w) == .success,
              let win = w, CFGetTypeID(win) == AXUIElementGetTypeID() else { return false }
        let window = win as! AXUIElement
        var sizeV: CFTypeRef?; var cur = CGSize(width: 800, height: 600)
        if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeV) == .success,
           let sv = sizeV, CFGetTypeID(sv) == AXValueGetTypeID() {
            AXValueGetValue(sv as! AXValue, .cgSize, &cur)
        }
        guard let screen = NSScreen.main, let primary = NSScreen.screens.first else { return false }
        // Cocoa (bottom-left) → AX (top-left of the primary display).
        let vf = screen.visibleFrame
        let visible = CGRect(x: vf.minX, y: primary.frame.height - vf.maxY, width: vf.width, height: vf.height)
        let f = layout.frame(in: visible, current: cur)
        var origin = f.origin, size = f.size
        guard let pos = AXValueCreate(.cgPoint, &origin), let sz = AXValueCreate(.cgSize, &size) else { return false }
        // Size, move, size again: some apps clamp size against the old position.
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        let ok = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, pos) == .success
        AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sz)
        return ok
    }
}
