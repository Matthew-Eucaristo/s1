import Foundation

/// What visibly changed between two observations: the evidence that a step
/// did something, appended to its outcome so the Judge and the Reasoner see
/// "→ new: “Chat 2”" or "→ no visible change" instead of trusting "pressed".
enum ScreenDiff {
    static func summary(_ before: Snapshot, _ after: Snapshot) -> String? {
        var parts: [String] = []
        if before.frontmostApp != after.frontmostApp, let app = after.frontmostApp {
            parts.append("now in \(app)")
        }
        let wb = Set(before.windows.compactMap(\.title).filter { !$0.isEmpty })
        let wa = after.windows.compactMap(\.title).filter { !$0.isEmpty }
        if let opened = wa.first(where: { !wb.contains($0) }) {
            parts.append("window “\(clip(opened))” opened")
        }
        let lb = labels(before.axTree), la = labels(after.axTree)
        let old = Set(lb.map(\.key)), new = Set(la.map(\.key))
        let added = la.filter { !old.contains($0.key) }
        let gone = lb.filter { !new.contains($0.key) }.count
        if !added.isEmpty {
            var s = "new: " + added.prefix(3).map { "“\($0.shown)”" }.joined(separator: ", ")
            if added.count > 3 { s += " +\(added.count - 3) more" }
            parts.append(s)
        }
        if gone > 0 { parts.append("\(gone) gone") }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }

    /// Labeled nodes in tree order: identity = role + label + value, so a
    /// field whose text changed counts as changed.
    static func labels(_ tree: AXNode?) -> [(key: String, shown: String)] {
        guard let tree else { return [] }
        var seen = Set<String>()
        var out: [(String, String)] = []
        for n in tree.flattened {
            let label = n.title ?? n.desc ?? ""
            let value = n.value ?? ""
            guard !label.isEmpty || !value.isEmpty else { continue }
            let key = "\(n.role)|\(label)|\(value)"
            if seen.insert(key).inserted {
                out.append((key, clip(label.isEmpty ? value : value.isEmpty ? label : "\(label): \(value)")))
            }
        }
        return out
    }

    private static func clip(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count <= 40 ? t : String(t.prefix(40)) + "…"
    }
}
