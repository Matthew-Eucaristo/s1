import SwiftUI
import S1Core

/// Settings → Models. Two ideas only: **providers** (an account or a
/// server, one key each) and **roles** (what s1 uses a model for). Pick a
/// model per role from any connected provider; connecting one fills its
/// recommended roles for you.
@available(macOS 26, *)
struct ModelsSettings: View {
    @Bindable var model: AppModel
    @State private var adding = false
    @State private var detail: Provider?

    private var store: ModelStore { model.models }

    var body: some View {
        Form {
            Section {
                RoleRow(store: store, role: .judge) { adding = true }
                RoleRow(store: store, role: .reasoner) { adding = true }
            } header: {
                Text("System 1 and System 2")
            } footer: {
                FootNote("s1 always tries its built-in grammar first: instant, free and private. The Judge can only add caution; the safety gate decides either way.")
            }

            Section {
                Toggle(isOn: Binding(get: { store.visionEnabled }, set: { store.setVision($0) })) {
                    Text("Let models see the screen")
                    Text(store.visionSummary)
                }
            } footer: {
                FootNote("Screenshots go to the Judge when it can read images, otherwise to the Reasoner with each step it takes over. Pick models marked “Sees the screen” to use it.")
            }

            Section {
                if store.providers.isEmpty {
                    HStack(spacing: 12) {
                        Image(systemName: "cpu")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("No providers yet")
                            Text("Connect one to give s1 a Judge and a Reasoner.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }
                ForEach(store.providers) { p in
                    ProviderRow(store: store, provider: p) { detail = p }
                }
                Button {
                    adding = true
                } label: {
                    Label("Add Provider…", systemImage: "plus")
                }
            } header: {
                Text("Providers")
            } footer: {
                FootNote("Keys live in your login Keychain and are never shown again. The same setup drives the `s1` command line.")
            }

            UsageSection()
        }
        .formStyle(.grouped)
        .sheet(isPresented: $adding) { AddProviderSheet(model: model) }
        .sheet(item: $detail) { p in ProviderDetailSheet(store: store, provider: p) }
        .onAppear { store.checkAll() }
    }
}

// MARK: - roles

@available(macOS 26, *)
struct RoleRow: View {
    let store: ModelStore
    let role: ModelRole
    var addProvider: () -> Void

    var body: some View {
        LabeledContent {
            RoleMenu(store: store, role: role, addProvider: addProvider)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: role.symbol)
                    .foregroundStyle(.tint)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(role.title)
                    if let problem = store.problem(role) {
                        Label(problem.description, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    } else {
                        Text(role.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if store.assignment(role) != nil, role == .judge || role == .reasoner {
                        Label(store.canSee(role) ? "Sees the screen" : "Text only",
                              systemImage: store.canSee(role) ? "eye" : "text.alignleft")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(store.canSee(role) && store.visionEnabled ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    }
                }
            }
        }
    }
}

/// The model picker for one role: every connected provider that can fill
/// it, curated picks first, the provider's live list under "More".
@available(macOS 26, *)
struct RoleMenu: View {
    let store: ModelStore
    let role: ModelRole
    var addProvider: () -> Void

    var body: some View {
        let current = store.assignment(role)
        Menu {
            Toggle(isOn: binding(nil)) {
                Text(role.api == .audio ? "On this Mac (private)" : "Off")
            }
            ForEach(store.providers.filter { $0.supports(role) }) { p in
                Section(p.name) {
                    ForEach(p.models(for: role)) { m in
                        Toggle(isOn: binding(ModelRef(provider: p.id, model: m.id))) {
                            Text(m.displayName)
                            Text(Self.caption(m, role))
                        }
                    }
                    let more = store.moreModels(p, for: role)
                    if !more.isEmpty {
                        Menu(p.models(for: role).isEmpty ? "Models" : "More Models") {
                            ForEach(more, id: \.self) { id in
                                Toggle(id, isOn: binding(ModelRef(provider: p.id, model: id)))
                            }
                        }
                    }
                    if let current, current.provider == p.id, p.option(current.model) == nil,
                       !more.contains(current.model) {
                        Toggle(current.model, isOn: binding(current))
                    }
                }
            }
            Divider()
            Button("Add Provider…", action: addProvider)
        } label: {
            Text(store.title(for: role))
        }
        .fixedSize()
        .accessibilityLabel(Text(role.title))
    }

    static func caption(_ m: ModelOption, _ role: ModelRole) -> String {
        var parts: [String] = []
        if m.isRecommended(for: role) { parts.append(String(localized: "Recommended")) }
        if role == .judge || role == .reasoner, m.vision == true { parts.append(String(localized: "Sees the screen")) }
        if parts.isEmpty, let note = m.note { parts.append(note) }
        return parts.joined(separator: ", ")
    }

    private func binding(_ ref: ModelRef?) -> Binding<Bool> {
        Binding(get: { store.assignment(role) == ref },
                set: { on in if on { store.assign(role, ref) } })
    }
}

// MARK: - providers

@available(macOS 26, *)
private struct ProviderRow: View {
    let store: ModelStore
    let provider: Provider
    var open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                ProviderBadge(template: provider.template)
                VStack(alignment: .leading, spacing: 2) {
                    Text(provider.name)
                    Text(statusLine)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                }
                Spacer()
                if store.checks[provider.id] == .checking {
                    ProgressView().controlSize(.small)
                }
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows this provider's key, models and usage")
    }

    private var roles: [ModelRole] { Models.roles(of: provider.id, config: store.config) }

    private var statusLine: String {
        if case .failed(let why)? = store.checks[provider.id] { return why }
        if provider.needsKey && !store.hasKey(provider) { return String(localized: "No API key") }
        let used = roles.isEmpty
            ? String(localized: "Not used yet")
            : roles.map { $0.short }.formatted(.list(type: .and))
        return provider.isLocal ? String(localized: "On this Mac · \(used)") : used
    }

    private var statusColor: Color {
        if case .failed? = store.checks[provider.id] { return .red }
        if provider.needsKey && !store.hasKey(provider) { return .orange }
        return .secondary
    }
}

/// Add a provider: pick one, then a single form — key, URL or account
/// as that provider needs — verified live before anything is saved.
@available(macOS 26, *)
struct AddProviderSheet: View {
    let model: AppModel
    var onConnected: (([ModelRole]) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var picked: ProviderTemplate?

    var body: some View {
        Group {
            if let picked {
                ConnectForm(model: model, template: picked, back: { self.picked = nil }) { roles in
                    onConnected?(roles)
                    dismiss()
                }
                .transition(.push(from: .trailing))
            } else {
                chooser
                    .transition(.push(from: .leading))
            }
        }
        .frame(width: 520, height: 540)
        .clipped()
        .animation(.smooth(duration: 0.3), value: picked?.id)
    }

    private var chooser: some View {
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Text("Add a Provider").font(.title2.weight(.semibold))
                Text("One account or server, one key. s1 picks sensible models for you.")
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 24).padding(.bottom, 14)
            List {
                section("Recommended", ["typesafe", "opencode"])
                section("Cloud", ["openai", "openrouter", "groq", "gemini", "xai", "deepseek", "liquid", "cloudflare"])
                section("On Your Mac or Network", ["ollama", "lmstudio", "custom"])
            }
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(14)
        }
    }

    private func section(_ title: LocalizedStringKey, _ ids: [String]) -> some View {
        Section(title) {
            ForEach(ids.compactMap(ProviderCatalog.template), id: \.id) { t in
                let connected = t.kind == .cloud && model.models.providers.contains { $0.template.id == t.id }
                Button {
                    picked = t
                } label: {
                    HStack(spacing: 12) {
                        ProviderBadge(template: t, size: 32)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).font(.body.weight(.medium))
                            Text(t.summary).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if connected {
                            Text("Connected").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 3)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .disabled(connected)
            }
        }
    }
}

@available(macOS 26, *)
private struct ConnectForm: View {
    let model: AppModel
    let template: ProviderTemplate
    var back: () -> Void
    var done: ([ModelRole]) -> Void

    @State private var key = ""
    @State private var name = ""
    @State private var url = ""
    @State private var values: [String: String] = [:]
    @State private var working = false
    @State private var error: String?

    private var ready: Bool {
        if template.needsKey && key.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        if template.kind != .cloud && url.trimmingCharacters(in: .whitespaces).isEmpty { return false }
        return template.fields.allSatisfy { !(values[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                ProviderBadge(template: template, size: 52)
                Text(template.name).font(.title2.weight(.semibold))
                Text(template.summary).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.top, 28).padding(.horizontal, 32)

            Form {
                if template.kind == .custom {
                    TextField("Name", text: $name, prompt: Text("My Server"))
                }
                if template.kind != .cloud {
                    TextField("Server URL", text: $url, prompt: Text("http://localhost:8000/v1"))
                }
                ForEach(template.fields, id: \.id) { f in
                    TextField(f.label, text: Binding(get: { values[f.id] ?? "" }, set: { values[f.id] = $0 }),
                              prompt: f.placeholder.map { Text($0) })
                }
                if template.kind != .local {
                    SecureField(template.needsKey ? "API Key" : "API Key (optional)", text: $key,
                                prompt: template.keyHint.map { Text($0) })
                }
                if let link = template.keyURL, let u = URL(string: link) {
                    Link(destination: u) {
                        Label("Get a key from \(u.host ?? link)", systemImage: "arrow.up.forward.square")
                    }
                    .font(.callout)
                }
                if let error {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Button("Back", action: back).disabled(working)
                Spacer()
                if working { ProgressView().controlSize(.small).padding(.trailing, 6) }
                Button("Connect") { Task { await connect() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!ready || working)
            }
            .padding(14)
        }
        .onAppear {
            url = template.chat ?? ""
            if template.kind == .custom { url = "" }
        }
    }

    private func connect() async {
        working = true
        error = nil
        defer { working = false }
        let cfg = model.models.config
        let id: String = switch template.kind {
        case .custom: Models.newID(for: Models.slug(name.isEmpty ? "custom" : name), config: cfg)
        default: Models.newID(for: template.id, config: cfg)
        }
        var entry = ProviderConfig(id: id, template: id == template.id ? nil : template.id)
        if template.kind == .custom { entry.name = name.isEmpty ? nil : name }
        let u = url.trimmingCharacters(in: .whitespaces)
        if template.kind != .cloud, u != template.chat {
            entry.chat = u
            // A remote Ollama answers System One at the root of the same host.
            if template.id == "ollama", u.hasSuffix("/v1") { entry.systemOne = String(u.dropLast(3)) }
        }
        if !values.isEmpty { entry.values = values.mapValues { $0.trimmingCharacters(in: .whitespaces) } }
        switch await model.models.connect(entry, key: key) {
        case .success(let roles):
            let names = roles.map { $0.short }.formatted(.list(type: .and))
            model.show(roles.isEmpty ? String(localized: "\(template.name) connected.")
                                     : String(localized: "\(template.name) connected — now your \(names)."))
            done(roles)
        case .failure(let f):
            error = template.id == "ollama" && f.message == "server unreachable"
                ? String(localized: "Ollama isn't running. Open the Ollama app, or install it with `brew install --cask ollama`.")
                : f.message
        }
    }
}

/// One provider up close: its key, server, what it's used for, and its
/// models — with one-tap downloads for Ollama.
@available(macOS 26, *)
private struct ProviderDetailSheet: View {
    let store: ModelStore
    let provider: Provider
    @Environment(\.dismiss) private var dismiss
    @State private var newKey = ""
    @State private var replacing = false
    @State private var confirmRemove = false
    @State private var serverURL = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                ProviderBadge(template: provider.template, size: 44)
                VStack(alignment: .leading, spacing: 3) {
                    Text(provider.name).font(.title3.weight(.semibold))
                    checkLine
                }
                Spacer()
                Button("Check Again") { Task { await store.check(provider) } }
                    .disabled(store.checks[provider.id] == .checking)
            }
            .padding(20)

            Form {
                Section("Connection") {
                    if provider.kind != .cloud {
                        TextField("Server URL", text: $serverURL)
                            .onSubmit(saveURL)
                    }
                    if provider.needsKey || provider.kind == .custom {
                        if replacing || !store.hasKey(provider) {
                            HStack {
                                SecureField("API Key", text: $newKey, prompt: provider.template.keyHint.map { Text($0) })
                                Button("Save") {
                                    Task {
                                        if await store.replaceKey(provider, key: newKey).ok { newKey = ""; replacing = false }
                                    }
                                }
                                .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                            }
                        } else {
                            LabeledContent("API Key") {
                                HStack {
                                    Text("Saved in Keychain").foregroundStyle(.secondary)
                                    Button("Replace…") { replacing = true }
                                }
                            }
                        }
                    }
                    if let link = provider.template.keyURL, let u = URL(string: link) {
                        Link(destination: u) { Label("Open \(u.host ?? link)", systemImage: "arrow.up.forward.square") }
                    }
                }

                Section("Used For") {
                    let roles = Models.roles(of: provider.id, config: store.config)
                    if roles.isEmpty {
                        Text("Nothing yet. Choose one of its models above or under Voice.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(roles) { r in
                        LabeledContent {
                            Text(store.title(for: r))
                        } label: {
                            Label(r.title, systemImage: r.symbol)
                        }
                    }
                }

                Section {
                    if provider.template.id == "ollama" && !store.ollamaPresent {
                        Label("Ollama isn't installed — `brew install --cask ollama`", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                    ForEach(provider.template.models) { m in
                        ModelLine(store: store, provider: provider, option: m)
                    }
                    let extra = (store.live[provider.id] ?? []).filter { id in !provider.template.models.contains { $0.id == id } }
                    let liveRoles = provider.roles.filter { $0.api == .chat }
                    if provider.template.models.isEmpty {
                        if extra.isEmpty {
                            Text("This server didn't list any models.").foregroundStyle(.secondary)
                        }
                        ForEach(extra, id: \.self) { id in
                            ModelLine(store: store, provider: provider, option: ModelOption(id, roles: liveRoles))
                        }
                    } else if !extra.isEmpty {
                        DisclosureGroup("\(extra.count) more from this server") {
                            ForEach(extra, id: \.self) { id in
                                ModelLine(store: store, provider: provider, option: ModelOption(id, roles: liveRoles))
                            }
                        }
                    }
                } header: {
                    Text("Models")
                }

                Section {
                    Button("Disconnect \(provider.name)…", role: .destructive) { confirmRemove = true }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)

            Divider()
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(14)
        }
        .frame(width: 540, height: 540)
        .onAppear {
            serverURL = provider.base(.chat) ?? ""
            store.refreshInstalled()
            Task { await store.refreshModels(provider) }
        }
        .confirmationDialog("Disconnect \(provider.name)?", isPresented: $confirmRemove) {
            Button("Disconnect", role: .destructive) {
                store.disconnect(provider)
                dismiss()
            }
        } message: {
            Text("Its key is removed from the Keychain and every role using it turns off.")
        }
    }

    @ViewBuilder
    private var checkLine: some View {
        switch store.checks[provider.id] {
        case .checking?:
            Text("Checking…").font(.callout).foregroundStyle(.secondary)
        case .ok(let m)?:
            Label(m, systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        case .failed(let m)?:
            Label(m, systemImage: "xmark.circle.fill").font(.callout).foregroundStyle(.red)
        case nil:
            Text(provider.template.summary).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func saveURL() {
        var e = provider.config
        let u = serverURL.trimmingCharacters(in: .whitespaces)
        e.chat = u == provider.template.chat ? nil : u
        if provider.template.id == "ollama" { e.systemOne = e.chat.map { $0.hasSuffix("/v1") ? String($0.dropLast(3)) : $0 } }
        store.update(e)
        Task { await store.check(Models.provider(provider.id, config: store.config) ?? provider) }
    }
}

@available(macOS 26, *)
private struct ModelLine: View {
    let store: ModelStore
    let provider: Provider
    let option: ModelOption

    private var isOllama: Bool { provider.template.id == "ollama" }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(option.displayName)
                Text(([option.size, option.note].compactMap { $0 } + [roles]).joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isOllama {
                if let p = store.pulls[option.id] {
                    Text(p).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head).frame(maxWidth: 160, alignment: .trailing)
                } else if store.isInstalled(option.id) {
                    useMenu
                } else if store.ollamaPresent {
                    Button {
                        store.pull(option.id, provider: provider)
                    } label: {
                        Image(systemName: "arrow.down.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Download \(option.displayName)")
                }
            } else {
                useMenu
            }
        }
    }

    private var roles: String {
        let r = option.roles.map { $0.short }.formatted(.list(type: .and))
        return option.vision == true ? r + ", " + String(localized: "sees the screen") : r
    }

    private var useMenu: some View {
        Menu("Use") {
            ForEach(option.roles) { r in
                Button {
                    store.assign(r, ModelRef(provider: provider.id, model: option.id))
                } label: {
                    Text("As \(r.short)")
                }
            }
        }
        .fixedSize()
        .controlSize(.small)
    }
}

/// Metered calls per role/model — numbers only, from ~/.s1/usage.jsonl.
@available(macOS 26, *)
private struct UsageSection: View {
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
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.model).lineLimit(1)
                        Text(ModelRole(rawValue: r.role).map { $0.short } ?? r.role)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Usage · Last 30 Days")
        } footer: {
            FootNote("Token counts as each provider reports them. Full log: `s1 usage`.")
        }
        .task {
            rows = await Task.detached {
                UsageLog.summarize(UsageLog.load(since: Date().addingTimeInterval(-30 * 86_400)))
            }.value
        }
    }

    static func line(_ r: UsageLog.Summary) -> String {
        var s = "\(r.calls) calls · \(r.input.formatted(.number.notation(.compactName))) in · \(r.output.formatted(.number.notation(.compactName))) out"
        if let h = r.cacheHitRate, r.cached > 0 { s += " · \(Int(h * 100))% cached" }
        if r.failures > 0 { s += " · \(r.failures) failed" }
        return s + " · \(r.avgMs) ms"
    }
}
