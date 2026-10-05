import SwiftUI
import AVFoundation
import S1Core

/// Standard macOS Settings window (⌘,). The main window stays a command
/// bar + step feed; every knob lives here, grouped by what it changes.
@available(macOS 26, *)
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(model: model) }
            Tab("Voice", systemImage: "waveform", value: "voice") { VoiceSettings(model: model) }
            Tab("Models", systemImage: "cpu", value: "models") { ConnectionsView(model: model) }
            Tab("Snippets", systemImage: "text.badge.plus", value: "snippets") { SnippetSettings() }
            Tab("Permissions", systemImage: "hand.raised", value: "permissions") { PermissionSettings(model: model) }
            Tab("About", systemImage: "info.circle", value: "about") { AboutSettings() }
        }
        .scenePadding()
        .frame(width: 620, height: 640)
        .onAppear { model.refreshModels(); model.refreshPermissions() }
    }
}

@available(macOS 26, *)
private struct GeneralSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                Picker("Brain", selection: $model.brain) {
                    ForEach(AppModel.Brain.allCases) { b in Text(b.title).tag(b) }
                }
                .pickerStyle(.inline)
                Toggle("Escalate hard steps to S2 (reasoning LLM)", isOn: $model.useS2)
            } header: {
                Text("System 1")
            } footer: {
                Text("Simple commands (open, type, press, scroll) run on the built-in grammar with no model at all. Auto adds the optional vision model (Models → Advanced, off by default) only when the grammar can't place a step.")
            }
            Section("Companion") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLoginItem() }))
                Toggle("Notch status pill", isOn: $model.notchHUD)
                LabeledContent("Wake") { Text("⇧⇧  or  ⌃⌥Space  ·  ⌘⇧L in the app").foregroundStyle(.secondary) }
                LabeledContent("Launcher") { Text("⌥Space").foregroundStyle(.secondary) }
                LabeledContent("Dictate") { Text("⌃⌥D — hold to talk, or tap; text pastes where you type").foregroundStyle(.secondary) }
            }
            Section {
                Toggle("Remember things I ask you to", isOn: Binding(
                    get: { Memory.enabled() },
                    set: { on in var c = S1Config.load(); c.memory = on ? nil : false; try? c.save() }))
                HStack {
                    Button("Open Memory") {
                        if !FileManager.default.fileExists(atPath: Memory.path.path) { try? Memory.clear() }
                        NSWorkspace.shared.open(Memory.path)
                    }
                    Button("Clear Memory") { try? Memory.clear() }
                    Spacer()
                    Button("Open Skills Folder") {
                        S1Home.ensurePrivate()
                        try? FileManager.default.createDirectory(at: Skills.dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(Skills.dir)
                    }
                }
            } header: {
                Text("Memory & skills")
            } footer: {
                Text("Say “remember that …” to keep a fact (never passwords or keys), “forget everything” to clear. After something works, say “save that as a skill called morning setup”; saying “morning setup” replays its steps, each through the safety gate. Plain files in ~/.s1 — edit them freely. The current session's history is always shared with S1 and S2.")
            }
            Section {
                Toggle("Use Cua Driver when installed", isOn: Binding(
                    get: { CuaDriver.enabled() },
                    set: { on in
                        var c = S1Config.load(); c.executor = on ? nil : "cgevent"
                        try? c.save()
                    }))
                .disabled(CuaDriver.binary() == nil)
                if CuaDriver.binary() == nil {
                    Button(model.cuaInstalling ? "Installing…" : "Install Cua Driver (recommended)") {
                        Task { await model.installCuaDriver() }
                    }
                    .disabled(model.cuaInstalling)
                    if !model.cuaInstallLog.isEmpty {
                        Text(model.cuaInstallLog.components(separatedBy: "\n").dropLast().last ?? "")
                            .font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Executor")
            } footer: {
                if CuaDriver.binary() == nil {
                    Text("Recommended. Installed with CUA's own installer so typing, keys and app launches run in the background without stealing focus. [cua.ai/docs/libraries/cua-driver](https://cua.ai/docs/libraries/cua-driver)")
                } else {
                    Text(CuaDriver.enabled() ? "Cua Driver found. Typing, shortcuts and app launches go through it in the background (no focus stealing); everything else, and any failed Cua call, uses s1's own fast path. The safety gate runs first either way." : "Cua Driver is installed but turned off; s1 uses its own input path.")
                }
            }
            Section {
                Toggle("Sandbox shell commands", isOn: $model.sandboxSrt)
                    .disabled(Sandbox.srtBinary() == nil)
            } header: {
                Text("Shell sandbox")
            } footer: {
                if Sandbox.srtBinary() == nil {
                    Text("Optional, off by default. Runs shell steps inside Anthropic's sandbox-runtime (Seatbelt + network policy) — install with `npm install -g @anthropic-ai/sandbox-runtime`. Without it this stays off.")
                } else {
                    Text("sandbox-runtime found. When on, shell steps run under the policy in ~/.s1/srt-settings.json (edit it to widen or tighten). On any srt error the step fails instead of running unsandboxed.")
                }
            }
            Section {
                ForEach(configFiles, id: \.0) { name, url, ensure in
                    Button(name) { ensure(); NSWorkspace.shared.open(url) }
                }
                Button("Run checks (s1 doctor)") {
                    Task {
                        let items = await Task.detached { Doctor.run() }.value
                        doctorResult = items.isEmpty
                            ? "All good — nothing needs attention."
                            : items.map { "\($0.level == .fail ? "✗" : $0.level == .warn ? "⚠" : "✓") \($0.what)" }
                                   .joined(separator: "\n")
                    }
                }
                if let r = doctorResult {
                    Text(r).font(.caption.monospaced()).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } header: {
                Text("Configuration files")
            } footer: {
                Text("Every s1 setting lives in a plain file under ~/.s1 — edit them in any editor, then run the checks to validate. `s1 doctor` does the same in a terminal (`--fix` repairs).")
            }
        }
        .formStyle(.grouped)
    }

    @State private var doctorResult: String?

    /// Every user-facing file under ~/.s1, in doc order — each with the
    /// ensure-step that materializes a sane default before opening.
    private var configFiles: [(String, URL, () -> Void)] {
        let home = NSHomeDirectory() + "/.s1"
        let touchJSON: (String) -> Void = { path in
            if !FileManager.default.fileExists(atPath: path) {
                try? "{}\n".write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        let touchText: (String) -> Void = { path in
            if !FileManager.default.fileExists(atPath: path) {
                try? "".write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        return [
            ("config.json — models, keys, sandbox",
             URL(fileURLWithPath: home + "/config.json"),
             { let c = S1Config.load(); try? c.save() }),
            ("providers.json — endpoint presets",
             URL(fileURLWithPath: home + "/providers.json"),
             { Providers.ensureFile() }),
            ("convert.json — unit & currency aliases",
             URL(fileURLWithPath: home + "/convert.json"),
             { touchJSON(home + "/convert.json") }),
            ("snippets.json — launcher commands",
             URL(fileURLWithPath: home + "/snippets.json"),
             { Snippets.ensureFile() }),
            ("memory.md — remembered facts",
             URL(fileURLWithPath: home + "/memory.md"),
             { touchText(home + "/memory.md") }),
            ("srt-settings.json — sandbox policy",
             URL(fileURLWithPath: home + "/srt-settings.json"),
             { Sandbox.ensureSettingsFile() }),
        ]
    }
}

@available(macOS 26, *)
private struct VoiceSettings: View {
    @Bindable var model: AppModel

    private var voices: [AVSpeechSynthesisVoice] {
        let codes = Set(SpokenLanguage.candidates(for: model.locale).map(SpokenLanguage.code))
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { codes.contains(String($0.language.prefix(2))) }
            .sorted { ($0.language, -$0.quality.rawValue, $0.name) < ($1.language, -$1.quality.rawValue, $1.name) }
    }

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $model.locale) {
                    Text("Automatic").tag(SpokenLanguage.auto)
                    Divider()
                    Text("Indonesian").tag("id-ID")
                    Text("English (US)").tag("en-US")
                    Text("English (UK)").tag("en-GB")
                }
                LabeledContent("Custom words") {
                    TextField("e.g. Warp, JIRA", text: $model.vocabulary)
                        .multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Speech recognition")
            } footer: {
                Text(model.locale == SpokenLanguage.auto
                     ? "On-device. Automatic listens in \(SpokenLanguage.candidates(for: model.locale).map { Locale.current.localizedString(forIdentifier: $0.identifier) ?? $0.identifier }.joined(separator: " and ")) at once and keeps the one it's surest of. Installed app names are learned automatically."
                     : "On-device. Installed app names are learned automatically.")
            }
            Section {
                Menu("Preset") {
                    ForEach(Providers.presets(role: .stt), id: \.id) { p in
                        Button(p.note.map { "\(p.label) — \($0)" } ?? p.label) {
                            model.sttBase = p.base; model.sttModel = p.model
                        }
                    }
                    Divider()
                    Button("Edit presets (providers.json)…") {
                        Providers.ensureFile()
                        NSWorkspace.shared.open(Providers.path)
                    }
                }
                .fixedSize()
                TextField("Base URL", text: $model.sttBase)
                TextField("Model (empty = on-device)", text: $model.sttModel)
                if !model.sttModel.isEmpty {
                    KeyRow(model: model, role: .stt)
                    TestRow(model: model, role: .stt)
                }
            } header: {
                Text("Cloud recognition (optional)")
            } footer: {
                Text("Apple still listens on-device (end-of-speech detection, live text). With a model set, each finished turn is re-transcribed in the cloud for accuracy, using your custom words as the spelling hint, and falls back to on-device on any error. Audio leaves the Mac only when this is on.")
            }
            Section {
                Toggle("Interrupt with my voice (barge-in)", isOn: $model.voiceInterrupt)
                Picker("End-of-speech detection", selection: $model.vadMode) {
                    Text("Automatic (Apple VAD + energy)").tag("auto")
                    Text("Energy only (deterministic)").tag("energy")
                }
                Picker("End-of-speech sensitivity", selection: $model.vadSensitivity) {
                    Text("Low — tolerates pauses").tag("low")
                    Text("Medium").tag("medium")
                    Text("High — ends the turn fast").tag("high")
                }
            } header: {
                Text("Listening")
            } footer: {
                Text("Barge-in listens (energy only, echo-cancelled) while a run or reply is in flight — say anything and it stops, then keep talking for the next command. High sensitivity cuts the turn sooner after your last word.")
            }
            Section {
                Toggle("Speak results", isOn: $model.speakReply)
                Picker("Voice", selection: $model.ttsVoice) {
                    Text("Automatic (best installed)").tag("")
                    Divider()
                    ForEach(voices, id: \.identifier) { v in
                        Text("\(v.name) — \(v.language)\(Self.qualityTag(v.quality))").tag(v.identifier)
                    }
                }
                .disabled(!model.speakReply)
                Button("Preview") { model.previewVoice() }
                    .disabled(!model.speakReply)
                Menu("Cloud voice") {
                    ForEach(Providers.presets(role: .tts), id: \.id) { p in
                        Button(p.note.map { "\(p.label) — \($0)" } ?? p.label) {
                            model.ttsBase = p.base; model.ttsModel = p.model
                            if let v = p.voice { model.ttsCloudVoice = v }
                        }
                    }
                    Divider()
                    Button("Edit presets (providers.json)…") {
                        Providers.ensureFile()
                        NSWorkspace.shared.open(Providers.path)
                    }
                }
                .fixedSize()
                .disabled(!model.speakReply)
                if !model.ttsModel.isEmpty {
                    TextField("Base URL", text: $model.ttsBase)
                    TextField("Model", text: $model.ttsModel)
                    TextField("Voice", text: $model.ttsCloudVoice)
                    KeyRow(model: model, role: .tts)
                    TestRow(model: model, role: .tts)
                }
            } header: {
                Text("Speech output")
            } footer: {
                Text("Replies use the language you spoke. For the most natural sound, download a Premium or Enhanced voice in System Settings → Accessibility → Spoken Content → System Voice → Manage Voices.")
            }
        }
        .formStyle(.grouped)
    }

    static func qualityTag(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: " · Premium"
        case .enhanced: " · Enhanced"
        default: ""
        }
    }
}

@available(macOS 26, *)
private struct PermissionSettings: View {
    @Bindable var model: AppModel
    var body: some View {
        Form {
            Section {
                PermRow(label: "Accessibility", ok: model.permissions.accessibility, pane: "Privacy_Accessibility")
                PermRow(label: "Screen Recording", ok: model.permissions.screenRecording, pane: "Privacy_ScreenCapture")
                PermRow(label: "Microphone", ok: model.permissions.microphone, pane: "Privacy_Microphone")
                PermRow(label: "Input Monitoring", ok: model.permissions.inputMonitoring, pane: "Privacy_ListenEvent")
                HStack {
                    Button("Request / re-check") { model.requestPermissions() }
                    Button("Fix stuck Accessibility") { model.resetAccessibility() }
                }
            } footer: {
                Text("Only Accessibility is required. Toggle on but still missing? Fix removes the old build's entry and asks again. Screen Recording is optional (screenshots, vision) and applies on next launch.")
            }
        }
        .formStyle(.grouped)
    }
}

@available(macOS 26, *)
struct ModelLibrarySection: View {
    @Bindable var model: AppModel
    var body: some View {
                Section("Model library") {
                    if !model.ollamaPresent {
                        Label("Ollama not installed", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                        Text(ModelPull.installHint)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    } else {
                        if !model.installedModels.isEmpty {
                            ForEach(model.installedModels, id: \.self) { name in
                                HStack(spacing: 6) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(.green)
                                        .accessibilityHidden(true)
                                    Text(name).lineLimit(1).truncationMode(.tail)
                                    Spacer()
                                    if name == model.vlmModel && model.brain == .vlm {
                                        Text("S1").font(.caption.weight(.semibold))
                                            .foregroundStyle(.tint)
                                    }
                                    if name == model.s2Model && model.useS2 {
                                        Text("S2").font(.caption.weight(.semibold))
                                            .foregroundStyle(.purple)
                                    }
                                    if name == model.grounderModel {
                                        Text("⌖").font(.caption.weight(.semibold))
                                            .foregroundStyle(.orange)
                                            .accessibilityLabel("click grounder")
                                    }
                                    if name.hasPrefix(model.decisionModel) && !model.decisionModel.isEmpty
                                        && model.decisionIsLocal {
                                        Text("judge").font(.caption.weight(.semibold))
                                            .foregroundStyle(.teal)
                                    }
                                    Menu {
                                        Button("Use as decision judge (S1)") { model.useAsDecision(name) }
                                        Button("Use as brain (S1)") { model.useAsBrain(name) }
                                        Button("Use as reasoner (S2)") { model.useAsS2(name) }
                                        if name == model.grounderModel {
                                            Button("Stop using as click grounder") { model.grounderModel = "" }
                                        } else {
                                            Button("Use as click grounder") { model.useAsGrounder(name) }
                                        }
                                    } label: {
                                        Image(systemName: "ellipsis.circle")
                                            .accessibilityLabel("Assign \(name)")
                                    }
                                    .menuStyle(.borderlessButton)
                                    .menuIndicator(.hidden)
                                    .frame(width: 20)
                                }
                            }
                        }
                        ForEach(model.catalog.filter { !model.installedModels.contains($0.name) },
                                id: \.name) { entry in
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(entry.name).font(.callout)
                                        if entry.decision {
                                            Image(systemName: "checkmark.diamond")
                                                .font(.caption2)
                                                .foregroundStyle(.teal)
                                                .accessibilityLabel("decision model")
                                        } else if entry.grounding {
                                            Image(systemName: "scope")
                                                .font(.caption2)
                                                .foregroundStyle(.orange)
                                                .accessibilityLabel("click grounding model")
                                        } else if entry.vision {
                                            Image(systemName: "eye")
                                                .font(.caption2)
                                                .foregroundStyle(.secondary)
                                                .accessibilityLabel("vision model")
                                        }
                                    }
                                    Text("\(entry.size) · \(entry.blurb)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                if let prog = model.pullProgress[entry.name] {
                                    Text(prog).font(.caption)
                                        .lineLimit(1).truncationMode(.head)
                                        .frame(maxWidth: 110)
                                } else {
                                    Button {
                                        model.pullModel(entry.name, vision: entry.vision,
                                                        grounding: entry.grounding, decision: entry.decision)
                                    } label: {
                                        Image(systemName: "arrow.down.circle")
                                    }
                                    .buttonStyle(.glass)
                                    .controlSize(.small)
                                    .accessibilityLabel("Download \(entry.name)")
                                }
                            }
                        }
                    }
                    Text("One tap downloads the model and wires it in — ◆ decision judges check each step, vision models become the S1 brain, text models become S2, ⌖ grounders aim clicks.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
    }
}

    /// One line under an endpoint section: is the configured model there,
    /// and if not, the single button that fixes it.
@available(macOS 26, *)
struct ModelStatusRow: View {
    let status: ModelPullStatus
    var body: some View {
        HStack(spacing: 8) {
            switch status.state {
            case .checking:
                ProgressView().controlSize(.mini)
                Text("checking…").foregroundStyle(.secondary)
            case .installed:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    .accessibilityLabel("installed")
                Text("\(status.modelName) ready").foregroundStyle(.secondary)
            case .missing:
                Image(systemName: "arrow.down.circle").foregroundStyle(.orange)
                    .accessibilityLabel("not downloaded")
                Text("\(status.modelName) not pulled").foregroundStyle(.secondary)
                Spacer()
                Button("Download") { status.pull() }.controlSize(.mini)
            case .downloading(let line):
                ProgressView().controlSize(.mini)
                Text(line).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.tail)
            case .failed(let err):
                Image(systemName: "xmark.circle").foregroundStyle(.red)
                    .accessibilityLabel("failed")
                Text(err).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                Button("Retry") { status.retry() }.controlSize(.mini)
            case .unreachable:
                Image(systemName: "bolt.slash").foregroundStyle(.orange)
                    .accessibilityLabel("server down")
                Text("server down").foregroundStyle(.secondary)
                Spacer()
                Button("Start") { status.startServer() }.controlSize(.mini)
            case .noOllama:
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    .accessibilityLabel("ollama missing")
                Text(ModelPull.installHint).font(.caption.monospaced())
                    .textSelection(.enabled)
            case .remote:
                EmptyView()
            }
        }
        .font(.caption)
        .onAppear { status.refresh() }
    }
}

@available(macOS 26, *)
struct PermRow: View {
    /// macOS 13+ System Settings deep link (the old com.apple.preference.security
    /// URL still resolves but lands on the pane root on newer releases).
    static func open(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }
    let label: String
    let ok: Bool
    let pane: String
    var body: some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
                .accessibilityLabel(ok ? "granted" : "missing")
            Text(label).font(.callout)
            if !ok {
                Spacer()
                Button("Open Settings") { Self.open(pane) }
                .controlSize(.mini)
            }
        }
    }
}

/// Snippet editor over ~/.s1/snippets.json — type the keyword in the
/// ⌥Space launcher, Enter pastes the expansion into the app you were in.
@available(macOS 26, *)
private struct SnippetSettings: View {
    @State private var items: [Snippet] = Snippets.load()
    @State private var selection: Int?
    @State private var note = ""

    var body: some View {
        Form {
            Section {
                List(selection: $selection) {
                    ForEach(items.indices, id: \.self) { i in
                        HStack {
                            Text(items[i].keyword.isEmpty ? "untitled" : items[i].keyword).bold()
                            Text(items[i].text.replacingOccurrences(of: "\n", with: " ⏎ "))
                                .foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(i)
                    }
                }
                .frame(minHeight: 200)
                HStack {
                    Button("Add") {
                        items.append(Snippet(keyword: "new", text: ""))
                        selection = items.count - 1
                    }
                    Button("Remove") {
                        if let s = selection, items.indices.contains(s) { items.remove(at: s); selection = nil }
                    }
                    .disabled(selection == nil)
                    Spacer()
                    Button("Restore Defaults") { items = Snippets.defaults; selection = nil }
                    Button("Open JSON") { Snippets.ensureFile(); NSWorkspace.shared.open(Snippets.path) }
                    Button("Save") {
                        do { try Snippets.save(items); note = "Saved" } catch { note = error.localizedDescription }
                    }
                    .keyboardShortcut("s", modifiers: .command)
                }
            } footer: {
                Text(note.isEmpty ? "Placeholders: {date} {time} {datetime} {isodate} {weekday} {name} {uuid} {clipboard}. Stored in ~/.s1/snippets.json." : note)
            }
            if let s = selection, items.indices.contains(s) {
                Section("Edit") {
                    TextField("Keyword", text: $items[s].keyword)
                    TextEditor(text: $items[s].text)
                        .font(.body.monospaced())
                        .frame(minHeight: 90)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { items = Snippets.load() }
    }
}

/// Version, license and the open-source projects s1 builds on.
@available(macOS 26, *)
private struct AboutSettings: View {
    private struct Credit: Identifiable {
        let name, license, url, use: String
        var id: String { name }
    }

    private let credits: [Credit] = [
        .init(name: "Cua Driver (trycua/cua)", license: "MIT", url: "https://github.com/trycua/cua",
              use: "Optional background executor, used when installed"),
        .init(name: "swift-argument-parser (Apple)", license: "Apache-2.0", url: "https://github.com/apple/swift-argument-parser",
              use: "s1 command-line interface"),
        .init(name: "AeriVoice", license: "MIT", url: "https://github.com/DanielOu1208/aerivoice",
              use: "Design inspiration: hold-to-talk, live notch transcript, paste-and-restore"),
        .init(name: "Pi agent harness", license: "MIT", url: "https://github.com/badlogic/pi-mono",
              use: "Design inspiration: JSON event stream, session history, text-file skills"),
        .init(name: "sandbox-runtime (Anthropic)", license: "Apache-2.0", url: "https://github.com/anthropics/sandbox-runtime",
              use: "Optional sandbox for shell steps — Seatbelt rules + network policy"),
        .init(name: "Agent Memory Repo (Cognition)", license: "MIT", url: "https://github.com/AgentMemoryRepo/agentmemoryrepo",
              use: "The open spec behind Devin's memory — main file + per-topic files + [[links]] index"),
        .init(name: "Frankfurter", license: "MIT", url: "https://frankfurter.dev",
              use: "Currency rates (European Central Bank reference data)"),
    ]

    var body: some View {
        Form {
            Section {
                LabeledContent("s1", value: "\(S1Info.version)")
                LabeledContent("License", value: "MIT")
                Link("github.com/Matthew-Eucaristo/s1", destination: URL(string: "https://github.com/Matthew-Eucaristo/s1")!)
            }
            Section {
                ForEach(credits) { c in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Link(c.name, destination: URL(string: c.url)!)
                            Spacer()
                            Text(c.license).font(.caption).foregroundStyle(.secondary)
                        }
                        Text(c.use).font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Open source")
            } footer: {
                Text("Thanks to everyone who builds and maintains these projects. Hosted models (Jev, OpenCode Go, Liquid d1, Cloudflare Clef, Groq, OpenAI) are third-party services under their own terms.")
            }
        }
        .formStyle(.grouped)
    }
}
