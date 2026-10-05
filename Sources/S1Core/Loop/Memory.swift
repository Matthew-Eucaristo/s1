import Foundation

/// Persistent memory: short facts the user asked s1 to keep ("remember
/// that my editor is Zed"), one bullet per line in ~/.s1/memory.md — plain
/// text, editable, on by default (`memory: false` / `S1_MEMORY=0` turns it
/// off). S2 sees the newest facts within a small budget.
public enum Memory {
    public static var path: URL { URL(fileURLWithPath: S1Home.path + "/memory.md") }

    public static func enabled(_ cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let e = env["S1_MEMORY"] { return e != "0" }
        return cfg.memory != false
    }

    public static func facts(at url: URL = path) -> [String] {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return s.split(separator: "\n").compactMap { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("- ") else { return nil }
            return String(t.dropFirst(2))
        }
    }

    /// Newest facts that fit `budget` characters, oldest first.
    public static func recent(budget: Int = 2000, at url: URL = path) -> [String] {
        var out: [String] = [], used = 0
        for f in facts(at: url).reversed() {
            used += f.count + 3
            if used > budget { break }
            out.insert(f, at: 0)
        }
        return out
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

    public static func add(_ fact: String, at url: URL = path) throws {
        let f = fact.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty else { return }
        var all = facts(at: url).filter { $0.lowercased() != f.lowercased() }
        all.append(String(f.prefix(300)))
        try write(Array(all.suffix(200)), to: url)
    }

    public static func clear(at url: URL = path) throws { try write([], to: url) }

    static func write(_ facts: [String], to url: URL) throws {
        if url == path { S1Home.ensurePrivate() }
        let body = "# s1 memory — one fact per line; edit freely\n\n" + facts.map { "- \($0)\n" }.joined()
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

    public static func parse(_ goal: String) -> MetaCommand? {
        let g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
        if (try? /^(?:forget everything|forget (?:all|my) memor(?:y|ies)|clear (?:my )?memory|lupakan semua(?:nya)?)$/
            .ignoresCase().wholeMatch(in: g)) != nil { return .forget }
        if let m = try? /^(?:please\s+)?(?:save|simpan)\s+(?:that|this|it|ini|itu)?\s*(?:as|sebagai)\s+(?:a\s+)?(?:skill|shortcut)\s+(?:called\s+|named\s+|bernama\s+)?(.+)$/
            .ignoresCase().wholeMatch(in: g) {
            return .saveSkill(String(m.1).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“” ")))
        }
        if let m = try? /^(?:please\s+)?(?:remember|ingat(?:lah)?)\s+(?:that\s+|bahwa\s+)?(.+)$/
            .ignoresCase().wholeMatch(in: g) {
            return .remember(String(m.1))
        }
        return nil
    }

    public var kind: String {
        switch self { case .remember: "remember"; case .forget: "forget"; case .saveSkill: "saveSkill" }
    }

    /// Runs the command; the reply is shown and spoken.
    public func perform(conversation: Conversation = .shared) -> String {
        switch self {
        case .remember(let fact):
            guard Memory.enabled() else { return "Memory is off. Turn it on in Settings → General." }
            guard !Memory.looksSecret(fact) else { return "I won't store passwords, keys or tokens in memory." }
            do { try Memory.add(fact); return "Got it, I'll remember: \(fact)" }
            catch { return "Couldn't save memory: \(error.localizedDescription)" }
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
