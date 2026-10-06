import Foundation
import S1Core
import SwiftUI

/// Providers + role assignments for the UI — a thin observable layer over
/// `Models` in S1Core, which the CLI and the agent read from the same
/// `~/.s1/config.json`. Every edit writes through immediately; `onChange`
/// lets the agent re-arm with the new models.
@available(macOS 26, *)
@MainActor
@Observable
final class ModelStore {
    struct Failure: Error { let message: String }

    enum Check: Equatable {
        case checking
        case ok(String)
        case failed(String)

        var isOK: Bool { if case .ok = self { return true }; return false }
    }

    private(set) var config = S1Config.load()
    /// Provider ids with a key in the Keychain — cached so views don't hit
    /// the Keychain on every render.
    private(set) var keyed: Set<String> = []
    private(set) var checks: [String: Check] = [:]
    /// Live `/models` lists per provider id.
    private(set) var live: [String: [String]] = [:]
    /// `ollama list`, refreshed on demand.
    private(set) var installed: [String] = []
    /// Download progress per Ollama model while a pull runs.
    private(set) var pulls: [String: String] = [:]

    @ObservationIgnored var onChange: (() -> Void)?

    init() { reloadKeys() }

    var providers: [Provider] { Models.connected(config: config) }

    func provider(_ id: String) -> Provider? { providers.first { $0.id == id } }

    func assignment(_ role: ModelRole) -> ModelRef? {
        Models.assignment(role, config: config, env: [:])
    }

    /// Why a role isn't working, if it isn't. nil = off or fine.
    func problem(_ role: ModelRole) -> Models.Problem? {
        if case .failure(let p)? = Models.resolve(role, config: config, env: [:], secret: cachedSecret) { return p }
        return nil
    }

    var hasReasoner: Bool {
        if case .success? = Models.resolve(.reasoner, config: config, env: [:], secret: cachedSecret) { return true }
        return false
    }

    func hasKey(_ p: Provider) -> Bool { keyed.contains(p.keyAccount) }

    /// Screenshots may go to models that can read them.
    var visionEnabled: Bool { Models.visionEnabled(config: config, env: [:]) }

    func setVision(_ on: Bool) { write { $0.vision = on ? nil : false } }

    func canSee(_ role: ModelRole) -> Bool { Models.canSee(role, config: config, env: [:]) }

    /// The Reasoner may search the web when its provider or model can.
    var webSearchEnabled: Bool { config.webSearch != false }

    func setWebSearch(_ on: Bool) { write { $0.webSearch = on ? nil : false } }

    /// How the current Reasoner searches, in one line.
    var webSearchSummary: String {
        guard webSearchEnabled else { return String(localized: "Off. The Reasoner answers from what it knows and says when it may be out of date.") }
        guard let e = Models.endpoint(.reasoner, config: config, env: [:]) else {
            return String(localized: "Connect a Reasoner to search the web.")
        }
        switch WebSearch.kind(e) {
        case .native: return String(localized: "Your Reasoner searches the web by itself.")
        case .openAI: return String(localized: "Uses OpenAI's web search (billed per search).")
        case .openRouter: return String(localized: "Uses OpenRouter's web search (billed per search).")
        case .none: return String(localized: "Your Reasoner's provider has no web search, so answers about recent events may be out of date.")
        }
    }

    /// Who sees the screen right now, in one line for the Models pane.
    var visionSummary: String {
        guard visionEnabled else { return String(localized: "Off. s1 reads the accessibility tree only.") }
        switch (canSee(.judge), canSee(.reasoner)) {
        case (true, true): return String(localized: "The judge and the reasoner both see the screen.")
        case (true, false): return String(localized: "The Judge sees the screen. The Reasoner works from the accessibility tree.")
        case (false, true): return String(localized: "The Reasoner sees the screen when a step needs it.")
        case (false, false): return String(localized: "Neither model can read images, so s1 uses the accessibility tree only.")
        }
    }

    /// Display line for a role's current pick: "Jev · TypeSafe".
    func title(for role: ModelRole) -> String {
        guard let ref = assignment(role) else {
            return role.api == .audio ? String(localized: "On this Mac") : String(localized: "Off")
        }
        let p = Models.provider(ref.provider, config: config)
        let model = p?.option(ref.model)?.displayName ?? ref.model
        return p.map { "\(model) · \($0.name)" } ?? model
    }

    // MARK: - editing

    func assign(_ role: ModelRole, _ ref: ModelRef?) {
        write { Models.assign(role, ref, in: &$0) }
    }

    /// Validate first, then save — a provider only lands in config once a
    /// real round trip proved the key and URL work. Returns the roles it
    /// took over, or the failure to show inline.
    func connect(_ entry: ProviderConfig, key: String?) async -> Result<[ModelRole], Failure> {
        let t = ProviderCatalog.template(entry.template ?? entry.id) ?? ProviderCatalog.template("custom")!
        let p = Provider(template: t, config: entry)
        let k = key?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveKey = (k?.isEmpty == false ? k : nil) ?? SecretStore.get(account: p.keyAccount)
        checks[p.id] = .checking
        let outcome = await ProviderCheck.run(p, key: effectiveKey)
        guard outcome.ok else {
            checks[p.id] = nil
            return .failure(.init(message: outcome.message))
        }
        if let k, !k.isEmpty {
            do { try SecretStore.set(k, account: p.keyAccount) } catch {
                return .failure(.init(message: error.localizedDescription))
            }
        }
        var took: [ModelRole] = []
        write { took = Models.connect(entry, in: &$0) }
        checks[p.id] = .ok(outcome.message)
        Task { await refreshModels(p) }
        return .success(took)
    }

    func replaceKey(_ p: Provider, key: String) async -> ProviderCheck.Outcome {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        checks[p.id] = .checking
        let outcome = await ProviderCheck.run(p, key: k)
        if outcome.ok { try? SecretStore.set(k, account: p.keyAccount); reloadKeys(); onChange?() }
        checks[p.id] = outcome.ok ? .ok(outcome.message) : .failed(outcome.message)
        return outcome
    }

    func update(_ entry: ProviderConfig) {
        write { c in
            if let i = c.providers?.firstIndex(where: { $0.id == entry.id }) { c.providers?[i] = entry }
        }
    }

    func disconnect(_ p: Provider) {
        write { Models.disconnect(p.id, in: &$0) }
        SecretStore.delete(account: p.keyAccount)
        checks[p.id] = nil
        live[p.id] = nil
        reloadKeys()
    }

    private func write(_ body: (inout S1Config) -> Void) {
        var c = S1Config.load()
        body(&c)
        try? c.save()
        config = c
        reloadKeys()
        onChange?()
    }

    func reload() {
        config = S1Config.load()
        reloadKeys()
    }

    private func reloadKeys() {
        keyed = Set(Models.connected(config: config).map(\.keyAccount).filter { SecretStore.has(account: $0) })
    }

    private var cachedSecret: Models.Secret {
        let keyed = keyed
        return { p in keyed.contains(p.keyAccount) ? "•" : nil }
    }

    // MARK: - checks + live lists

    func check(_ p: Provider) async {
        checks[p.id] = .checking
        let outcome = await ProviderCheck.run(p, key: Models.keychain(p))
        checks[p.id] = outcome.ok ? .ok(outcome.message) : .failed(outcome.message)
    }

    /// Settings open → re-verify every provider once and fetch live lists.
    func checkAll() {
        reload()
        for p in providers where checks[p.id] != .checking {
            Task { await check(p); await refreshModels(p) }
        }
        refreshInstalled()
    }

    func refreshModels(_ p: Provider) async {
        guard p.template.listsModels else { return }
        if case .success(let ids) = await ModelList.fetch(p, key: Models.keychain(p)) { live[p.id] = ids }
    }

    /// Models a picker can offer beyond the catalog's curated ones.
    func moreModels(_ p: Provider, for role: ModelRole) -> [String] {
        guard role.api == .chat else { return [] }
        let curated = Set(p.template.models.map(\.id))
        return (live[p.id] ?? []).filter { !curated.contains($0) }
    }

    // MARK: - Ollama

    var ollamaPresent: Bool { ModelPull.ollamaBinary() != nil }

    func isInstalled(_ model: String) -> Bool { ModelPull.contains(installed, model) }

    func refreshInstalled() {
        Task {
            installed = await Task.detached { ModelPull.installed() }.value
        }
    }

    /// One tap: pull, then (optionally) assign it.
    func pull(_ model: String, provider: Provider, assignTo role: ModelRole? = nil) {
        guard pulls[model] == nil else { return }
        pulls[model] = String(localized: "Starting…")
        Task {
            do {
                try await ModelPull.pull(model: model) { line in
                    Task { @MainActor in self.pulls[model] = line }
                }
                pulls[model] = nil
                refreshInstalled()
                await refreshModels(provider)
                if let role { assign(role, ModelRef(provider: provider.id, model: model)) }
            } catch {
                pulls[model] = String(localized: "Failed: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - presentation

@available(macOS 26, *)
extension ModelRole {
    var title: LocalizedStringKey {
        switch self {
        case .judge: "Judge (System 1)"
        case .reasoner: "Reasoner (System 2)"
        case .transcribe: "Transcription"
        case .speak: "Voice"
        }
    }

    var subtitle: LocalizedStringKey {
        switch self {
        case .judge: "Picks the right control when unsure and checks the job is done. Fast and optional."
        case .reasoner: "An LLM for anything the built-in grammar can't do."
        case .transcribe: "Re-transcribes each finished turn in the cloud."
        case .speak: "Speaks replies with a cloud voice."
        }
    }

    var symbol: String {
        switch self {
        case .judge: "checkmark.shield"
        case .reasoner: "sparkles"
        case .transcribe: "waveform"
        case .speak: "speaker.wave.2"
        }
    }

    var short: String {
        switch self {
        case .judge: String(localized: "Judge")
        case .reasoner: String(localized: "Reasoner")
        case .transcribe: String(localized: "Transcription")
        case .speak: String(localized: "Voice")
        }
    }
}

extension ProviderTemplate {
    /// Brand colour behind the official mark.
    var tint: Color {
        switch id {
        case "typesafe": Color(red: 0.87, green: 0.33, blue: 0.75)
        case "openai", "xai", "ollama", "opencode", "liquid": Color(white: 0.12)
        case "openrouter": Color(red: 0.39, green: 0.40, blue: 0.95)
        case "groq": Color(red: 0.96, green: 0.31, blue: 0.21)
        case "gemini": Color(red: 0.26, green: 0.52, blue: 0.96)
        case "deepseek": Color(red: 0.30, green: 0.42, blue: 1.0)
        case "cloudflare": Color(red: 0.95, green: 0.50, blue: 0.13)
        case "lmstudio": Color(red: 0.25, green: 0.36, blue: 0.86)
        default: Color(white: 0.42)
        }
    }
}
