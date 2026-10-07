import AVFoundation
import SwiftUI
import S1Core

/// The standard Settings window (⌘,), grouped by what each pane changes.
struct SettingsView: View {
    @Bindable var model: AppModel

    var body: some View {
        TabView(selection: $model.settingsTab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings(model: model) }
            Tab("Models", systemImage: "cpu", value: "models") { ModelsSettings(model: model) }
            Tab("Usage", systemImage: "chart.bar.xaxis", value: "usage") { UsageSettings() }
            Tab("Voice", systemImage: "waveform", value: "voice") { VoiceSettings(model: model) }
            Tab("Snippets", systemImage: "text.badge.plus", value: "snippets") { SnippetSettings() }
            Tab("Permissions", systemImage: "hand.raised", value: "permissions") { PermissionSettings(model: model) }
            Tab("Advanced", systemImage: "gearshape.2", value: "advanced") { AdvancedSettings(model: model) }
        }
        .frame(width: 640, height: 600)
        .tint(model.accent)
        .onAppear { model.refreshPermissions() }
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Bindable var model: AppModel
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section {
                Toggle("Open s1 at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLoginItem() }))
                Toggle("Keep running in the menu bar", isOn: $model.keepRunning)
                Toggle("Show status under the notch", isOn: $model.notchHUD)
            } footer: {
                FootNote("Closing the window keeps s1 in the menu bar so ⇧⇧, the launcher and dictation still work; it uses no microphone and almost no power while idle. Turn it off to quit when the window closes. The status pill appears only while s1 listens or works.")
            }

            Section {
                Picker("Accent color", selection: $model.accentChoice) {
                    Label { Text("s1 Orange") } icon: { Image(systemName: "circle.fill").foregroundStyle(Theme.orange) }
                        .tag(AccentChoice.s1)
                    Label { Text("System Accent") } icon: { Image(systemName: "circle.fill").foregroundStyle(Color(nsColor: .controlAccentColor)) }
                        .tag(AccentChoice.system)
                }
            } header: {
                Text("Appearance")
            } footer: {
                FootNote("System Accent follows System Settings → Appearance.")
            }

            Section("Shortcuts") {
                LabeledContent("Talk to s1") {
                    HStack(spacing: 8) {
                        KeyCaps(keys: ["⇧", "⇧"])
                        Text("or").foregroundStyle(.secondary)
                        KeyCaps(keys: ["⌃", "⌥", "Space"])
                    }
                }
                LabeledContent("Launcher") { KeyCaps(keys: ["⌥", "Space"]) }
                LabeledContent("Dictate anywhere") { KeyCaps(keys: ["⌃", "⌥", "D"]) }
            }

            Section {
                Picker("Language", selection: $model.appLanguage) {
                    Text("System Default").tag("system")
                    Divider()
                    ForEach(model.appLanguageOptions, id: \.id) { o in Text(o.name).tag(o.id) }
                }
                if model.languageNeedsRelaunch {
                    LabeledContent("Takes effect after a restart") {
                        Button("Restart s1") { model.relaunchApp() }
                    }
                }
            } header: {
                Text("App Language")
            } footer: {
                FootNote("Menus and labels. The language s1 listens for is under Voice.")
            }

            Section {
                Toggle("Remember what I ask it to", isOn: Binding(
                    get: { Memory.enabled() },
                    set: { on in try? S1Config.update { $0.memory = on ? nil : false } }))
                LabeledContent("Memory and skills") {
                    HStack {
                        Button("Show Memory") {
                            if !FileManager.default.fileExists(atPath: Memory.path.path) { try? Memory.clear() }
                            NSWorkspace.shared.open(Memory.path)
                        }
                        Button("Show Skills") {
                            S1Home.ensurePrivate()
                            try? FileManager.default.createDirectory(at: Skills.dir, withIntermediateDirectories: true)
                            NSWorkspace.shared.open(Skills.dir)
                        }
                        Button("Clear Memory…", role: .destructive) { confirmClear = true }
                    }
                }
            } header: {
                Text("Memory")
            } footer: {
                FootNote("Say “remember that …” to keep a fact (never passwords or keys). After something works, say “save that as a skill called morning setup” — then just say “morning setup”. Plain files in ~/.s1.")
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Clear everything s1 remembers?", isPresented: $confirmClear) {
            Button("Clear Memory", role: .destructive) { try? Memory.clear() }
        } message: {
            Text("Saved skills are kept.")
        }
    }
}

// MARK: - Voice

private struct VoiceSettings: View {
    @Bindable var model: AppModel
    @State private var newWord = ""
    @State private var addingProvider = false

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
                    ForEach(SpokenLanguage.pickerOptions, id: \.id) { o in Text(o.name).tag(o.id) }
                }
                LabeledContent {
                    RoleMenu(store: model.models, role: .transcribe) { addingProvider = true }
                } label: {
                    Text("Recognition")
                    if let p = model.models.problem(.transcribe) {
                        Text(p.description).foregroundStyle(.orange)
                    }
                }
                Toggle("Stop when I talk over s1", isOn: $model.voiceInterrupt)
                Picker("End of speech", selection: $model.vadSensitivity) {
                    Text("Patient — allows pauses").tag("low")
                    Text("Balanced").tag("medium")
                    Text("Quick — ends right away").tag("high")
                }
                Picker("Detection", selection: $model.vadMode) {
                    Text("Automatic").tag("auto")
                    Text("Volume only").tag("energy")
                }
            } header: {
                Text("Listening")
            } footer: {
                FootNote(model.models.assignment(.transcribe) == nil
                     ? "Speech is recognized on this Mac. Automatic listens in English and your Mac's language at once."
                     : "Live text still runs on this Mac; each finished turn is re-transcribed in the cloud, falling back to on-device on any error.")
            }

            Section {
                ForEach(model.vocabularyList, id: \.self) { w in
                    HStack {
                        Text(w)
                        Spacer()
                        Button { model.removeVocabularyWord(w) } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Remove \(w)")
                    }
                }
                HStack {
                    TextField("Add a word or name", text: $newWord)
                        .onSubmit(addWord)
                    Button("Add", action: addWord)
                        .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Custom Words")
            } footer: {
                FootNote("Names the recognizer misspells. s1 already learns your installed apps, skill names and remembered names.")
            }

            Section {
                Toggle("Speak replies", isOn: $model.speakReply)
                LabeledContent {
                    RoleMenu(store: model.models, role: .speak) { addingProvider = true }
                } label: {
                    Text("Voice")
                    if let p = model.models.problem(.speak) {
                        Text(p.description).foregroundStyle(.orange)
                    }
                }
                .disabled(!model.speakReply)
                if model.models.assignment(.speak) == nil {
                    Picker("Apple voice", selection: $model.ttsVoice) {
                        Text("Best installed").tag("")
                        Divider()
                        ForEach(voices, id: \.identifier) { v in
                            Text("\(v.name) — \(v.language)\(Self.qualityTag(v.quality))").tag(v.identifier)
                        }
                    }
                    .disabled(!model.speakReply)
                } else {
                    TextField("Voice name", text: $model.cloudVoice, prompt: Text("troy"))
                        .disabled(!model.speakReply)
                }
                LabeledContent("") {
                    Button("Preview") { model.previewVoice() }.disabled(!model.speakReply)
                }
            } header: {
                Text("Speaking")
            } footer: {
                FootNote("Replies use the language you spoke. For the most natural Apple voice, download a Premium voice in System Settings → Accessibility → Spoken Content.")
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $addingProvider) { AddProviderSheet(model: model) }
    }

    private func addWord() {
        model.addVocabularyWord(newWord)
        newWord = ""
    }

    static func qualityTag(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: " · Premium"
        case .enhanced: " · Enhanced"
        default: ""
        }
    }
}

// MARK: - Permissions

private struct PermissionSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            Section {
                PermissionRow(title: "Accessibility", detail: "Required — how s1 sees and uses your Mac.",
                              granted: model.permissions.accessibility, pane: .accessibility)
                PermissionRow(title: "Input Monitoring", detail: "The ⇧⇧ and ⌃⌥Space shortcuts.",
                              granted: model.permissions.inputMonitoring, pane: .inputMonitoring)
                PermissionRow(title: "Microphone", detail: "Voice commands and dictation.",
                              granted: model.permissions.microphone, pane: .microphone)
                PermissionRow(title: "Screen Recording", detail: "Screenshots for checking work and vision models.",
                              granted: model.permissions.screenRecording, pane: .screenRecording)
            } footer: {
                FootNote("Only Accessibility is required. Screen Recording applies after s1 restarts.")
            }
            Section {
                LabeledContent("Accessibility") {
                    Button("Repair") { model.resetAccessibility() }
                }
                LabeledContent("Screen Recording") {
                    HStack {
                        Button("Repair") { model.resetScreenRecording() }
                        Button("Restart s1") { model.relaunchApp() }
                    }
                }
            } header: {
                Text("On in System Settings but not working?")
            } footer: {
                FootNote("A switch can belong to an older copy of s1. Repair removes it and asks again; turn it back on, then restart s1 for Screen Recording.")
            }
        }
        .formStyle(.grouped)
    }
}

struct PermissionRow: View {
    let title: LocalizedStringKey
    let detail: LocalizedStringKey
    let granted: Bool
    let pane: PermissionPane

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .contentTransition(.symbolEffect(.replace))
                .accessibilityLabel(granted ? "granted" : "not granted")
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted {
                Button("Open Settings") { pane.open() }
                    .controlSize(.small)
            }
        }
        .animation(.smooth, value: granted)
    }
}

// MARK: - Advanced

private struct AdvancedSettings: View {
    @Bindable var model: AppModel
    @State private var doctor: [Doctor.Item]?

    var body: some View {
        Form {
            Section {
                Toggle("Act in the background with Cua Driver", isOn: Binding(
                    get: { CuaDriver.enabled() },
                    set: { on in try? S1Config.update { $0.executor = on ? nil : "cgevent" } }))
                    .disabled(CuaDriver.binary() == nil)
                if CuaDriver.binary() != nil, CuaDriver.enabled() {
                    LabeledContent("Cua Driver's own permissions") {
                        Button("Grant…") {
                            CuaActuator.resetAvailability()
                            Task.detached { try? await CuaInstaller.grantPermissions() }
                        }
                    }
                }
                if CuaDriver.binary() == nil {
                    LabeledContent("Cua Driver isn't installed") {
                        Button(model.cuaInstalling ? "Installing…" : "Install") {
                            Task { await model.installCuaDriver() }
                        }
                        .disabled(model.cuaInstalling)
                    }
                    if let last = model.cuaInstallLog.split(separator: "\n").last {
                        Text(last).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Executor")
            } footer: {
                FootNote("Recommended. Typing, shortcuts and app launches run without stealing focus; anything else uses s1's own input path. Cua Driver is a separate app and needs its own Accessibility and Screen Recording; until it has them, s1 acts directly. The safety gate runs first either way.")
            }

            Section {
                Toggle("Sandbox shell commands", isOn: $model.sandboxSrt)
                    .disabled(Sandbox.srtBinary() == nil)
            } header: {
                Text("Shell Sandbox")
            } footer: {
                FootNote(Sandbox.srtBinary() == nil
                     ? "Runs shell steps inside Anthropic's sandbox-runtime. Install it with `npm install -g @anthropic-ai/sandbox-runtime`."
                     : "Shell steps run under ~/.s1/srt-settings.json. If the sandbox fails, the step fails — it never runs unsandboxed.")
            }

            Section {
                ForEach(configFiles, id: \.0) { name, url, ensure in
                    LabeledContent(name) {
                        Button("Open") { ensure(); NSWorkspace.shared.open(url) }
                    }
                }
                LabeledContent("Check every file") {
                    Button("Run Checks") {
                        Task { doctor = await Task.detached { Doctor.run() }.value }
                    }
                }
                if let doctor {
                    ForEach(Array(doctor.enumerated()), id: \.offset) { _, item in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.what)
                                if !item.detail.isEmpty {
                                    Text(item.detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        } icon: {
                            Image(systemName: item.level == .ok ? "checkmark.circle.fill"
                                  : item.level == .warn ? "exclamationmark.triangle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(item.level == .ok ? .green : item.level == .warn ? .orange : .red)
                        }
                    }
                }
            } header: {
                Text("Configuration Files")
            } footer: {
                FootNote("Everything lives in plain files under ~/.s1. `s1 doctor` runs the same checks in Terminal.")
            }

            Section {
                LabeledContent("Run history") {
                    Button("Show in Finder") {
                        try? FileManager.default.createDirectory(at: RunHistory.root, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(RunHistory.root)
                    }
                }
            } footer: {
                FootNote("Every run keeps its steps and screenshots. The newest 50 are kept.")
            }
        }
        .formStyle(.grouped)
    }

    private var configFiles: [(String, URL, () -> Void)] {
        let home = S1Home.path
        let touch: (String, String) -> Void = { path, seed in
            if !FileManager.default.fileExists(atPath: path) {
                try? seed.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        return [
            ("config.json", URL(fileURLWithPath: home + "/config.json"), { try? S1Config.load().save() }),
            ("snippets.json", URL(fileURLWithPath: home + "/snippets.json"), { Snippets.ensureFile() }),
            ("convert.json", URL(fileURLWithPath: home + "/convert.json"), { touch(home + "/convert.json", "{}\n") }),
            ("srt-settings.json", URL(fileURLWithPath: home + "/srt-settings.json"), { Sandbox.ensureSettingsFile() }),
        ]
    }
}

// MARK: - Snippets

/// Snippet editor over ~/.s1/snippets.json — type the keyword in the ⌥Space
/// launcher and Return pastes the expansion where you were typing.
private struct SnippetSettings: View {
    @State private var items: [Snippet] = Snippets.load()
    @State private var selection: Int?
    @State private var saved = true

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                List(selection: $selection) {
                    ForEach(items.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(items[i].keyword.isEmpty ? String(localized: "Untitled") : items[i].keyword)
                                .font(.body.weight(.medium))
                            Text(items[i].text.replacingOccurrences(of: "\n", with: " "))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .tag(i)
                    }
                }
                Divider()
                HStack(spacing: 0) {
                    Button {
                        items.append(Snippet(keyword: "new", text: ""))
                        selection = items.count - 1
                        persist()
                    } label: { Image(systemName: "plus").frame(width: 24, height: 20) }
                    Button {
                        if let s = selection, items.indices.contains(s) {
                            items.remove(at: s); selection = nil; persist()
                        }
                    } label: { Image(systemName: "minus").frame(width: 24, height: 20) }
                    .disabled(selection == nil)
                    Spacer()
                    Menu {
                        Button("Restore Defaults") { items = Snippets.defaults; selection = nil; persist() }
                        Button("Open snippets.json") { Snippets.ensureFile(); NSWorkspace.shared.open(Snippets.path) }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }
                .buttonStyle(.borderless)
                .padding(6)
            }
            .frame(width: 220)
            Divider()
            Group {
                if let s = selection, items.indices.contains(s) {
                    Form {
                        TextField("Keyword", text: $items[s].keyword)
                        Section("Text") {
                            TextEditor(text: $items[s].text)
                                .font(.body.monospaced())
                                .frame(minHeight: 160)
                        }
                        Text("Placeholders: {date} {time} {datetime} {isodate} {weekday} {name} {uuid} {clipboard}")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .formStyle(.grouped)
                    .onChange(of: items[s].keyword) { persist() }
                    .onChange(of: items[s].text) { persist() }
                } else {
                    ContentUnavailableView("No Snippet Selected", systemImage: "text.badge.plus",
                                           description: Text("Type a snippet's keyword in the ⌥Space launcher to paste it."))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { items = Snippets.load() }
    }

    private func persist() { try? Snippets.save(items) }
}

// MARK: - About

enum AboutPanel {
    private static let credits: [(String, String, String)] = [
        ("Cua Driver", "MIT", "Background executor, used when installed"),
        ("swift-argument-parser", "Apache-2.0", "The s1 command line"),
        ("sandbox-runtime (Anthropic)", "Apache-2.0", "Optional shell sandbox"),
        ("Agent Memory Repo (Cognition)", "MIT", "The memory file layout"),
        ("Pi agent harness", "MIT", "Design reference: event stream, text-file skills"),
        ("AeriVoice", "MIT", "Design reference: hold-to-talk, live notch transcript"),
        ("Frankfurter", "MIT", "Currency rates (ECB reference data)"),
    ]

    @MainActor
    static func show() {
        let body = NSMutableAttributedString()
        let p = NSMutableParagraphStyle()
        p.alignment = .center
        p.paragraphSpacing = 6
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let bold = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        body.append(NSAttributedString(string: String(localized: "A voice-first agent for your Mac. Open source, MIT.\n\n"),
                                       attributes: [.font: small, .paragraphStyle: p, .foregroundColor: NSColor.labelColor]))
        for (name, license, use) in credits {
            body.append(NSAttributedString(string: "\(name) · \(license)\n",
                                           attributes: [.font: bold, .paragraphStyle: p, .foregroundColor: NSColor.labelColor]))
            body.append(NSAttributedString(string: use + "\n",
                                           attributes: [.font: small, .paragraphStyle: p, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        body.append(NSAttributedString(string: "\ngithub.com/Matthew-Eucaristo/s1",
                                       attributes: [.font: small, .paragraphStyle: p,
                                                    .link: URL(string: "https://github.com/Matthew-Eucaristo/s1")!]))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "s1",
            .applicationVersion: S1Info.version,
            .credits: body,
        ])
    }
}
