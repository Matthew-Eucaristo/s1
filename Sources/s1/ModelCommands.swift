import ArgumentParser
import Foundation
import S1Core

// Providers + role assignments from the terminal — the same model the
// app's Settings → Models pane edits, in the same ~/.s1/config.json.
//
//   s1 providers              what's connected, what can be added
//   s1 connect groq           key → Keychain, check it, fill empty roles
//   s1 use reasoner groq/openai/gpt-oss-120b
//   s1 models                 what each role can use
//   s1 disconnect groq

/// `--policy` → the S1 brain. `auto` is the grammar judged by your judge
/// model (the same `Brain` the app runs); `ax` is the grammar alone with
/// zero model calls.
func makePolicy(_ name: String) throws -> any Policy {
    switch name {
    case "auto": return Brain.policy()
    case "ax": return AXPolicy()
    default: throw ValidationError("unknown policy \(name) — use auto or ax")
    }
}

/// S2 for a CLI command: the assigned reasoner, unless `--no-s2`. Says why
/// when a reasoner is assigned but can't answer.
func cliReasoner(_ enabled: Bool) -> (any Reasoner)? {
    guard enabled else { return nil }
    if case .failure(let why)? = Models.resolve(.reasoner) {
        FileHandle.standardError.write(Data("s2 off: \(why)\n".utf8))
    }
    return Brain.reasoner()
}

/// Hidden prompt when interactive, one stdin line otherwise (pipes, CI).
func readSecret(_ prompt: String) -> String? {
    let raw: String?
    if isatty(STDIN_FILENO) != 0 {
        var buf = [CChar](repeating: 0, count: 4096)
        raw = readpassphrase(prompt, &buf, buf.count, 0).map { String(cString: $0) }
        buf.withUnsafeMutableBytes { _ = memset_s($0.baseAddress, $0.count, 0, $0.count) }
    } else {
        raw = readLine(strippingNewline: true)
    }
    let k = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return k.isEmpty ? nil : k
}

private func roleLabel(_ r: ModelRole) -> String {
    r.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
}

struct ProvidersCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "providers",
        abstract: "Connected providers (checked live) and the ones you can add.")

    func run() async throws {
        let cfg = S1Config.load()
        let connected = Models.connected(config: cfg)
        if connected.isEmpty {
            print("no providers connected — s1 runs on its grammar alone\n")
        } else {
            print("connected:")
            for p in connected {
                let outcome = await ProviderCheck.run(p, key: Models.keychain(p))
                let roles = Models.roles(of: p.id, config: cfg).map(\.rawValue)
                print("  \(outcome.ok ? "✓" : "✗") \(p.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(outcome.message)"
                      + (roles.isEmpty ? "" : " · \(roles.joined(separator: ", "))"))
            }
            print("")
        }
        print("available — `s1 connect <id>`:")
        let have = Set(connected.map { $0.template.id })
        for t in ProviderCatalog.all where !have.contains(t.id) || t.kind != .cloud {
            print("  \(t.id.padding(toLength: 12, withPad: " ", startingAt: 0)) \(t.summary)")
        }
    }
}

struct ConnectCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "connect",
        abstract: "Connect a provider: key into the Keychain, a live check, empty roles filled.",
        discussion: """
            s1 connect opencode                 prompts for the key (hidden)
            echo $KEY | s1 connect groq         key from stdin
            s1 connect cloudflare --account <id>
            s1 connect ollama --url http://studio.local:11434/v1
            s1 connect custom --name "LM Box" --url http://10.0.0.5:8000/v1
            """)
    @Argument(help: "Provider id from `s1 providers`.") var provider: String
    @Option(help: "Instance id when connecting a second copy (e.g. ollama-studio).") var id: String?
    @Option(help: "Display name (custom servers).") var name: String?
    @Option(help: "OpenAI-compatible base URL override (custom servers, a remote Ollama).") var url: String?
    @Option(help: "Cloudflare account id.") var account: String?
    @Flag(help: "Skip the live check.") var noCheck = false

    func run() async throws {
        guard let t = ProviderCatalog.template(provider) else {
            throw ValidationError("unknown provider \(provider) — `s1 providers` lists them")
        }
        var cfg = S1Config.load()
        let instance = id ?? (t.kind == .custom ? Models.slug(name ?? "custom") : provider)
        var entry = cfg.providers?.first { $0.id == instance }
            ?? ProviderConfig(id: instance, template: instance == t.id ? nil : t.id)
        if let name { entry.name = name }
        if let url { entry.chat = url }
        if let account { entry.values = (entry.values ?? [:]).merging(["account": account]) { $1 } }
        if t.kind == .custom, entry.chat == nil {
            throw ValidationError("a custom server needs --url")
        }
        for f in t.fields where (entry.values?[f.id] ?? "").isEmpty {
            throw ValidationError("\(t.name) needs --\(f.id) (\(f.label))")
        }

        let p = Provider(template: t, config: entry)
        if p.needsKey || t.kind == .custom {
            let have = SecretStore.has(account: p.keyAccount)
            let prompt = "\(p.name) API key\(have ? " (Enter keeps the saved one)" : t.kind == .custom ? " (optional)" : "")"
                + (t.keyURL.map { " — \($0)" } ?? "") + ": "
            if let key = readSecret(prompt) {
                try SecretStore.set(key, account: p.keyAccount)
            } else if p.needsKey && !have {
                throw ValidationError("\(p.name) needs an API key")
            }
        }
        if !noCheck {
            let outcome = await ProviderCheck.run(p, key: Models.keychain(p))
            print("\(outcome.ok ? "✓" : "✗") \(p.name): \(outcome.message)")
            if !outcome.ok { throw ExitCode(1) }
        }
        let took = Models.connect(entry, in: &cfg)
        try cfg.save()
        print("connected \(instance)")
        for r in took {
            print("  \(roleLabel(r)) → \(Models.assignment(r, config: cfg, env: [:])?.description ?? "")")
        }
        if took.isEmpty, Models.roles(of: instance, config: cfg).isEmpty {
            print("  assign it with `s1 use <role> \(instance)/<model>` — `s1 models` lists choices")
        }
    }
}

struct DisconnectCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "disconnect",
        abstract: "Remove a provider, its Keychain key, and every role pointed at it.")
    @Argument(help: "Provider instance id.") var provider: String

    func run() async throws {
        var cfg = S1Config.load()
        guard cfg.providers?.contains(where: { $0.id == provider }) == true else {
            throw ValidationError("\(provider) isn't connected")
        }
        let roles = Models.roles(of: provider, config: cfg)
        Models.disconnect(provider, in: &cfg)
        try cfg.save()
        SecretStore.delete(account: provider)
        print("disconnected \(provider)" + (roles.isEmpty ? "" : " — now off: \(roles.map(\.rawValue).joined(separator: ", "))"))
    }
}

struct UseCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "use",
        abstract: "Assign a model to a role — `s1 use reasoner groq/openai/gpt-oss-120b`. No args shows assignments.",
        discussion: "Roles: \(ModelRole.allCases.map(\.rawValue).joined(separator: ", ")). `off` clears a role (speech falls back to on-device).")
    @Argument(help: "Role.") var role: String?
    @Argument(help: "provider/model, or off.") var model: String?

    func run() async throws {
        guard let role else { return printAssignments() }
        guard let r = ModelRole(rawValue: role) else {
            throw ValidationError("roles: \(ModelRole.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        guard let model else { throw ValidationError("pass provider/model or off") }
        var cfg = S1Config.load()
        if model == "off" {
            Models.assign(r, nil, in: &cfg)
            try cfg.save()
            print("\(r.rawValue) → off")
            return
        }
        guard let ref = ModelRef(model) else { throw ValidationError("expected provider/model, got \(model)") }
        guard let p = Models.provider(ref.provider, config: cfg) else {
            throw ValidationError("\(ref.provider) isn't connected — `s1 connect \(ref.provider)` first")
        }
        guard p.supports(r) else { throw ValidationError("\(p.name) can't serve the \(r.rawValue) role") }
        Models.assign(r, ref, in: &cfg)
        try cfg.save()
        print("\(r.rawValue) → \(ref)")
        if case .failure(let why)? = Models.resolve(r, config: cfg) { print("  ⚠ \(why)") }
    }

    private func printAssignments() {
        let cfg = S1Config.load()
        for r in ModelRole.allCases {
            let line: String = switch Models.resolve(r, config: cfg) {
            case nil: r.api == .audio ? "on-device (Apple)" : "off"
            case .success(let res)?: res.ref.description + (Models.seesScreen(r, config: cfg) ? "  · sees the screen" : "")
            case .failure(let why)?: "\(Models.assignment(r, config: cfg)?.description ?? "") ⚠ \(why)"
            }
            print("\(roleLabel(r)) \(line)")
        }
    }
}

struct ModelsCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "models",
        abstract: "What each role can use: catalog picks and live lists from connected providers.")
    @Argument(help: "Only this provider.") var provider: String?

    func run() async throws {
        let cfg = S1Config.load()
        let providers = Models.connected(config: cfg).filter { provider == nil || $0.id == provider }
        if providers.isEmpty { print("no providers connected — `s1 providers`"); return }
        let installed = ModelPull.ollamaBinary() == nil ? [] : ModelPull.installed()
        for p in providers {
            print("\(p.name) (\(p.id))")
            for m in p.template.models {
                var tags = m.roles.map(\.rawValue).joined(separator: ",")
                if let rec = m.recommended, !rec.isEmpty { tags += " ★" }
                var extra = [m.size, m.note].compactMap { $0 }.joined(separator: " · ")
                if p.template.id == "ollama" { extra = (ModelPull.contains(installed, m.id) ? "installed · " : "") + extra }
                print("  \(p.id)/\(m.id)  [\(tags)]\(extra.isEmpty ? "" : "  \(extra)")")
            }
            if p.template.listsModels, case .success(let ids) = await ModelList.fetch(p, key: Models.keychain(p)) {
                let extra = ids.filter { id in !p.template.models.contains { $0.id == id } }
                if !extra.isEmpty {
                    print("  + \(extra.count) more: " + extra.prefix(12).joined(separator: ", ")
                          + (extra.count > 12 ? " …" : ""))
                }
            }
            print("")
        }
        print("assign: s1 use <role> <provider/model> · local downloads: s1 pull <model>")
    }
}

struct ConfigCmd: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "config",
        abstract: "Show the resolved setup — brain, roles, voice — and where to edit it.")

    func run() async throws {
        let exists = FileManager.default.fileExists(atPath: S1Config.path)
        print("config  \(S1Config.path)\(exists ? "" : " (not found — defaults)")")
        if exists, (try? Data(contentsOf: URL(fileURLWithPath: S1Config.path)))
            .flatMap({ try? JSONDecoder().decode(S1Config.self, from: $0) }) == nil {
            print("  ⚠ malformed JSON — defaults in use; fix it or `s1 doctor`")
        }
        print("brain   \(Brain.describe())\n")
        let cfg = S1Config.load()
        for r in ModelRole.allCases {
            switch Models.resolve(r, config: cfg) {
            case nil:
                print("\(roleLabel(r)) \(r.api == .audio ? "on-device (Apple)" : "off")")
            case .failure(let why)?:
                print("\(roleLabel(r)) \(Models.assignment(r, config: cfg)?.description ?? "") ✗ \(why)")
            case .success(let res)?:
                let sees = Models.seesScreen(r, config: cfg) ? "  · sees the screen" : ""
                print("\(roleLabel(r)) \(res.ref)  \((await ProviderCheck.role(res)).ok ? "✓" : "✗ unreachable")\(sees)")
            }
        }
        print("\nscreen sharing \(Models.visionEnabled(config: cfg) ? "on — models that can see get screenshots" : "off — accessibility tree only")")
        print("locale \(cfg.locale ?? SpokenLanguage.auto) · speak \(cfg.speak ?? true) · notch pill \(cfg.notchHUD ?? true)")
        let vocab = Vocabulary.assemble(custom: cfg.vocabulary ?? [])
        print("vocabulary \(cfg.vocabulary?.count ?? 0) custom + \(vocab.count - (cfg.vocabulary?.count ?? 0)) learned")
        print("\nenv overrides: S1_<ROLE>=provider/model|off (e.g. S1_REASONER), S1_<PROVIDER>_KEY (e.g. S1_GROQ_KEY), S1_VISION=off, S1_NUM_CTX")
    }
}
