import Foundation
import Testing
@testable import S1Core

// MARK: - providers + roles

private let noKeys: Models.Secret = { _ in nil }
private let allKeys: Models.Secret = { _ in "k" }

@Test func modelRefSplitsOnFirstSlashOnly() {
    let r = ModelRef("openrouter/anthropic/claude-sonnet-4.5")
    #expect(r?.provider == "openrouter")
    #expect(r?.model == "anthropic/claude-sonnet-4.5")
    #expect(r?.description == "openrouter/anthropic/claude-sonnet-4.5")
    #expect(ModelRef("off") == nil)
    #expect(ModelRef("/x") == nil)
    #expect(ModelRef("groq/") == nil)
}

@Test func catalogIsInternallyConsistent() {
    let ids = ProviderCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)
    for t in ProviderCatalog.all {
        if t.kind == .cloud { #expect(t.keyURL != nil, "\(t.id) needs a key URL") }
        let p = Provider(template: t, config: ProviderConfig(id: t.id, values: ["account": "acct"]))
        for m in t.models {
            // Recommendations are a subset of what the model can do…
            for r in m.recommended ?? [] { #expect(m.roles.contains(r), "\(t.id)/\(m.id) recommends \(r)") }
            // …and the provider actually speaks every role's protocol.
            for r in m.roles { #expect(p.supports(r), "\(t.id) can't serve \(r) for \(m.id)") }
        }
        // At most one recommended model per role, so auto-fill is unambiguous.
        for r in ModelRole.allCases {
            #expect(t.models.filter { $0.isRecommended(for: r) }.count <= 1, "\(t.id) recommends two \(r)s")
        }
    }
}

@Test func placeholdersFillFromInstanceValuesAndModel() {
    let t = ProviderCatalog.template("cloudflare")!
    let bare = Provider(template: t, config: ProviderConfig(id: "cloudflare"))
    #expect(bare.base(.chat) == nil)                       // account still missing
    let p = Provider(template: t, config: ProviderConfig(id: "cloudflare", values: ["account": "abc"]))
    #expect(p.base(.chat) == "https://api.cloudflare.com/client/v4/accounts/abc/ai/v1")
    #expect(p.base(.systemOne, model: "clef-flash")
            == "https://api.cloudflare.com/client/v4/accounts/abc/ai/run/@cf/cloudflare/clef-flash")
    #expect(p.base(.systemOne) == nil)                     // {model} needs a model
    // Audio rides the chat base unless overridden.
    let groq = Provider(template: ProviderCatalog.template("groq")!, config: ProviderConfig(id: "groq"))
    #expect(groq.base(.audio) == "https://api.groq.com/openai/v1")
}

@Test func connectFillsOnlyEmptyAutoRoles() {
    var cfg = S1Config()
    let took = Models.connect(ProviderConfig(id: "groq"), in: &cfg)
    // Groq recommends reasoner, transcribe and speak — but speech stays
    // on-device until chosen, so only the reasoner is taken.
    #expect(took == [.reasoner])
    #expect(cfg.models?["reasoner"] == "groq/meta-llama/llama-4-scout-17b-16e-instruct")
    #expect(cfg.models?["transcribe"] == nil && cfg.models?["speak"] == nil)
    // A second provider never steals a role that's already set.
    let took2 = Models.connect(ProviderConfig(id: "opencode"), in: &cfg)
    #expect(took2.isEmpty)
    #expect(cfg.models?["reasoner"] == "groq/meta-llama/llama-4-scout-17b-16e-instruct")
    // …but fills one that's empty.
    #expect(Models.connect(ProviderConfig(id: "typesafe"), in: &cfg) == [.judge])
    #expect(cfg.providers?.map(\.id) == ["groq", "opencode", "typesafe"])
    // Reconnecting updates in place, keeping order.
    Models.connect(ProviderConfig(id: "groq", name: "Groq (work)"), in: &cfg)
    #expect(cfg.providers?.map(\.id) == ["groq", "opencode", "typesafe"])
    #expect(cfg.providers?.first?.name == "Groq (work)")
}

@Test func disconnectClearsEveryRoleOnThatProvider() {
    var cfg = S1Config()
    Models.connect(ProviderConfig(id: "groq"), in: &cfg)
    Models.connect(ProviderConfig(id: "typesafe"), in: &cfg)
    Models.assign(.transcribe, ModelRef("groq/whisper-large-v3-turbo"), in: &cfg)
    Models.disconnect("groq", in: &cfg)
    #expect(cfg.providers?.map(\.id) == ["typesafe"])
    #expect(cfg.models == ["judge": "typesafe/jev-latest"])
    Models.disconnect("typesafe", in: &cfg)
    #expect(cfg.providers == nil && cfg.models == nil)
}

@Test func assigningASpeakModelCarriesItsVoice() {
    var cfg = S1Config()
    Models.connect(ProviderConfig(id: "openai"), in: &cfg)
    Models.assign(.speak, ModelRef("openai/gpt-4o-mini-tts"), in: &cfg)
    #expect(cfg.cloudVoice == "alloy")
}

@Test func resolveExplainsWhyARoleIsIdle() {
    var cfg = S1Config()
    #expect(Models.resolve(.reasoner, config: cfg, env: [:], secret: allKeys) == nil)   // off
    Models.assign(.reasoner, ModelRef("nowhere/x"), in: &cfg)
    if case .failure(.unknownProvider("nowhere"))? = Models.resolve(.reasoner, config: cfg, env: [:], secret: allKeys) {} else {
        Issue.record("expected unknownProvider")
    }
    Models.connect(ProviderConfig(id: "opencode"), in: &cfg)
    Models.assign(.reasoner, ModelRef("opencode/deepseek-v4.1-flash"), in: &cfg)
    if case .failure(.missingKey)? = Models.resolve(.reasoner, config: cfg, env: [:], secret: noKeys) {} else {
        Issue.record("expected missingKey")
    }
    let ep = Models.endpoint(.reasoner, config: cfg, env: [:], secret: allKeys)
    #expect(ep?.baseURL == "https://opencode.ai/zen/go/v1")
    #expect(ep?.model == "deepseek-v4.1-flash")
    #expect(ep?.apiKey == "k")
    #expect(ep?.numCtx == 8192)
    // A judge-only provider can't take a chat role.
    Models.connect(ProviderConfig(id: "typesafe"), in: &cfg)
    Models.assign(.reasoner, ModelRef("typesafe/jev-latest"), in: &cfg)
    if case .failure(.unsupported)? = Models.resolve(.reasoner, config: cfg, env: [:], secret: allKeys) {} else {
        Issue.record("expected unsupported")
    }
}

@Test func localProvidersNeedNoKeyAndRemoteOllamaWorks() {
    var cfg = S1Config()
    Models.connect(ProviderConfig(id: "ollama"), in: &cfg)
    #expect(cfg.models == nil)                              // nothing pulled is assumed
    Models.assign(.judge, ModelRef("ollama/nimble"), in: &cfg)
    let judge = Models.endpoint(.judge, config: cfg, env: [:], secret: noKeys)
    #expect(judge?.baseURL == "http://localhost:11434")
    #expect(judge?.apiKey == nil)
    // A second Ollama on another Mac: same template, its own id and URLs.
    let id = Models.newID(for: "ollama", config: cfg)
    #expect(id == "ollama-2")
    Models.connect(ProviderConfig(id: id, template: "ollama", chat: "http://studio.local:11434/v1",
                                  systemOne: "http://studio.local:11434"), in: &cfg)
    Models.assign(.reasoner, ModelRef(provider: id, model: "qwen3:8b"), in: &cfg)
    #expect(Models.endpoint(.reasoner, config: cfg, env: [:], secret: noKeys)?.baseURL == "http://studio.local:11434/v1")
}

@Test func envOverridesAssignmentsAndKeys() {
    var cfg = S1Config()
    Models.connect(ProviderConfig(id: "opencode"), in: &cfg)
    // S1_<ROLE> beats the file; "off" turns a role off.
    let env = ["S1_REASONER": "groq/llama-x"]
    #expect(Models.assignment(.reasoner, config: cfg, env: env)?.description == "groq/llama-x")
    #expect(Models.assignment(.reasoner, config: cfg, env: ["S1_REASONER": "off"]) == nil)
    // Catalog providers resolve without being connected (scripts / CI).
    #expect(Models.endpoint(.reasoner, config: cfg, env: env, secret: allKeys)?.baseURL
            == "https://api.groq.com/openai/v1")
    #expect(Provider(template: ProviderCatalog.template("groq")!, config: ProviderConfig(id: "groq")).keyEnv
            == "S1_GROQ_KEY")
    #expect(Provider(template: ProviderCatalog.template("ollama")!, config: ProviderConfig(id: "ollama-2")).keyEnv
            == "S1_OLLAMA_2_KEY")
}

@Test func customServersAreExplicitOnly() {
    var cfg = S1Config()
    // "custom" is a template, never a provider by itself.
    #expect(Models.provider("custom", config: cfg) == nil)
    Models.connect(ProviderConfig(id: Models.slug("LM Box!"), template: "custom", name: "LM Box",
                                  chat: "http://10.0.0.5:8000/v1"), in: &cfg)
    let p = Models.provider("lm-box", config: cfg)
    #expect(p?.name == "LM Box")
    #expect(p?.needsKey == false)
    #expect(p?.supports(.reasoner) == true && p?.supports(.transcribe) == true)
    #expect(p?.roles == [.reasoner, .transcribe, .speak])
    #expect(p?.supports(.judge) == false)                   // no System One URL given
}

@Test func configRoundTripsProvidersAndModels() throws {
    let path = NSTemporaryDirectory() + "s1cfg-\(UUID().uuidString).json"
    defer { try? FileManager.default.removeItem(atPath: path) }
    try S1Config.update(at: path) { c in
        Models.connect(ProviderConfig(id: "cloudflare", values: ["account": "abc"]), in: &c)
        c.locale = "id-ID"
    }
    let back = S1Config.load(from: path)
    #expect(back.providers?.first?.values?["account"] == "abc")
    #expect(back.models?["judge"] == "cloudflare/clef-flash")
    #expect(back.models?["reasoner"] == "cloudflare/@cf/meta/llama-4-scout-17b-16e-instruct")
    #expect(back.locale == "id-ID")
    // Slashes stay readable in the file.
    #expect(try String(contentsOfFile: path, encoding: .utf8).contains("\"cloudflare/clef-flash\""))
}

@Test func brainIsGrammarUntilModelsAreAssigned() {
    let none = Brain.policy(config: S1Config(), env: [:])
    #expect(none is AXPolicy)
    #expect(Brain.reasoner(config: S1Config(), env: [:]) == nil)
    var cfg = S1Config()
    Models.connect(ProviderConfig(id: "ollama"), in: &cfg)
    Models.assign(.judge, ModelRef("ollama/nimble"), in: &cfg)
    #expect(Brain.policy(config: cfg, env: [:]) is JudgedPolicy)
    #expect(Brain.describe(config: cfg, env: [:]) == "S1 grammar + judge nimble · S2 off")
}

@Test func screenGoesToWhicheverBrainCanSee() {
    var cfg = S1Config()
    Models.connect(ProviderConfig(id: "ollama"), in: &cfg)
    // Text-only judge and reasoner: accessibility tree only.
    Models.assign(.judge, ModelRef("ollama/nimble"), in: &cfg)
    Models.assign(.reasoner, ModelRef("ollama/qwen3:8b"), in: &cfg)
    #expect(!Models.seesScreen(.judge, config: cfg, env: [:]))
    #expect(!Models.seesScreen(.reasoner, config: cfg, env: [:]))
    #expect((Brain.reasoner(config: cfg, env: [:]) as? LLMReasoner)?.vision == false)
    // S1 can't see, S2 can: the screen goes with each escalation.
    Models.assign(.reasoner, ModelRef("ollama/qwen3-vl:8b"), in: &cfg)
    #expect(Models.seesScreen(.reasoner, config: cfg, env: [:]))
    #expect(Brain.reasoner(config: cfg, env: [:])?.wantsScreenshot == true)
    // A judge that sees gets the screen when it looks — not a capture every step.
    Models.assign(.judge, ModelRef("ollama/clef-flash"), in: &cfg)
    #expect((Brain.policy(config: cfg, env: [:]) as? JudgedPolicy)?.judge.acceptsImages == true)
    #expect(!Brain.policy(config: cfg, env: [:]).wantsScreenshot)
    #expect(Brain.describe(config: cfg, env: [:]).contains("(sees screen)"))
    // One switch turns screen sharing off for both.
    cfg.vision = false
    #expect(!Models.seesScreen(.judge, config: cfg, env: [:]) && !Models.seesScreen(.reasoner, config: cfg, env: [:]))
    #expect((Brain.policy(config: cfg, env: [:]) as? JudgedPolicy)?.judge.acceptsImages == false)
    #expect(Brain.reasoner(config: cfg, env: [:])?.wantsScreenshot == false)
    cfg.vision = nil
    #expect(!Models.seesScreen(.reasoner, config: cfg, env: ["S1_VISION": "off"]))
}

@Test func visionGuessCoversModelsOutsideTheCatalog() {
    for m in ["qwen2.5vl:7b", "Qwen/Qwen3-VL-8B", "gpt-4o-mini", "anthropic/claude-sonnet-4.5",
              "google/gemini-2.5-pro", "llava:13b", "meta-llama/llama-4-maverick", "deepseek-v4-flash-vision-exp"] {
        #expect(Models.looksVisual(m), "\(m) should read images")
    }
    for m in ["qwen3:8b", "deepseek-v4.1-flash", "openai/gpt-oss-120b", "nimble", "devlin-7b"] {
        #expect(!Models.looksVisual(m), "\(m) should be text only")
    }
}

@Test func modelListParsesBothShapesAndMatchesTags() {
    let openai = Data(#"{"data":[{"id":"b"},{"id":"a"}]}"#.utf8)
    let ollama = Data(#"{"models":[{"name":"nimble:latest"}]}"#.utf8)
    #expect(ModelList.parse(openai) == ["a", "b"])
    #expect(ModelList.parse(ollama) == ["nimble:latest"])
    #expect(ModelList.parse(Data("nope".utf8)).isEmpty)
    #expect(ModelList.contains(["nimble:latest"], "nimble"))
    #expect(!ModelList.contains(["nimble:latest"], "tev1"))
}

@Test func doctorFlagsBrokenRolesAndProviders() {
    var cfg = S1Config()
    Models.connect(ProviderConfig(id: "opencode"), in: &cfg)
    cfg.models?["oracle"] = "opencode/x"
    cfg.models?["speak"] = "not-a-ref"
    var out: [Doctor.Item] = []
    Doctor.checkModels(cfg, secret: noKeys, out: &out)
    #expect(out.contains { $0.what == "provider opencode" && $0.level == .warn })   // no key
    #expect(out.contains { $0.what == "models" && $0.detail.contains("oracle") })
    #expect(out.contains { $0.what == "models.speak" && $0.detail.contains("provider/model") })
    #expect(out.contains { $0.what == "models.reasoner" && $0.detail.contains("no API key") })
}

// MARK: - run history

@Test func runHistoryReadsOutcomeFromMeta() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("s1hist-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let logger = try RunLogger(goal: "open Notes", root: root, config: [:])
    await logger.finish(RunReport(status: .done, steps: 2, runDir: logger.runDir.path, escalations: 0,
                                  summary: "Notes is open"))
    let runs = RunHistory.list(root: root)
    #expect(runs.count == 1)
    #expect(runs.first?.goal == "open Notes")
    #expect(runs.first?.ok == true)
    #expect(runs.first?.steps == 2)
    #expect(runs.first?.summary == "Notes is open")
    #expect(runs.first?.started != nil && runs.first?.finished != nil)
}
