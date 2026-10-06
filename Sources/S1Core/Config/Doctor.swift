import Foundation

/// `s1 doctor` — checks every standardized file under ~/.s1 plus the
/// external pieces s1 relies on (keychain keys, cua-driver, srt). File
/// structure and referential integrity only: it never hits the network —
/// `s1 config` already probes endpoints live.
public enum Doctor {
    public enum Level: String, Sendable { case ok, warn, fail }
    public struct Item: Sendable, Equatable {
        public var level: Level
        public var what: String
        public var detail: String
        public init(_ level: Level, _ what: String, _ detail: String = "") {
            self.level = level; self.what = what; self.detail = detail
        }
    }

    /// config.json keys S1Config knows — anything else is almost certainly
    /// a typo the decoder silently ignores.
    static let knownConfigKeys: Set<String> = [
        "providers", "models", "cloudVoice", "vision", "locale", "speak", "vocabulary", "recent",
        "notchHUD", "voice", "executor", "memory", "sandbox", "onboarded",
        "voiceInterrupt", "vad", "vadSensitivity",
    ]

    /// The whole ~/.s1 sweep. Synchronous and cheap — every check is a
    /// local file read or a binary probe.
    public static func run(home: String = S1Home.path,
                           secret: Models.Secret = Models.keychain) -> [Item] {
        var out: [Item] = []
        let fm = FileManager.default

        // ~/.s1 itself: owner-only like ~/.ssh — it can hold run artifacts.
        if let perms = (try? fm.attributesOfItem(atPath: home))?[.posixPermissions] as? Int {
            if perms & 0o077 != 0 {
                out.append(Item(.warn, "~/.s1 permissions",
                                "dir is \(String(perms, radix: 8)) — chmod 700 recommended"))
            } else {
                out.append(Item(.ok, "~/.s1 permissions", "700"))
            }
        }

        checkConfig(home: home, out: &out)
        checkModels(S1Config.load(from: home + "/config.json"), secret: secret, out: &out)
        checkSnippets(home: home, out: &out)
        checkConvert(home: home, out: &out)
        checkSkills(home: home, out: &out)
        checkMemory(home: home, out: &out)
        checkTasks(home: home, out: &out)

        // cua-driver: the executor prefers it when present — but only a
        // binary whose signature + notarization verify as CUA's.
        if let bin = CuaDriver.binary() {
            if let v = try? CuaInstaller.verify() {
                out.append(Item(.ok, "cua-driver", "\(bin) — \(v.detail)"))
            } else {
                out.append(Item(.fail, "cua-driver",
                    "\(bin) failed signature/notarization checks — reinstall via "
                    + "`s1 setup --install-cua`; s1 falls back to CGEvent meanwhile"))
            }
        } else {
            out.append(Item(.warn, "cua-driver",
                "not installed — s1 falls back to CGEvent; `s1 setup --install-cua` "
                + "or the in-app onboarding installs the official driver"))
        }

        // sandbox-runtime: only meaningful when enabled.
        let cfg = S1Config.load(from: home + "/config.json")
        if Sandbox.enabled(cfg: cfg) {
            if let srt = Sandbox.srtBinary() {
                out.append(Item(.ok, "sandbox-runtime (srt)", srt))
            } else {
                out.append(Item(.fail, "sandbox-runtime (srt)",
                                "sandbox is \"srt\" but srt isn't installed — \(Sandbox.installHint)"))
            }
            let srtFile = home + "/srt-settings.json"
            if fm.fileExists(atPath: srtFile) {
                if let d = try? Data(contentsOf: URL(fileURLWithPath: srtFile)),
                   (try? JSONSerialization.jsonObject(with: d)) is [String: Any] {
                    out.append(Item(.ok, "srt-settings.json", "valid JSON"))
                } else {
                    out.append(Item(.fail, "srt-settings.json", "not valid JSON"))
                }
            } else {
                out.append(Item(.warn, "srt-settings.json",
                                "missing — a default policy is written on first sandboxed run"))
            }
        } else {
            out.append(Item(.ok, "sandbox-runtime",
                            "off (default) — set sandbox:\"srt\" in config.json to enable"))
        }

        return out
    }

    static func checkConfig(home: String, out: inout [Item]) {
        let p = home + "/config.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            out.append(Item(.warn, "config.json",
                            "missing — defaults apply; `s1 setup` writes one"))
            return
        }
        guard (try? JSONDecoder().decode(S1Config.self, from: d)) != nil else {
            out.append(Item(.fail, "config.json", "doesn't parse — fix or delete it"))
            return
        }
        // Unknown top-level keys: almost always a typo'd knob.
        if let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] {
            let unknown = obj.keys.filter { !knownConfigKeys.contains($0) }
            for k in unknown.sorted() {
                out.append(Item(.warn, "config.json",
                                "unknown key \"\(k)\" — s1 ignores it"))
            }
        }
        // Sandbox value sanity.
        if let s = S1Config.load(from: p).sandbox,
           !["srt", "off", "none", ""].contains(s) {
            out.append(Item(.warn, "config.json",
                            "sandbox \"\(s)\" not recognized — use \"srt\" or \"off\""))
        }
        out.append(Item(.ok, "config.json", "valid"))
    }

    /// Providers + role assignments — structure only, no network (the
    /// app and `s1 providers` check live). A role that can't resolve is a
    /// warning: s1 still runs, that role just sits idle.
    static func checkModels(_ cfg: S1Config, secret: Models.Secret, out: inout [Item]) {
        var seen = Set<String>()
        for entry in cfg.providers ?? [] {
            guard seen.insert(entry.id).inserted else {
                out.append(Item(.warn, "providers", "“\(entry.id)” is listed twice"))
                continue
            }
            if let t = entry.template, ProviderCatalog.template(t) == nil {
                out.append(Item(.warn, "providers", "“\(entry.id)”: unknown template “\(t)”"))
            }
            guard let p = Models.provider(entry.id, config: cfg) else { continue }
            if p.kind == .custom, p.base(.chat) == nil, p.base(.systemOne) == nil {
                out.append(Item(.fail, "provider \(p.id)", "custom server without a URL"))
            } else if p.needsKey, (secret(p) ?? "").isEmpty {
                out.append(Item(.warn, "provider \(p.id)", "no API key — `s1 connect \(p.id)`"))
            } else {
                out.append(Item(.ok, "provider \(p.id)", p.needsKey ? "key in Keychain" : "no key needed"))
            }
        }
        for (name, value) in (cfg.models ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard let role = ModelRole(rawValue: name) else {
                out.append(Item(.warn, "models", "unknown role “\(name)” — roles: \(ModelRole.allCases.map(\.rawValue).joined(separator: ", "))"))
                continue
            }
            guard ModelRef(value) != nil else {
                out.append(Item(.warn, "models.\(name)", "“\(value)” isn't provider/model"))
                continue
            }
            switch Models.resolve(role, config: cfg, env: [:], secret: secret) {
            case .success(let r)?: out.append(Item(.ok, "models.\(name)", "\(r.ref)"))
            case .failure(let why)?: out.append(Item(.warn, "models.\(name)", "\(value) — \(why), role idle"))
            case nil: break
            }
        }
        if cfg.models?.isEmpty ?? true {
            out.append(Item(.ok, "models", "none assigned — grammar only (`s1 connect` adds a provider)"))
        }
    }

    static func checkSnippets(home: String, out: inout [Item]) {
        let p = home + "/snippets.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            out.append(Item(.ok, "snippets.json",
                            "not customized — \(Snippets.defaults.count) builtin snippets"))
            return
        }
        guard let list = try? JSONDecoder().decode([Snippet].self, from: d) else {
            out.append(Item(.fail, "snippets.json", "doesn't parse"))
            return
        }
        var seen = Set<String>()
        var issues = 0
        for s in list {
            if s.keyword.trimmingCharacters(in: .whitespaces).isEmpty {
                issues += 1; out.append(Item(.warn, "snippets.json", "a snippet has an empty keyword"))
            } else if !seen.insert(s.keyword.lowercased()).inserted {
                issues += 1
                out.append(Item(.warn, "snippets.json", "duplicate keyword \"\(s.keyword)\""))
            }
            if s.text.isEmpty {
                issues += 1
                out.append(Item(.warn, "snippets.json", "\"\(s.keyword)\" has empty text"))
            }
        }
        out.append(Item(issues == 0 ? .ok : .warn, "snippets.json",
                        "\(list.count) snippets\(issues == 0 ? "" : ", \(issues) issue\(issues == 1 ? "" : "s")")"))
    }

    static func checkConvert(home: String, out: inout [Item]) {
        let p = home + "/convert.json"
        guard let d = try? Data(contentsOf: URL(fileURLWithPath: p)) else {
            out.append(Item(.ok, "convert.json", "not customized — builtin unit/currency tables"))
            return
        }
        guard let ext = try? JSONDecoder().decode(Convert.Extensions.self, from: d) else {
            out.append(Item(.fail, "convert.json", "doesn't parse — expected {\"units\":{…},\"currencies\":{…}}"))
            return
        }
        let issues = Convert.validateExtensions(ext)
        for i in issues { out.append(Item(.warn, "convert.json", i)) }
        let n = (ext.units?.count ?? 0) + (ext.currencies?.count ?? 0)
        out.append(Item(issues.isEmpty ? .ok : .warn, "convert.json", "\(n) custom aliases"))
    }

    static func checkSkills(home: String, out: inout [Item]) {
        let dir = URL(fileURLWithPath: home + "/skills", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: nil)) ?? []
        let jsons = files.filter { $0.pathExtension == "json" }
        guard !jsons.isEmpty else {
            out.append(Item(.ok, "skills", "none saved yet — say \"save that as a skill called …\""))
            return
        }
        var bad = 0
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        for f in jsons {
            if let s = try? dec.decode(Skill.self, from: Data(contentsOf: f)) {
                if s.steps.isEmpty {
                    bad += 1
                    out.append(Item(.warn, "skills/\(f.lastPathComponent)",
                                    "skill \"\(s.name)\" has no steps — it can't run"))
                }
            } else {
                bad += 1
                out.append(Item(.fail, "skills/\(f.lastPathComponent)", "doesn't parse"))
            }
        }
        out.append(Item(bad == 0 ? .ok : .warn, "skills",
                        "\(jsons.count) saved skill\(jsons.count == 1 ? "" : "s")"))
    }

    static func checkMemory(home: String, out: inout [Item]) {
        let p = home + "/memory.md"
        let facts = Memory.facts(at: URL(fileURLWithPath: p))
        let dir = home + "/memory"
        let topics = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".md") } ?? []
        if !FileManager.default.fileExists(atPath: p), topics.isEmpty {
            out.append(Item(.ok, "memory", "empty — \"remember that …\" stores facts"))
            return
        }
        out.append(Item(.ok, "memory.md", "\(facts.count) fact\(facts.count == 1 ? "" : "s")"
            + (topics.isEmpty ? "" : " + \(topics.count) topic file\(topics.count == 1 ? "" : "s")")))
        // Index sanity: a stale/missing index block means hand-edits
        // dropped it — the next topic write regenerates it.
        if let s = try? String(contentsOfFile: p, encoding: .utf8),
           !topics.isEmpty, !s.contains(Memory.indexStart) {
            out.append(Item(.warn, "memory.md",
                            "index block missing — run `s1 doctor --fix` or add a topic fact to regenerate"))
        }
    }

    static func checkTasks(home: String, out: inout [Item]) {
        let dir = home + "/tasks"
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir))?
            .filter { $0.hasSuffix(".txt") } ?? []
        var empty = 0
        for f in files where ((try? String(contentsOfFile: dir + "/" + f, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) { empty += 1 }
        out.append(Item(empty == 0 ? .ok : .warn, "tasks",
                        files.isEmpty ? "none — \"list my tasks\" starts one"
                            : "\(files.count) file\(files.count == 1 ? "" : "s")"
                            + (empty == 0 ? "" : ", \(empty) empty")))
    }
}
