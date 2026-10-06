import Foundation

/// Persistent memory, following Cognition's open Agent Memory Repo spec
/// (github.com/AgentMemoryRepo/agentmemoryrepo — the design behind
/// Devin's memory system): a main `~/.s1/memory.md` (the entry file —
/// one fact per line, user-editable) plus topic files at
/// `~/.s1/memory/<topic>.md`, and an auto-maintained index of `[[links]]`
/// so a human scanning the folder sees the same structure the agent does.
///
/// Routing: "remember that my editor is Zed" lands on the main list;
/// "remember that apps: my editor is Zed" files it under memory/apps.md.
/// Facts carry the spec's ` [added: YYYY-MM-DD] ` metadata; dedupe
/// ignores metadata and case. On by default — `memory: false` /
/// `S1_MEMORY=0` disables.
public enum Memory {
    /// The main file — also hosts the topic index between s1:index markers.
    public static var path: URL { URL(fileURLWithPath: S1Home.path + "/memory.md") }
    /// Topic files — one markdown file per routed subject.
    public static var topicsDir: URL { URL(fileURLWithPath: S1Home.path + "/memory", isDirectory: true) }

    static let indexStart = "<!-- s1:index -->"
    static let indexEnd = "<!-- /s1:index -->"
    /// Fact metadata — spec-style `[added: …]` plus the pre-spec
    /// `*(added …)*` stamp, so older files still dedupe correctly.
    /// (nonisolated: Regex isn't Sendable; a `let` never mutates.)
    nonisolated(unsafe) static let stampRe =
        /\s*(\[added: ?\d{4}-\d{2}-\d{2}\]|\*\(added \d{4}-\d{2}-\d{2}\)\*)\s*$/

    public static func enabled(_ cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let e = env["S1_MEMORY"] { return e != "0" }
        return cfg.memory != false
    }

    /// Fact lines of one file — bullets only, index block skipped.
    public static func facts(at url: URL = path) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [String] = [], inIndex = false
        for line in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == indexStart { inIndex = true; continue }
            if t == indexEnd { inIndex = false; continue }
            guard !inIndex, t.hasPrefix("- ") else { continue }
            out.append(String(t.dropFirst(2)))
        }
        return out
    }

    /// A remembered fact without its "*(added …)*" stamp, case kept.
    static func plain(_ f: String) -> String {
        f.replacing(stampRe, with: "").trimmingCharacters(in: .whitespaces)
    }

    /// "my editor" → "Zed" when memory says "my editor is Zed" (also
    /// "editorku adalah Zed"). Lets the grammar act on personal names without
    /// asking a model.
    public static func resolve(_ phrase: String, facts: [String]? = nil) -> String? {
        var subject = phrase.lowercased().trimmingCharacters(in: .whitespaces)
        var personal = false
        for lead in ["my ", "the "] where subject.hasPrefix(lead) {
            subject = String(subject.dropFirst(lead.count)); personal = personal || lead == "my "
        }
        for tail in ["ku", " saya", " aku"] where subject.hasSuffix(tail) && subject.count > tail.count + 2 {
            subject = String(subject.dropLast(tail.count)); personal = true
        }
        guard personal, subject.count >= 2, enabled() else { return nil }
        let pattern = "(?i)^(?:my\\s+)?" + NSRegularExpression.escapedPattern(for: subject)
            + "(?:ku)?\\s+(?:is|are|adalah|itu|=)\\s+(.+?)[.!]?$"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return nil }
        for f in (facts ?? allFacts()).reversed() {
            let t = plain(f)
            if let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)),
               let r = Range(m.range(at: 1), in: t) {
                return String(t[r]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    /// Answer "what's my editor?" / "apa editorku?" straight from memory —
    /// only for personal questions, only when a fact matches. Nil = not a
    /// memory question (the run goes on as usual).
    public static func recall(_ goal: String, facts: [String]? = nil) -> String? {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
        let patterns = [
            /^(?i)(?:what|who|where|which)(?:'s| is| are| was)\s+(my\s+.+)$/,
            /^(?i)(?:do you remember|remind me(?: of| about)?|what did i (?:say|tell you) about)\s+(.+)$/,
            /^(?i)(?:apa|siapa|di ?mana)\s+(.+(?:ku|saya|aku))$/,
        ]
        guard enabled(),
              let topic = patterns.lazy.compactMap({ g.firstMatch(of: $0).map { String($0.1) } }).first else { return nil }
        if let v = resolve(topic.hasPrefix("my ") || topic.lowercased().hasSuffix("ku") ? topic : "my " + topic, facts: facts) {
            return "\(topic.prefix(1).uppercased() + topic.dropFirst()): \(v)."
        }
        // Looser: the fact sharing the most meaningful words with the question.
        let stop: Set<String> = ["my", "the", "a", "is", "are", "what", "ku", "saya", "aku", "apa", "itu", "about"]
        let want = Set(topic.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init).filter { $0.count > 2 && !stop.contains($0) })
        guard !want.isEmpty else { return nil }
        let scored = (facts ?? allFacts()).map { f -> (String, Int) in
            let words = Set(plain(f).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
            return (plain(f), want.intersection(words).count)
        }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }
        return scored.map { "You told me: \($0.0)" }
    }

    /// Dedupe key: stamp-free, case-folded — "Zed *(added …)*" == "zed".
    public static func normalizeFact(_ f: String) -> String {
        f.replacing(stampRe, with: "").lowercased()
            .trimmingCharacters(in: .whitespaces)
    }

    /// "apps: my editor is Zed" → (apps, "my editor is Zed"). The topic
    /// word must be ≥2 chars so "i: prefer dark mode" stays a plain fact.
    public static func route(_ fact: String) -> (topic: String?, fact: String) {
        guard let m = try? /^([A-Za-z][A-Za-z0-9_-]{1,23})\s*:\s*(.{2,})$/
            .wholeMatch(in: fact) else { return (nil, fact) }
        let slug = String(m.1).lowercased()
            .replacingOccurrences(of: "_", with: "-")
        return (slug, String(m.2).trimmingCharacters(in: .whitespaces))
    }

    public static func topicFile(_ name: String) -> URL {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { $0.append($1) }
        return topicsDir.appendingPathComponent((slug.isEmpty ? "notes" : slug) + ".md")
    }

    /// Every fact the session knows: main file plus each topic file,
    /// topic entries prefixed "<topic>: " so S2 sees their grouping.
    public static func allFacts() -> [String] {
        var out = facts(at: path)
        for t in topics() {
            for f in facts(at: t.url) { out.append("\(t.name): \(f)") }
        }
        return out
    }

    /// Newest facts that fit `budget` characters, oldest first, followed by
    /// a topic-file index line so S2 knows where memory lives on disk.
    public static func recent(budget: Int = 2000, at url: URL = path) -> [String] {
        var out: [String] = [], used = 0
        for f in allFacts(at: url).reversed() {
            used += f.count + 3
            if used > budget { break }
            out.insert(f, at: 0)
        }
        let dir = url.deletingLastPathComponent()
            .appendingPathComponent("memory", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let ts = files.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
            .map { (name: $0.deletingPathExtension().lastPathComponent, count: facts(at: $0).count) }
        if !ts.isEmpty {
            out.append("· memory files: "
                + ts.map { "memory/\($0.name).md (\($0.count))" }.joined(separator: ", "))
        }
        return out
    }

    static func allFacts(at main: URL) -> [String] {
        // url != path only in tests — keep the same "main + its sibling dir"
        // layout so tests exercise the real code path.
        var out = facts(at: main)
        let dir = main.deletingLastPathComponent().appendingPathComponent("memory", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in files.sorted(by: { $0.path < $1.path }) where u.pathExtension == "md" {
            for f in facts(at: u) {
                out.append("\(u.deletingPathExtension().lastPathComponent): \(f)")
            }
        }
        return out
    }

    /// Topic files on disk: name + fact count, sorted by name.
    public static func topics() -> [(name: String, count: Int, url: URL)] {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: topicsDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
            .map { (name: $0.deletingPathExtension().lastPathComponent,
                    count: facts(at: $0).count, url: $0) }
    }

    /// Never keep credentials — memory is plain text that S2 reads.
    public static func looksSecret(_ s: String) -> Bool {
        let l = s.lowercased()
        if ["password", "passcode", "kata sandi", "api key", "apikey", "secret", "token", "pin "]
            .contains(where: { l.contains($0) }) { return true }
        return s.split(separator: " ").contains { w in
            w.count >= 24 && w.allSatisfy { $0.isLetter || $0.isNumber || "-_".contains($0) }
                && w.contains(where: \.isNumber)
        }
    }

    /// Append a fact — routed to a topic file when it opens with
    /// "topic: …", else the main list. Returns the topic it landed on
    /// (nil = main list) so the spoken reply can say where it went.
    @discardableResult
    public static func add(_ fact: String, at url: URL = path) throws -> String? {
        let f = fact.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return nil }
        let (topic, body) = route(f)
        let stamped = String(body.prefix(300)) + " [added: \(Self.today())]"
        if let topic {
            // Topic dir sits beside whichever main file we're writing to —
            // tests pass their own path and get an isolated layout.
            let dir = url == path ? topicsDir
                : url.deletingLastPathComponent().appendingPathComponent("memory", isDirectory: true)
            let file = dir.appendingPathComponent(topic + ".md")
            var all = facts(at: file).filter { normalizeFact($0) != normalizeFact(body) }
            all.append(stamped)
            try write(all, to: file,
                      header: "# \(topic) — s1 memory topic; one fact per line, edit freely")
            try? rebuildIndex(at: url)
            return topic
        }
        var all = facts(at: url).filter { normalizeFact($0) != normalizeFact(body) }
        all.append(stamped)
        try write(Array(all.suffix(200)), to: url)
        return nil
    }

    static func today() -> String {
        let d = DateFormatter(); d.dateFormat = "yyyy-MM-dd"
        return d.string(from: Date())
    }

    /// Wipe everything — main file and every topic file.
    public static func clear(at url: URL = path) throws {
        try write([], to: url)
        let dir = url == path ? topicsDir
            : url.deletingLastPathComponent().appendingPathComponent("memory", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        for u in files where u.pathExtension == "md" {
            try? FileManager.default.removeItem(at: u)
        }
        try? rebuildIndex(at: url)
    }

    /// Rewrite the `s1:index` block inside the main file to mirror the
    /// topic files on disk — markers make it cheap to find and safe to
    /// regenerate without touching the user's own lines. Topics come from
    /// the `memory/` dir beside `url` (== topicsDir for the default path).
    public static func rebuildIndex(at url: URL = path) throws {
        let dir = url.deletingLastPathComponent()
            .appendingPathComponent("memory", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let ts = files.filter { $0.pathExtension == "md" }.sorted { $0.path < $1.path }
            .map { (name: $0.deletingPathExtension().lastPathComponent, count: facts(at: $0).count) }
        let block = indexStart + "\n"
            + (ts.isEmpty
               ? "_no topic files yet — use `remember that <topic>: <fact>`_\n"
               : ts.map { "- [[memory/\($0.name).md]] — \($0.count) fact\($0.count == 1 ? "" : "s")\n" }
                  .joined())
            + indexEnd
        var s = (try? String(contentsOf: url, encoding: .utf8))
            ?? "# s1 memory — one fact per line; `topic: fact` files it under memory/<topic>.md\n\n"
        if let a = s.range(of: indexStart), let b = s.range(of: indexEnd) {
            s.replaceSubrange(a.lowerBound..<b.upperBound, with: block)
        } else {
            s += "\n" + block + "\n"
        }
        if url == path { S1Home.ensurePrivate() }
        try s.write(to: url, atomically: true, encoding: .utf8)
    }

    static func write(_ facts: [String], to url: URL,
                      header: String = "# s1 memory — one fact per line; `topic: fact` files it under memory/<topic>.md; edit freely") throws {
        if url == path || url.deletingLastPathComponent() == topicsDir { S1Home.ensurePrivate() }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var body = header + "\n\n" + facts.map { "- \($0)\n" }.joined()
        if url == path {
            // Carry the index block through a rewrite — dropping it would
            // leave stale [[links]] until the next topic write.
            if let a = (try? String(contentsOf: url, encoding: .utf8)).flatMap({ s in
                s.range(of: indexStart).flatMap { lo in
                    s.range(of: indexEnd).map { hi in s[lo.lowerBound..<hi.upperBound] } }
            }) {
                body += "\n" + a + "\n"
            }
        }
        try body.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// A saved shortcut: a name (and extra trigger phrases) that replays a list
/// of S1 subgoals. Each step still goes through grammar/Jev and the safety
/// gate — a skill is a plan, never a bypass. JSON in ~/.s1/skills/.
public struct Skill: Codable, Sendable, Equatable {
    public var name: String
    public var triggers: [String]
    public var steps: [String]
    public var created: Date?

    public init(name: String, triggers: [String] = [], steps: [String], created: Date? = Date()) {
        self.name = name; self.triggers = triggers; self.steps = steps; self.created = created
    }
}

public enum Skills {
    public static var dir: URL { URL(fileURLWithPath: S1Home.path + "/skills", isDirectory: true) }

    public static func normalize(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " })
            .split(separator: " ").joined(separator: " ")
    }

    public static func load(from d: URL = dir) -> [Skill] {
        let files = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return files.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
            .compactMap { try? dec.decode(Skill.self, from: Data(contentsOf: $0)) }
            .filter { !$0.steps.isEmpty }
    }

    public static func save(_ s: Skill, to d: URL = dir) throws {
        if d == dir { S1Home.ensurePrivate() }
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let slug = normalize(s.name).replacingOccurrences(of: " ", with: "-")
        try enc.encode(s).write(to: d.appendingPathComponent((slug.isEmpty ? "skill" : slug) + ".json"),
                                options: .atomic)
    }

    /// "morning setup", "run morning setup", "jalankan morning setup".
    public static func match(_ goal: String, in skills: [Skill]) -> Skill? {
        var g = normalize(goal)
        for p in ["run skill ", "run shortcut ", "run ", "jalankan ", "do "] where g.hasPrefix(p) {
            g = String(g.dropFirst(p.count)); break
        }
        guard !g.isEmpty else { return nil }
        return skills.first { s in ([s.name] + s.triggers).contains { normalize($0) == g } }
    }
}

/// Commands about s1 itself, handled before any model runs.
public enum MetaCommand: Equatable, Sendable {
    case remember(String)
    case forget
    case saveSkill(String)
    /// A personal question memory can answer ("what's my editor?").
    case recall(String)

    public static func parse(_ goal: String) -> MetaCommand? {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        if (try? /^(?:forget everything|forget (?:all|my) memor(?:y|ies)|clear (?:my )?memory|lupakan semua(?:nya)?)$/
            .ignoresCase().wholeMatch(in: g)) != nil { return .forget }
        if let m = try? /^(?:please\s+)?(?:save|simpan)\s+(?:that|this|it|ini|itu)?\s*(?:as|sebagai)\s+(?:a\s+)?(?:skill|shortcut)\s+(?:called\s+|named\s+|bernama\s+)?(.+)$/
            .ignoresCase().wholeMatch(in: g) {
            return .saveSkill(String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“” ")))
        }
        if let answer = Memory.recall(g) { return .recall(answer) }
        if let m = try? /^(?:please\s+)?(?:remember|ingat(?:lah)?)\s+(?:that\s+|bahwa\s+)?(.+)$/
            .ignoresCase().wholeMatch(in: g) {
            return .remember(String(m.1))
        }
        return nil
    }

    public var kind: String {
        switch self { case .remember: "remember"; case .forget: "forget"; case .saveSkill: "saveSkill"; case .recall: "recall" }
    }

    /// Runs the command; the reply is shown and spoken.
    public func perform(conversation: Conversation = .shared) -> String {
        switch self {
        case .remember(let fact):
            guard Memory.enabled() else { return "Memory is off. Turn it on in Settings → General." }
            guard !Memory.looksSecret(fact) else { return "I won't store passwords, keys or tokens in memory." }
            do {
                let topic = try Memory.add(fact)
                if let topic { return "Got it — filed under " + topic + ": \(Memory.route(fact).fact)" }
                return "Got it, I'll remember: \(fact)"
            } catch { return "Couldn't save memory: \(error.localizedDescription)" }
        case .recall(let answer):
            return answer
        case .forget:
            do { try Memory.clear(); return "Memory cleared." }
            catch { return "Couldn't clear memory: \(error.localizedDescription)" }
        case .saveSkill(let name):
            guard let t = conversation.lastSuccessful() else {
                return "Nothing to save yet. Run something first, then say “save that as a skill called …”."
            }
            let steps = t.steps.isEmpty ? [t.goal] : t.steps
            do {
                try Skills.save(Skill(name: name, steps: steps))
                return "Saved skill “\(name)” (\(steps.count) step\(steps.count == 1 ? "" : "s")). Say “\(name)” to run it."
            } catch { return "Couldn't save skill: \(error.localizedDescription)" }
        }
    }
}
