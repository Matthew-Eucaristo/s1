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
    static let grammarWords = [
        "buka", "ketik", "klik", "tulis", "tunggu", "gulir", "geser",
        "tangkap", "tangkapan", "cek", "pastikan", "selesai", "tekan", "isi",
        "spasi", "panah", "hapus",
        "lalu", "kemudian", "terus", "open", "type", "click", "write",
        "wait", "scroll", "screenshot", "verify", "done", "press", "key",
    ]

    /// `custom` entries keep their spelling and rank above auto names.
    /// Case-insensitive dedup preserves the first-seen casing.
    public static func assemble(custom: [String], appNames: () -> [String] = InstalledApps.names) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for w in ["s1"] + custom + grammarWords + appNames() {
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
