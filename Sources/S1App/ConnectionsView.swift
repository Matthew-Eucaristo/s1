import SwiftUI
import S1Core

/// One place to wire every brain: S1 decision model, S1 vision + click
/// grounder, S2 LLM — base URL, model, and an API key that goes straight
/// to the Keychain (the field never shows a saved key back).
@available(macOS 26, *)
struct ConnectionsView: View {
    @Bindable var model: AppModel
    @State private var showVision = false

    var body: some View {
        Form {
                decisionStatus
                Section {
                    presetMenu(role: .decision) { model.decisionBase = $0; model.decisionModel = $1 }
                    TextField("Server", text: $model.decisionBase)
                    TextField("Model (empty = off)", text: $model.decisionModel, prompt: Text(Endpoints.defaultDecisionModel))
                    KeyRow(model: model, role: .decision)
                    TestRow(model: model, role: .decision)
                } header: {
                    Text("S1 · Decision model")
                } footer: {
                    Text("Default: TypeSafe Jev (get a key at typesafe.ai). Liquid d1 (console.liquid.ai, `liquid_…` key) and Cloudflare Clef / Clef Flash (API token; replace <ACCOUNT_ID>) also see a screenshot of the window. Typed yes/no · choice · score with probabilities (System One API). Judges every proposed step against the goal, the screen, and the run so far — a low score sends the step to S2 instead of acting. It can only add caution; the safety gate still decides.")
                }
                Section {
                    DisclosureGroup(isExpanded: $showVision) {
                        presetMenu(role: .vlm) { model.vlmBase = $0; model.vlmModel = $1 }
                        TextField("Base URL", text: $model.vlmBase)
                        TextField("Vision model (empty = off)", text: $model.vlmModel)
                        Toggle("Attach screenshots", isOn: $model.vlmScreenshot)
                        if !model.vlmModel.isEmpty { ModelStatusRow(status: model.vlmStatus) }
                        TextField("Click grounder (empty = VLM grounds)", text: $model.grounderModel)
                        KeyRow(model: model, role: .vlm)
                        TestRow(model: model, role: .vlm)
                    } label: {
                        LabeledContent("Advanced · S1 vision + click grounder",
                                       value: model.vlmModel.isEmpty ? "Off" : model.vlmModel)
                    }
                } footer: {
                    Text("Not needed for most commands: the AX grammar handles open/type/press/scroll and labeled buttons, S2 plans from the AX text, Jev judges. Turn on only for targets with no accessibility label (images, canvases, games). Reuses the S2 key on the same provider.")
                }
                Section {
                    presetMenu(role: .s2) { model.s2Base = $0; model.s2Model = $1 }
                    TextField("Base URL", text: $model.s2Base)
                    TextField("Model", text: $model.s2Model)
                    Toggle("Escalate to S2", isOn: $model.useS2)
                    ModelStatusRow(status: model.s2Status)
                    KeyRow(model: model, role: .s2)
                    TestRow(model: model, role: .s2)
                } header: {
                    Text("S2 · Reasoning LLM")
                } footer: {
                    Text("Recommended: OpenCode Go subscription key + DeepSeek V4.1 Flash. Any OpenAI-compatible /v1/chat/completions server works. Gets low-confidence and judge-vetoed steps. Local models are optional and not recommended.")
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
                            model.pullModel(model.decisionModel, vision: false, decision: true)
                        }
                    } else {
                        Text(ModelPull.installHint).font(.caption.monospaced()).textSelection(.enabled)
                    }
                }
            }
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
    @State private var result = ""
    @State private var testing = false

    var body: some View {
        HStack {
            Button(testing ? "Testing…" : "Test connection") {
                testing = true
                Task {
                    result = await model.testConnection(role)
                    testing = false
                }
            }
            .disabled(testing)
            Text(result).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }
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
