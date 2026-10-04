import Foundation

/// Bound on `~/.s1/artifacts` growth — every run drops screenshots + JSONL,
/// and nobody should ever have to think about it. Keep the newest N run
/// dirs, remove the rest. Run dirs are ISO-timestamp-prefixed, so a name
/// sort IS a chronological sort.
public enum ArtifactStore {

    /// How many recent runs to keep. `S1_KEEP_RUNS` overrides; "0" or a
    /// negative value disables pruning entirely.
    public static var keepRuns: Int {
        if let s = ProcessInfo.processInfo.environment["S1_KEEP_RUNS"],
           let n = Int(s) { return max(0, n) }
        return 50
    }

    /// Directory names that look like run dirs (ISO prefix `YYYY-`).
    private static func isRunDir(_ name: String) -> Bool {
        name.count > 5 && name.hasPrefix("20") && name.first?.isNumber == true
    }

    /// Remove the oldest run dirs beyond `keep`. Only touches directories
    /// that match the run-dir shape — anything else a user dropped in
    /// artifacts/ is theirs, we don't garbage-collect it.
    @discardableResult
    public static func prune(root: URL, keep: Int = keepRuns) -> Int {
        guard keep > 0 else { return 0 }
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return 0 }
        let runs = entries.filter { isRunDir($0.lastPathComponent) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let excess = runs.count - keep
        guard excess > 0 else { return 0 }
        var removed = 0
        for url in runs.prefix(excess) {
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// `s1 clean` — wipe every run dir under the artifacts root.
    /// Returns the number removed.
    @discardableResult
    public static func cleanAll(root: URL) -> Int {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil) else { return 0 }
        var removed = 0
        for url in entries where isRunDir(url.lastPathComponent) {
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }
}
