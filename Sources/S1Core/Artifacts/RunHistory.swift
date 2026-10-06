import Foundation

/// One past run, read from its meta.json — what a history list shows.
public struct RunSummary: Sendable, Identifiable, Hashable {
    public var id: String { dir.path }
    public let dir: URL
    public let goal: String
    public let started: Date?
    public let finished: Date?
    /// `RunStatus` raw value; nil while the run is live (or it crashed).
    public let status: String?
    public let summary: String?
    public let steps: Int?

    public var ok: Bool { status == RunStatus.done.rawValue }

    public init(dir: URL, goal: String, started: Date?, finished: Date?, status: String?,
                summary: String?, steps: Int?) {
        self.dir = dir; self.goal = goal; self.started = started; self.finished = finished
        self.status = status; self.summary = summary; self.steps = steps
    }
}

/// Past runs under `~/.s1/artifacts`, newest first. Run dirs are
/// ISO-timestamp-prefixed, so a name sort is a time sort — no stat calls.
public enum RunHistory {
    public static var root: URL { URL(fileURLWithPath: S1Home.path + "/artifacts") }

    public static func list(root: URL = RunHistory.root, limit: Int = 200) -> [RunSummary] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasPrefix("20") }
            .sorted(by: >)
            .prefix(limit)
            .compactMap { summary(of: root.appendingPathComponent($0)) }
    }

    public static func summary(of dir: URL) -> RunSummary? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("meta.json")),
              let meta = try? JSONDecoder().decode([String: String].self, from: data),
              let goal = meta["goal"] else { return nil }
        let iso = ISO8601DateFormatter()
        return RunSummary(dir: dir, goal: goal,
                          started: meta["started"].flatMap(iso.date(from:)),
                          finished: meta["finished"].flatMap(iso.date(from:)),
                          status: meta["status"], summary: meta["summary"],
                          steps: meta["steps"].flatMap(Int.init))
    }

    /// Screenshot files a run captured, in step order.
    public static func screenshots(in dir: URL) -> [URL] {
        let screens = dir.appendingPathComponent("screens")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: screens.path)) ?? []
        return names.filter { $0.hasSuffix(".png") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { screens.appendingPathComponent($0) }
    }
}
