import Foundation

/// Matching what the user said to the frontmost app's menu commands.
enum MenuMatch {
    /// Verbs that mean "use this item" — the rest of the phrase is its title.
    static let pickVerbs: Set<String> = ["click", "klik", "press", "tekan", "choose", "select", "pilih",
                                         "use", "do", "run", "toggle"]
    /// "create a new chat" → "new chat"; "make a new window" → "new window".
    static let createVerbs: Set<String> = ["create", "make", "start", "buat", "bikin", "mulai"]

    /// An exact menu command for the phrase, or nil. "new chat" → File › New
    /// Chat; "shuffle on" → Controls › Shuffle › On; "click Show Sidebar".
    /// Never "open X" by X alone: "open Notes" means the app, not a menu.
    static func exact(verb: String, arg: String, in menus: [MenuCommand]) -> MenuCommand? {
        let items = menus.filter(\.enabled)
        guard !items.isEmpty else { return nil }
        var phrases = [verb + (arg.isEmpty ? "" : " " + arg)]
        if pickVerbs.contains(verb), !arg.isEmpty { phrases.append(arg) }
        if createVerbs.contains(verb), !arg.isEmpty {
            let rest = arg.replacingOccurrences(of: #"^(a|an|the|sebuah)\s+"#, with: "",
                                                options: [.regularExpression, .caseInsensitive])
            phrases.append(rest.lowercased().hasPrefix("new ") ? rest : "new " + rest)
        }
        let wanted = Set(phrases.map(clean))
        return items.first { keys($0).contains { wanted.contains($0) } }
    }

    /// A command's names: its title, and for a submenu item "Shuffle On".
    static func keys(_ m: MenuCommand) -> [String] {
        var k = [clean(m.title)]
        if m.path.count >= 3 { k.append(clean(m.path[m.path.count - 2] + " " + m.title)) }
        return k
    }

    static func clean(_ s: String) -> String {
        MenuReader.normalize(s).replacingOccurrences(of: #"[^\p{L}\p{N} ]"#, with: " ", options: .regularExpression)
            .split(separator: " ").joined(separator: " ")
    }

    /// Everyday words for what menus call something else.
    static let synonyms: [String: [String]] = [
        "skip": ["next"], "next": ["next"], "back": ["previous", "back"], "previous": ["previous"],
        "louder": ["increase", "volume"], "quieter": ["decrease", "volume"], "softer": ["decrease", "volume"],
        "bigger": ["zoom", "in", "larger"], "smaller": ["zoom", "out", "smaller"],
        "fullscreen": ["full", "screen"], "lagu": ["track", "song"], "berikutnya": ["next"],
        "sebelumnya": ["previous"], "acak": ["shuffle"], "ulangi": ["repeat"], "baru": ["new"],
    ]
    static let stopwords: Set<String> = ["the", "a", "an", "my", "this", "that", "it", "please", "to",
                                         "for", "me", "in", "on", "of", "and", "ya", "dong", "tolong", "can", "you"]

    /// Commands that share words with the phrase, best first, with a 0…1
    /// score: how much of the command's title the phrase covers.
    static func fuzzy(_ phrase: String, in menus: [MenuCommand], limit: Int = 5) -> [(MenuCommand, Double)] {
        var words = Set(clean(phrase).split(separator: " ").map(String.init)).subtracting(stopwords)
        for w in words { words.formUnion(synonyms[w] ?? []) }
        guard !words.isEmpty else { return [] }
        return menus.filter(\.enabled).compactMap { m -> (MenuCommand, Double)? in
            let title = Set(clean(keys(m).last ?? m.title).split(separator: " ").map(String.init))
            let hit = title.intersection(words).count
            guard hit > 0 else { return nil }
            return (m, Double(hit) / Double(max(title.count, 1)))
        }
        .sorted { $0.1 > $1.1 }
        .prefix(limit).map { $0 }
    }
}
