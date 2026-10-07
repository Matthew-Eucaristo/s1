import AppKit
import Foundation

/// Assembles the contextual-strings list for STT: the user's own words
/// first (they always win), then installed app names — the things people
/// most often say wrong to a recognizer ("TextEdit", "Linear", "Warp").
/// Apple caps contextual strings at 100 total across all tags.
public enum Vocabulary {
    public static let appleLimit = 100

    /// Command-grammar words — the agent's own domain vocabulary. Without
    /// these, dictation spells them wrong ("buka"→"Buku", "ketik"→"ketek")
    /// and a perfectly heard sentence fails to parse.
    /// Indonesian only: English command words ("open", "type") are common
    /// enough that a hint slot is better spent on an app name.
    /// Always first: the name and the hands-free dictation switches.
    static let fixed = ["s1", "start dictating", "stop dictating", "dikte"]

    static let grammarWords = [
        "buka", "ketik", "klik", "tulis", "tunggu", "gulir", "geser",
        "tangkap", "tangkapan", "cek", "pastikan", "selesai", "tekan", "isi",
        "spasi", "panah", "hapus", "lalu", "kemudian", "terus",
    ]

    /// Words s1 already knows the user says: saved skill names + triggers,
    /// and proper nouns pulled from remembered facts ("my editor is Zed"
    /// teaches "Zed"). Mid-fact capitalized tokens are almost always names;
    /// the leading word is skipped so sentence starters don't qualify.
    public static func learned() -> [String] {
        var out = Skills.load().flatMap { [$0.name] + $0.triggers }
        for fact in Memory.allFacts() {
            let words = fact.split(separator: " ")
            for tok in words.dropFirst() {
                let w = String(tok).trimmingCharacters(in: .punctuationCharacters)
                guard w.count > 1, w.first?.isUppercase == true else { continue }
                out.append(w)
            }
        }
        return out
    }

    /// `custom` entries keep their spelling and rank above learned/auto
    /// names. Case-insensitive dedup preserves the first-seen casing.
    public static func assemble(custom: [String],
                                learned: () -> [String] = Vocabulary.learned,
                                appNames: () -> [String] = InstalledApps.ranked) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        // App names before grammar words: with 100 slots, "Chrome" being
        // heard right matters more than biasing "buka".
        for w in fixed + custom + learned() + appNames() + grammarWords {
            let t = w.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            guard seen.insert(t.lowercased()).inserted else { continue }
            out.append(t)
            if out.count >= appleLimit { break }
        }
        return out
    }
}

/// Display names of installed apps — the source of STT's auto vocabulary.
/// Directory scan only (fast, deterministic, no Spotlight stall).
public enum InstalledApps {
    public static let appDirs = [
        "/System/Applications",
        "/System/Applications/Utilities",
        "/Applications",
        "/Applications/Utilities",
        NSHomeDirectory() + "/Applications",
    ]

    /// Hint order for the recognizer's 100 slots: apps running now, then
    /// ones the user installed, then Apple's — each with its everyday short
    /// form ("Google Chrome" → also "Chrome").
    public static func ranked() -> [String] {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }.compactMap(\.localizedName)
        let byDir = Dictionary(grouping: names(withDir: true), by: \.dir).mapValues { $0.map(\.name) }
        let user = (byDir["/Applications"] ?? []) + (byDir[NSHomeDirectory() + "/Applications"] ?? [])
        let apple = (byDir["/System/Applications"] ?? []) + (byDir["/Applications/Utilities"] ?? [])
            + (byDir["/System/Applications/Utilities"] ?? [])
        return (running + user + apple).flatMap { [$0] + [shortForm($0)].compactMap { $0 } }
    }

    /// "Google Chrome" → "Chrome", "Microsoft Word" → "Word"; nil when the
    /// last word is generic ("Player", "Studio") or the name is one word.
    static func shortForm(_ name: String) -> String? {
        let words = name.split(separator: " ").map(String.init)
        guard words.count >= 2, let last = words.last, last.count >= 4,
              !["player", "studio", "editor", "viewer", "settings", "center", "utility",
                "assistant", "app", "manager", "preview"].contains(last.lowercased()) else { return nil }
        return last
    }

    static func names(withDir: Bool) -> [(dir: String, name: String)] {
        appDirs.flatMap { dir in
            ((try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [])
                .filter { $0.hasSuffix(".app") }.sorted().map { (dir, String($0.dropLast(4))) }
        }
    }

    public static func names() -> [String] {
        var out: [String] = []
        for dir in appDirs {
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { continue }
            for n in names where n.hasSuffix(".app") {
                out.append(String(n.dropLast(4)))
            }
        }
        return out
    }
}
