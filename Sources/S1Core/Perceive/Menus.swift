import ApplicationServices
import Foundation
import Synchronization

/// One command from an app's menu bar: the app's own list of everything it
/// can do, named by the app ("Controls › Next", "File › New Chat").
public struct MenuCommand: Codable, Sendable, Equatable {
    /// Menu titles from the menu bar down: ["Controls", "Next"].
    public var path: [String]
    /// "⌘N", "⇧⌘S" — nil when the item has no shortcut.
    public var shortcut: String?
    public var enabled: Bool

    public init(path: [String], shortcut: String? = nil, enabled: Bool = true) {
        self.path = path; self.shortcut = shortcut; self.enabled = enabled
    }

    public var title: String { path.last ?? "" }
    /// "File › New Chat ⌘N"
    public var label: String { path.joined(separator: " › ") + (shortcut.map { " " + $0 } ?? "") }
}

/// Reads the frontmost app's menu bar — without opening any menu — and
/// presses items by path. Menus barely change while an app runs, so each
/// app's list is cached for a short while; the enabled flags are re-read
/// when an item is pressed.
public enum MenuReader {
    static let maxItems = 300
    static let ttl: TimeInterval = 30
    private static let cache = Mutex<[pid_t: (at: Date, items: [MenuCommand])]>([:])

    /// The app's commands (Apple menu skipped), cached per pid.
    public static func commands(pid: pid_t, now: Date = Date()) -> [MenuCommand] {
        if let hit = cache.withLock({ $0[pid] }), now.timeIntervalSince(hit.at) < ttl { return hit.items }
        let items = read(pid: pid)
        cache.withLock { c in
            if c.count > 16 { c.removeAll() }
            c[pid] = (now, items)
        }
        return items
    }

    static func read(pid: pid_t) -> [MenuCommand] {
        let app = AXUIElementCreateApplication(pid)
        AXReader.bindTimeout(app)
        guard let bar: AXUIElement = copy(app, kAXMenuBarAttribute) else { return [] }
        var out: [MenuCommand] = []
        for top in children(bar).dropFirst() {          // the Apple menu isn't the app's
            guard let name = string(top, kAXTitleAttribute), !name.isEmpty else { continue }
            for menu in children(top) { collect(menu, path: [name], depth: 0, into: &out) }
            if out.count >= maxItems { break }
        }
        return out
    }

    private static func collect(_ menu: AXUIElement, path: [String], depth: Int, into out: inout [MenuCommand]) {
        for item in children(menu) {
            guard out.count < maxItems,
                  let title = string(item, kAXTitleAttribute)?.trimmingCharacters(in: .whitespaces),
                  !title.isEmpty else { continue }   // separators have no title
            let submenu = children(item).first
            // Services is the system's, not the app's — and dozens of items.
            if submenu != nil, title == "Services" { continue }
            if let submenu, depth < 1 {
                collect(submenu, path: path + [title], depth: depth + 1, into: &out)
                continue
            }
            let enabled = (copy(item, kAXEnabledAttribute) as Bool?) ?? true
            out.append(MenuCommand(path: path + [title], shortcut: shortcut(item), enabled: enabled))
        }
    }

    /// "⇧⌘N" from the item's command character and modifier mask
    /// (bit 0 shift, 1 option, 2 control, 3 = no ⌘).
    static func shortcut(_ item: AXUIElement) -> String? {
        guard let raw = string(item, kAXMenuItemCmdCharAttribute), let scalar = raw.unicodeScalars.first,
              let char = keyName(scalar) else { return nil }
        let mods = (copy(item, kAXMenuItemCmdModifiersAttribute) as NSNumber?)?.intValue ?? 0
        return format(char: char, modifiers: mods)
    }

    /// Function-key private-use characters (NSUpArrowFunctionKey …) and
    /// space get names; other control characters mean no shortcut.
    static func keyName(_ c: Unicode.Scalar) -> String? {
        switch c.value {
        case 0xF700: return "↑"
        case 0xF701: return "↓"
        case 0xF702: return "←"
        case 0xF703: return "→"
        case 0x20: return "Space"
        case 0x0D, 0x03: return "↩"
        case 0x1B: return "⎋"
        case 0x08, 0x7F: return "⌫"
        case 0xF704...0xF70F: return "F\(c.value - 0xF703)"
        case 0..<0x20, 0xE000...0xF8FF: return nil
        default: return String(c)
        }
    }

    static func format(char: String, modifiers mods: Int) -> String {
        var s = ""
        if mods & 4 != 0 { s += "⌃" }
        if mods & 2 != 0 { s += "⌥" }
        if mods & 1 != 0 { s += "⇧" }
        if mods & 8 == 0 { s += "⌘" }
        return s + (char.count == 1 ? char.uppercased() : char)
    }

    /// "File > New Chat" / "File › New Chat" → ["File", "New Chat"].
    public static func path(_ s: String) -> [String] {
        s.components(separatedBy: CharacterSet(charactersIn: ">›"))
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// A full path for what a model or the grammar named: the exact path, or
    /// just the item's title ("New Chat"), or a tail of it ("Shuffle › On").
    static func resolve(_ path: [String], in items: [MenuCommand]) -> [String]? {
        let want = path.map(normalize)
        if let hit = items.first(where: { $0.path.map(normalize) == want }) { return hit.path }
        return items.first { $0.path.count >= want.count && Array($0.path.suffix(want.count)).map(normalize) == want }?.path
    }

    /// Press the item at `path` (or the one it names) in the frontmost app's menu bar.
    public static func press(path asked: [String], pid: pid_t) throws -> String {
        let path = resolve(asked, in: commands(pid: pid)) ?? asked
        let app = AXUIElementCreateApplication(pid)
        AXReader.bindTimeout(app)
        guard let bar: AXUIElement = copy(app, kAXMenuBarAttribute) else {
            throw S1Error.axFailed("this app has no menu bar s1 can read")
        }
        var level = children(bar)
        var found: AXUIElement?
        for (i, name) in path.enumerated() {
            guard let hit = level.first(where: { same(string($0, kAXTitleAttribute), name) }) else {
                throw S1Error.axFailed("no menu item “\(path.prefix(i + 1).joined(separator: " › "))”")
            }
            found = hit
            // Menu bar item / submenu item → its menu → that menu's items.
            level = children(hit).first.map(children) ?? []
        }
        guard let item = found else { throw S1Error.axFailed("empty menu path") }
        if (copy(item, kAXEnabledAttribute) as Bool?) == false {
            throw S1Error.axFailed("“\(path.joined(separator: " › "))” is greyed out right now")
        }
        let err = AXUIElementPerformAction(item, kAXPressAction as CFString)
        guard err == .success else {
            throw S1Error.axFailed("couldn't choose “\(path.joined(separator: " › "))” (AX \(err.rawValue))")
        }
        cache.withLock { _ = $0.removeValue(forKey: pid) }   // state may have changed
        return "chose \(path.joined(separator: " › "))"
    }

    /// Menu titles compare without case or a trailing ellipsis ("Settings…").
    static func same(_ a: String?, _ b: String) -> Bool {
        guard let a else { return false }
        return normalize(a) == normalize(b)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func children(_ el: AXUIElement) -> [AXUIElement] {
        (copy(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? { copy(el, name) }

    private static func copy<T>(_ el: AXUIElement, _ name: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success else { return nil }
        return v as? T
    }
}
