import Foundation

/// Coarse-to-fine search for a control the user named but the grammar
/// couldn't match ("click the first step", "the type that I have").
///
/// One small `choice` per level instead of one huge prompt: first which part
/// of the screen (toolbar, tabs, sidebar list, page, dialog…), then which
/// control inside it. Each answer is a full distribution, so an unsure first
/// level widens the search to the next most likely part (a beam), and "none
/// of these" at any level hands the step to the Reasoner. A Judge that reads
/// images sees the screen at every level.
extension JudgedPolicy {
    /// Up to this many candidates go straight to the control question.
    static let directLimit = 14
    /// Probability mass the region beam must cover (at most two regions).
    static let beamMass = 0.8
    /// Below this the Judge's control pick doesn't act.
    static let exploreFloor = 0.4

    func explore(_ words: String, base: Decision, goal: String, observation: Snapshot,
                 history: [StepRecord], images: [String]) async throws -> Decision? {
        var regions = observation.axTree.map(Screen.regions) ?? []
        // The menu bar is one more place to look: the app's own commands.
        let menus = observation.menus.filter(\.enabled)
        if !menus.isEmpty {
            regions.append(Screen.Region(name: "Menu commands",
                                         targets: menus.map { Screen.Target(menu: $0) }))
        }
        let total = regions.reduce(0) { $0 + $1.targets.count }
        guard total > 0 else { return nil }

        var pool: [Screen.Target]
        var trail: [String] = []
        if total <= Self.directLimit || regions.count == 1 {
            pool = regions.flatMap(\.targets)
        } else {
            let shown = Array(regions.prefix(12))
            let keys = shown.enumerated().map { "\($0.offset + 1). \($0.element.summary)" }
            let state = DecisionContext.state(goal: goal, observation: observation, history: history)
            var criteria = Dictionary(uniqueKeysWithValues: keys.map { ($0, String?.none) })
            criteria[Self.noneOption] = "What `goal` refers to is in none of these parts"
            let r = try await judge.evaluate(
                state: state,
                questions: ["region": .choice("Which part of the `current` screen holds what `goal` refers to?",
                                              options: criteria)],
                images: images)
            guard let ans = r.answers["region"] else { return nil }
            // Beam: most likely parts until they cover `beamMass`, at most two.
            let dist = (ans.probabilities ?? ans.choice.map { [$0: ans.confidence ?? 1] } ?? [:])
                .filter { $0.key != Self.noneOption }
                .sorted { $0.value > $1.value }
            var mass = 0.0
            var picked: [Int] = []
            for (key, p) in dist {
                guard let i = keys.firstIndex(of: key), picked.count < 2, mass < Self.beamMass else { break }
                picked.append(i); mass += p
                trail.append(String(format: "%@ p=%.2f", shown[i].name, p))
            }
            guard !picked.isEmpty, mass >= 0.3 else { return nil }
            pool = picked.sorted().flatMap { shown[$0].targets }
        }
        // Too many to list: keep the ones whose words overlap, in screen order.
        if pool.count > Self.directLimit + 2 {
            let ranked = pool.enumerated()
                .map { ($0.offset, $0.element.score(words)) }
                .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
                .prefix(Self.directLimit + 2).map(\.0).sorted()
            pool = ranked.map { pool[$0] }
        }
        let keys = pool.enumerated().map { "\($0.offset + 1). \($0.element.label)" }
        guard let answer = try await choose(
            "Which control on the `current` screen does `goal` mean? The list is in screen order.",
            among: keys, observation: observation, goal: goal, history: history, images: images),
              let i = answer.index, answer.p >= Self.exploreFloor else { return nil }
        let action = pool[i].action
        trail.append(String(format: "%@ p=%.2f", pool[i].label, answer.p))
        var d = base
        d.action = action
        d.confidence = min(answer.p, Self.pickedCap)
        d.explore = nil
        d.rationale = "judge \(judge.model) looked for “\(words)”: " + trail.joined(separator: " → ")
        return d
    }
}

/// The screen as parts a person would name, each with the controls in it.
enum Screen {
    /// Something the Judge can point at: an on-screen control or a menu command.
    struct Target {
        var label: String
        var name: String
        var action: Action
        var node: AXNode?

        init?(node n: AXNode) {
            guard let a = Screen.press(n) else { return nil }
            label = AXPolicy.label(n); name = n.title ?? n.desc ?? n.value ?? ""; action = a; node = n
        }
        init(menu m: MenuCommand) {
            label = "Menu “\(m.label)”"; name = m.title; action = .menuItem(path: m.path); node = nil
        }

        func score(_ words: String) -> Double {
            if let node { return AXPolicy.matchScore(words, node) }
            return MenuMatch.fuzzy(words, in: [MenuCommand(path: [name])]).first?.1 ?? 0
        }
    }

    struct Region {
        var name: String
        var targets: [Target]
        /// "List: New chat, Search chats, Library +9" — what the Judge reads.
        var summary: String {
            let sample = targets.prefix(4).map { $0.name.prefix(28) }
                .filter { !$0.isEmpty }.joined(separator: ", ")
            let more = targets.count > 4 ? " +\(targets.count - 4)" : ""
            return "\(name) (\(targets.count)): \(sample)\(more)"
        }
    }

    static let landmarks: [String: String] = [
        "AXToolbar": "Toolbar", "AXTabGroup": "Tabs", "AXWebArea": "Page",
        "AXList": "List", "AXOutline": "Sidebar", "AXTable": "Table",
        "AXSheet": "Dialog", "AXPopover": "Popover", "AXMenuBar": "Menu bar",
        "AXScrollArea": "Scroll area", "AXWindow": "Window",
    ]

    /// Controls worth pointing at: pressable or editable, or labeled text and
    /// images on screen (web and SwiftUI rows are often just that).
    static func isTarget(_ n: AXNode) -> Bool {
        if AXSemantics.pressable.contains(n.role) || AXSemantics.editable.contains(n.role) { return true }
        guard ["AXStaticText", "AXImage", "AXCell", "AXRow"].contains(n.role),
              let f = n.frame, f.w > 0, f.h > 0 else { return false }
        return !((n.title ?? n.desc ?? n.value ?? "").isEmpty)
    }

    /// Each landmark becomes a part; controls belong to the nearest one.
    static func regions(_ tree: AXNode) -> [Region] {
        var out: [Region] = []
        func walk(_ n: AXNode, region: Int?) {
            var here = region
            if let kind = landmarks[n.role] {
                let title = (n.title ?? n.desc ?? "").prefix(30)
                out.append(Region(name: title.isEmpty ? kind : "\(kind) “\(title)”", targets: []))
                here = out.count - 1
            }
            if let r = here, isTarget(n), let t = Target(node: n) { out[r].targets.append(t) }
            for c in n.children { walk(c, region: here) }
        }
        walk(tree, region: nil)
        return out.filter { !$0.targets.isEmpty }
    }

    /// How to activate a chosen control.
    static func press(_ n: AXNode) -> Action? {
        if AXSemantics.pressable.contains(n.role) { return .axPress(ref: n.ref) }
        guard let f = n.frame, f.w > 0, f.h > 0 else { return nil }
        return .click(x: f.x + f.w / 2, y: f.y + f.h / 2)
    }
}
