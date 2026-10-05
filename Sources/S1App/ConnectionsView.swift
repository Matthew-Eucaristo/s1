import SwiftUI
import S1Core

/// One place to wire every brain: pick a provider card, paste its key
/// once, pick models per role — the detail sections below stay for
/// custom endpoints. API keys go straight to the Keychain and are
/// never shown back.
@available(macOS 26, *)
struct ConnectionsView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
                decisionStatus
                Section {
                    ForEach(Providers.families(), id: \.id) { fam in
                        ProviderRow(model: model, fam: fam)
                    }
                } header: {
                    Text("Providers")
                } footer: {
                    Text("Connect applies the provider's models to every role it covers (S1 = decision judge, S2 = reasoning, STT/TTS = speech). One API key unlocks the whole card — paste it once. Any OpenAI-compatible endpoint works, including every model on OpenRouter.")
                }
                Section {
                    presetMenu(role: .decision) { model.decisionBase = $0; model.decisionModel = $1 }
                    TextField("Server", text: $model.decisionBase)
                    TextField("Model (empty = off)", text: $model.decisionModel, prompt: Text(Endpoints.defaultDecisionModel))
                    KeyRow(model: model, role: .decision)
                    TestRow(model: model, role: .decision,
                            watch: model.decisionBase + "|" + model.decisionModel)
                } header: {
                    Text("S1 · Decision model")
                } footer: {
                    Text("Default: TypeSafe Jev (get a key at typesafe.ai). Liquid d1 (console.liquid.ai, `liquid_…` key) and Cloudflare Clef / Clef Flash (API token; replace <ACCOUNT_ID>) also see a screenshot of the window. Typed yes/no · choice · score with probabilities (System One API). Judges every proposed step against the goal, the screen, and the run so far — a low score sends the step to S2 instead of acting. It can only add caution; the safety gate still decides.")
                }
                Section {
                    presetMenu(role: .s2) { model.s2Base = $0; model.s2Model = $1 }
                    TextField("Base URL", text: $model.s2Base)
                    TextField("Model", text: $model.s2Model)
                    ModelStatusRow(status: model.s2Status)
                    KeyRow(model: model, role: .s2)
                    TestRow(model: model, role: .s2,
                            watch: model.s2Base + "|" + model.s2Model)
                } header: {
                    Text("S2 · Reasoning LLM")
                } footer: {
                    Text("Recommended: OpenCode Go subscription key + DeepSeek V4.1 Flash. Any OpenAI-compatible /v1/chat/completions server works. Hard steps always escalate to S2 — that isn't optional, it's the safety design. Local models are optional and not recommended.")
                }
                UsageSection(model: model)
                ModelLibrarySection(model: model)
                Section {
                } footer: {
                    Text("API keys live in the login Keychain (\(SecretStore.defaultService)), never in ~/.s1/config.json, and are never shown again after saving.")
                }
        }
        .formStyle(.grouped)
    }

    /// The judge is optional caution: missing just means "no second
    /// opinion" — one button fixes it, nothing nags elsewhere.
    @ViewBuilder
    private var decisionStatus: some View {
        let _ = model.installedModels
        if !model.decisionModel.isEmpty && model.decisionIsLocal && !model.decisionReady {
            Section {
                HStack {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Decision judge \(model.decisionModel) isn't downloaded")
                        Text("s1 runs fine without it; with it, risky or off-goal steps go to S2 instead of acting.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let p = model.pullProgress[model.decisionModel] {
                        Text(p).font(.caption).lineLimit(1).truncationMode(.head).frame(maxWidth: 140)
                    } else if model.ollamaPresent {
                        Button("Download") {
                            model.pullModel(model.decisionModel, decision: true)
                        }
                    } else {
                        Text(ModelPull.installHint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
    }

    /// Pill labels per role id.
    static func roleTag(_ role: String) -> String {
        switch role {
        case "decision": return "S1"
        case "vlm": return "Vision"
        case "grounder": return "Ground"
        case "s2": return "S2"
        case "stt": return "STT"
        case "tts": return "TTS"
        default: return role.uppercased()
        }
    }

    /// Presets come from `~/.s1/providers.json` ∪ builtins — the user can
    /// add their own endpoint to the file and it shows up in this menu.
    func presetMenu(role: ModelRole,
                            apply: @escaping (String, String) -> Void) -> some View {
        Menu("Preset") {
            ForEach(Providers.presets(role: role), id: \.id) { p in
                Button(p.note.map { "\(p.label) — \($0)" } ?? p.label) {
                    apply(p.base, p.model)
                }
            }
            Divider()
            Button("Edit presets (providers.json)…") {
                Providers.ensureFile()
                NSWorkspace.shared.open(Providers.path)
            }
        }
        .fixedSize()
    }
}

/// One provider: capability pills, connect state, a single key field for
/// every role it covers, per-role model pickers, and an auto-test that
/// runs whenever a covered role is configured — on appear and on change.
@available(macOS 26, *)
struct ProviderRow: View {
    @Bindable var model: AppModel
    let fam: ProviderFamily
    @State private var draft = ""
    @State private var results: [ModelRole: String] = [:]
    @State private var testing = Set<ModelRole>()

    private var roles: [ModelRole] { fam.roles.compactMap(ModelRole.init(rawValue:)) }
    /// Local-only providers (e.g. an Ollama preset family) never need a
    /// key — the card skips the field instead of demanding credentials.
    private var needsKey: Bool { !fam.presets.allSatisfy { Endpoints.isLocal($0.base) } }
    private var connected: Bool { model.familyHasKey(fam) || !needsKey }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(fam.name)
                ForEach(fam.roles, id: \.self) { r in
                    Text(ConnectionsView.roleTag(r))
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if connected {
                    Label("connected", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.titleAndIcon)
                }
                Button("Connect") {
                    model.connect(fam)
                    autoTest()
                }
                .controlSize(.small)
            }
            if needsKey {
                HStack {
                    SecureField(connected ? "key saved in Keychain — paste to replace" : "API key",
                                text: $draft)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                    Button("Save") {
                        model.saveKey(draft, forFamily: fam); draft = ""
                        autoTest()
                    }
                    .controlSize(.small)
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            // Per-role model pick — presets this provider ships for that
            // role; picking one rewires the role and re-tests it.
            ForEach(roles, id: \.self) { r in
                HStack(spacing: 8) {
                    Text(ConnectionsView.roleTag(r.rawValue))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .leading)
                    Menu(currentModel(r)) {
                        ForEach(fam.presets.filter { $0.role == r.rawValue }, id: \.id) { p in
                            Button(p.model) { model.apply(p); autoTest(r) }
                        }
                    }
                    .controlSize(.small)
                    .font(.caption)
                    if testing.contains(r) {
                        ProgressView().controlSize(.mini)
                    } else if let res = results[r] {
                        Text(res).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                }
            }
        }
        .padding(.vertical, 2)
        .task { autoTest() }
    }

    private func currentModel(_ r: ModelRole) -> String {
        let m = switch r {
        case .decision: model.decisionModel
        case .s2: model.s2Model
        case .vlm: model.vlmModel
        case .grounder: model.grounderModel
        case .stt: model.sttModel
        case .tts: model.ttsModel
        }
        return m.isEmpty ? "pick a model" : m
    }

    /// First-open and post-change probe — only roles that are configured
    /// AND credentialed (or local) fire a request.
    private func autoTest(_ only: ModelRole? = nil) {
        for r in roles where only == nil || r == only {
            guard model.roleReady(r), !testing.contains(r) else { continue }
            testing.insert(r)
            Task {
                results[r] = await model.testConnection(r)
                testing.remove(r)
            }
        }
    }
}

@available(macOS 26, *)
struct KeyRow: View {
    @Bindable var model: AppModel
    let role: ModelRole
    @State private var draft = ""

    var body: some View {
        // keyRevision makes the row re-read Keychain state after save/remove.
        let saved = model.keyRevision >= 0 && model.hasKey(role)
        LabeledContent("API key") {
            HStack {
                SecureField(saved ? "saved in Keychain — type to replace" : "paste API key",
                            text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { model.saveKey(draft, for: role); draft = "" }
                    .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if saved {
                    Button("Remove", role: .destructive) { model.removeKey(for: role) }
                }
            }
        }
    }
}

@available(macOS 26, *)
struct TestRow: View {
    @Bindable var model: AppModel
    let role: ModelRole
    /// Endpoint fingerprint (base+model) — changing it re-tests when the
    /// role has credentials, so a model pick or Connect is verified live.
    var watch = ""
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        HStack {
            Button(testing ? "Testing…" : "Test connection") {
                run()
            }
            .disabled(testing)
            Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
        .onAppear { auto() }
        .onChange(of: watch) { auto() }
    }

    private func run() {
        testing = true
        Task {
            result = await model.testConnection(role)
            testing = false
        }
    }

    /// First-open and post-change probe — skips unconfigured or
    /// uncredentialed roles rather than spamming "needs key".
    private func auto() {
        guard model.roleReady(role), !testing else { return }
        run()
    }
}

/// Metered calls per role/model — numbers only, from ~/.s1/usage.jsonl.
@available(macOS 26, *)
private struct UsageSection: View {
    @Bindable var model: AppModel
    @State private var rows: [UsageLog.Summary] = []

    var body: some View {
        Section {
            if rows.isEmpty {
                Text("No model calls yet.").foregroundStyle(.secondary)
            }
            ForEach(rows, id: \.self) { r in
                LabeledContent {
                    Text(Self.line(r)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                } label: {
                    Text("\(r.role) · \(r.model)")
                }
            }
            Button("Refresh") { rows = model.usageSummary() }
        } header: {
            Text("Usage · last 30 days")
        } footer: {
            Text("Tokens and prompt-cache hits as each provider reports them. Full log: s1 usage, or ~/.s1/usage.jsonl.")
        }
        .onAppear { rows = model.usageSummary() }
    }

    static func line(_ r: UsageLog.Summary) -> String {
        var s = "\(r.calls) calls · \(r.input) in / \(r.output) out"
        if let h = r.cacheHitRate, r.cached > 0 { s += " · cache \(Int(h * 100))%" }
        if r.failures > 0 { s += " · \(r.failures) failed" }
        return s + " · \(r.avgMs) ms avg"
    }
}
