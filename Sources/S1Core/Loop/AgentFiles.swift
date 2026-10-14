import Foundation

/// The open agent-file standards, read and written by s1:
/// - `AGENTS.md` (agents.md): plain instructions for agents.
/// - Agent Skills (agentskills.io): a folder with a `SKILL.md` whose YAML
///   frontmatter has `name` and `description`, plus optional `scripts/`,
///   `references/`, `assets/`.
///
/// The Reasoner gets them only when `agentFiles` is on (off by default):
/// instructions first, then every skill's name and description, and the
/// full text of the one skill the goal is about — progressive disclosure,
/// inside a fixed budget. s1 never runs a skill's scripts.
public enum AgentFiles {
    public static func enabled(_ cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let e = env["S1_AGENT_FILES"]?.lowercased() { return ["1", "on", "true", "yes"].contains(e) }
        return cfg.agentFiles ?? false
    }

    /// Where instructions live, most specific first: s1's own, then the
    /// shared cross-agent folder. (Coding tools' own files — CLAUDE.md,
    /// ~/.codex — are about code and stay theirs.)
    public static func instructionFiles(home: String = NSHomeDirectory()) -> [URL] {
        [S1Home.path + "/AGENTS.md", home + "/.agents/AGENTS.md"].map { URL(fileURLWithPath: $0) }
    }

    /// Skill folders: exported s1 skills, then the shared and Claude ones.
    public static func skillDirs(home: String = NSHomeDirectory()) -> [URL] {
        [S1Home.path + "/agent-skills", home + "/.agents/skills", home + "/.claude/skills"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    // MARK: - SKILL.md

    public struct SkillDoc: Sendable, Equatable {
        public var name: String
        public var description: String
        public var body: String
        public var folder: URL
    }

    /// The frontmatter between the leading `---` lines, as flat key → value
    /// (quotes stripped; a folded `>`/`|` value takes its indented lines).
    static func frontmatter(_ text: String) -> (fields: [String: String], body: String)? {
        var lines = text.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---",
              let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" })
        else { return nil }
        var fields: [String: String] = [:]
        var key: String?
        for line in lines[1..<end] {
            if let k = key, line.hasPrefix(" ") || line.hasPrefix("\t") {
                fields[k] = ((fields[k] ?? "") + " " + line.trimmingCharacters(in: .whitespaces))
                    .trimmingCharacters(in: .whitespaces)
                continue
            }
            key = nil
            guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
            let k = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var v = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if v == ">" || v == "|" || v == ">-" || v == "|-" { v = ""; key = k }
            if v.count >= 2, let f = v.first, let l = v.last, (f == "\"" && l == "\"") || (f == "'" && l == "'") {
                v = String(v.dropFirst().dropLast())
            }
            fields[k] = v
        }
        lines.removeFirst(end + 1)
        return (fields, lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Problems with a skill's frontmatter per the Agent Skills spec; empty = valid.
    public static func problems(name: String?, description: String?) -> [String] {
        var out: [String] = []
        if let n = name, !n.isEmpty {
            if n.count > 64 { out.append("name is longer than 64 characters") }
            if n.range(of: #"^[a-z0-9]+(-[a-z0-9]+)*$"#, options: .regularExpression) == nil {
                out.append("name must be lowercase letters, digits and single hyphens")
            }
        } else { out.append("name is missing") }
        if let d = description, !d.isEmpty {
            if d.count > 1024 { out.append("description is longer than 1024 characters") }
        } else { out.append("description is missing") }
        return out
    }

    public static func readSkill(at folder: URL) -> SkillDoc? {
        guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8),
              let fm = frontmatter(text), let name = fm.fields["name"], let desc = fm.fields["description"],
              problems(name: name, description: desc).isEmpty else { return nil }
        return SkillDoc(name: name, description: desc, body: fm.body, folder: folder)
    }

    /// Every valid skill in the skill folders; a name seen first wins.
    public static func skills(in dirs: [URL] = skillDirs()) -> [SkillDoc] {
        var seen = Set<String>(), out: [SkillDoc] = []
        for d in dirs {
            let kids = (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? []
            for k in kids.sorted(by: { $0.path < $1.path }) {
                guard let s = readSkill(at: k), seen.insert(s.name).inserted else { continue }
                out.append(s)
            }
        }
        return out
    }

    // MARK: - Reasoner context

    /// The agent-file section of a Reasoner prompt, within `budget`
    /// characters; nil when off or there's nothing to say.
    public static func context(goal: String, budget: Int = 4000,
                               instructions: [URL] = instructionFiles(),
                               skills: [SkillDoc]? = nil) -> String? {
        var parts: [String] = []
        var left = budget
        func take(_ s: String, _ cap: Int) -> String? {
            let t = String(s.prefix(min(cap, left)))
            guard !t.isEmpty else { return nil }
            left -= t.count
            return t
        }
        for url in instructions {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let t = take(text, 1800) else { continue }
            parts.append("The user's agent instructions (\(url.lastPathComponent) in \(url.deletingLastPathComponent().lastPathComponent)):\n\(t)")
        }
        let all = skills ?? Self.skills()
        if !all.isEmpty {
            let list = all.map { "- \($0.name): \($0.description.prefix(200))" }.joined(separator: "\n")
            if let t = take(list, 1200) { parts.append("Agent Skills the user has (name: when to use):\n" + t) }
            if let hit = relevant(goal, in: all), let t = take(hit.body, 1500) {
                parts.append("The skill “\(hit.name)” fits this goal; its instructions:\n" + t)
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n\n")
    }

    /// The skill a goal is about: its name's words are all in the goal, or
    /// at least two meaningful description words are.
    static func relevant(_ goal: String, in skills: [SkillDoc]) -> SkillDoc? {
        let stop: Set<String> = ["the", "and", "for", "with", "this", "that", "use", "when", "from", "into", "your"]
        func words(_ s: String) -> Set<String> {
            Set(s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
                .filter { $0.count > 2 && !stop.contains($0) })
        }
        let g = words(goal)
        guard !g.isEmpty else { return nil }
        return skills.max { a, b in
            score(a, g, words) < score(b, g, words)
        }.flatMap { score($0, g, words) >= 2 ? $0 : nil }
    }

    private static func score(_ s: SkillDoc, _ g: Set<String>, _ words: (String) -> Set<String>) -> Int {
        let name = words(s.name.replacingOccurrences(of: "-", with: " "))
        if !name.isEmpty, name.isSubset(of: g) { return 10 }
        return words(s.description).intersection(g).count
    }

    // MARK: - s1 skills ⇄ SKILL.md

    /// An s1 skill as an Agent Skills folder: SKILL.md (portable: the steps
    /// in words) plus `assets/s1-skill.json` (lossless, with the recording).
    @discardableResult
    public static func export(_ skill: Skill, to parent: URL) throws -> URL {
        let slug = String(Skills.normalize(skill.name).replacingOccurrences(of: " ", with: "-").prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let name = slug.isEmpty ? "s1-skill" : slug
        let folder = parent.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("assets"), withIntermediateDirectories: true)
        let steps = skill.steps.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        var desc = "Do “\(skill.name)” on a Mac: " + skill.steps.joined(separator: ", then ")
        if desc.count > 1024 { desc = String(desc.prefix(1021)) + "…" }
        let yaml = desc.replacingOccurrences(of: "\"", with: "'")
        let md = """
        ---
        name: \(name)
        description: "\(yaml)"
        metadata:
          s1-skill: "\(skill.name.replacingOccurrences(of: "\"", with: "'"))"
        ---

        # \(skill.name)

        Steps, in order:

        \(steps)

        Exported from s1. `assets/s1-skill.json` holds the full s1 skill, including any recorded actions.

        """
        try md.write(to: folder.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(skill).write(to: folder.appendingPathComponent("assets/s1-skill.json"), options: .atomic)
        return folder
    }

    public enum ImportError: Error, LocalizedError {
        case invalid([String]), noSteps
        public var errorDescription: String? {
            switch self {
            case .invalid(let p): "not a valid SKILL.md: " + p.joined(separator: "; ")
            case .noSteps: "the skill has no steps s1 can run (a numbered or bulleted list)"
            }
        }
    }

    /// An Agent Skills folder as an s1 skill: the lossless s1 JSON when the
    /// folder came from s1, else the body's numbered/bulleted list as the
    /// steps. Scripts are never imported as anything to run.
    public static func importSkill(from folder: URL) throws -> Skill {
        let text = try String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8)
        guard let fm = frontmatter(text) else { throw ImportError.invalid(["no frontmatter"]) }
        let issues = problems(name: fm.fields["name"], description: fm.fields["description"])
        guard issues.isEmpty, let name = fm.fields["name"] else { throw ImportError.invalid(issues) }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: folder.appendingPathComponent("assets/s1-skill.json")),
           let s = try? dec.decode(Skill.self, from: data), !s.steps.isEmpty {
            return s
        }
        let steps = fm.body.components(separatedBy: "\n").compactMap { line -> String? in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard let m = t.firstMatch(of: /^(?:\d+[.)]|[-*•])\s+(.+)$/) else { return nil }
            return String(m.1).trimmingCharacters(in: .whitespaces)
        }
        guard !steps.isEmpty else { throw ImportError.noSteps }
        return Skill(name: name.replacingOccurrences(of: "-", with: " "), steps: Array(steps.prefix(12)))
    }
}
