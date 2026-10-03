import SwiftUI
import S1Core

/// Liquid Glass shell: voice input up top, live step feed below,
/// brain/voice/permission controls in the sidebar.
@available(macOS 26, *)
struct ContentView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationSplitView {
            Form {
                Section("Brain — System 1") {
                    Picker("Policy", selection: $model.brain) {
                        ForEach(AppModel.Brain.allCases) { b in
                            Text(b.title).tag(b)
                        }
                    }
                    .pickerStyle(.inline)
                    Toggle("Escalate to S2 (LLM)", isOn: $model.useS2)
                }
                Section("Voice") {
                    Picker("Locale", selection: $model.locale) {
                        Text("Indonesia (id-ID)").tag("id-ID")
                        Text("English (en-US)").tag("en-US")
                    }
                    Toggle("Speak result (TTS)", isOn: $model.speakReply)
                    LabeledContent("Custom words") {
                        TextField("e.g. Warp, JIRA", text: $model.vocabulary)
                            .multilineTextAlignment(.trailing)
                    }
                    Text("STT also learns installed app names automatically — say an app name and it lands.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if model.brain == .vlm {
                    Section("Model endpoint — S1") {
                        TextField("Base URL", text: $model.vlmBase)
                        TextField("Model", text: $model.vlmModel)
                        Toggle("Attach screenshots", isOn: $model.vlmScreenshot)
                    }
                    .font(.callout)
                }
                if model.useS2 {
                    Section("Model endpoint — S2") {
                        TextField("Base URL", text: $model.s2Base)
                        TextField("Model", text: $model.s2Model)
                    }
                    .font(.callout)
                }
                Section("Permissions") {
                    permRow("Accessibility", ok: model.permissions.accessibility,
                            pane: "Privacy_Accessibility")
                    permRow("Screen recording", ok: model.permissions.screenRecording,
                            pane: "Privacy_ScreenCapture")
                    permRow("Microphone", ok: model.permissions.microphone,
                            pane: "Privacy_Microphone")
                    permRow("Input monitoring", ok: model.permissions.inputMonitoring,
                            pane: "Privacy_ListenEvent")
                    Button("Request / re-check") { model.requestPermissions() }
                    Text("Screen-recording grants apply on next app launch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationSplitViewColumnWidth(min: 230, ideal: 250)
        } detail: {
            VStack(spacing: 14) {
                if !model.permissions.ready { onboardingBanner }
                commandCard
                controlRow
                companionRow
                stepsFeed
                statusBar
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(minWidth: 740, minHeight: 540)
    }

    // MARK: - pieces

    private var commandCard: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Command — e.g. buka TextEdit lalu ketik halo", text: $model.goal, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...3)
                    .onSubmit { Task { await model.run() } }
                if !model.transcript.isEmpty {
                    Text("heard: \(model.transcript)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    ForEach(examples, id: \.self) { ex in
                        Button(ex) { model.goal = ex }
                            .buttonStyle(.glass)
                            .controlSize(.mini)
                    }
                    if !model.recentGoals.isEmpty {
                        Menu("Recent") {
                            ForEach(model.recentGoals, id: \.self) { g in
                                Button(g) { model.goal = g }
                            }
                        }
                        .controlSize(.mini)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular, in: .rect(cornerRadius: 18))
        }
    }

    /// First-run guidance: without AX + Screen Recording nothing works,
    /// so the biggest surface in the window points straight at the fix.
    private var onboardingBanner: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grant Accessibility + Screen Recording to begin")
                        .font(.callout.weight(.semibold))
                    Text("Each row in the sidebar has an Open Settings shortcut. Relaunch after granting Screen Recording.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Grant…") { model.requestPermissions() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.small)
            }
            .padding(12)
            .glassEffect(.regular.tint(.orange.opacity(0.25)), in: .rect(cornerRadius: 14))
        }
    }

    /// One-tap starters that exercise the common verbs.
    private var examples: [String] {
        model.locale.hasPrefix("id")
            ? ["buka TextEdit lalu ketik halo", "buka Notes", "tangkap layar"]
            : ["open TextEdit then type hello", "open Notes", "screenshot"]
    }

    private var controlRow: some View {
        GlassEffectContainer(spacing: 18) {
            HStack(spacing: 18) {
                Button {
                    model.toggleListen()
                } label: {
                    Image(systemName: model.listening ? "stop.fill" : "mic.fill")
                        .font(.system(size: 26, weight: .semibold))
                        .frame(width: 58, height: 58)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive().tint(
                    model.listening ? .red.opacity(0.55) : .accentColor.opacity(0.55)),
                    in: .circle)
                .help("Listen (20s), transcribe on-device, run")

                Button {
                    model.pickAudioAndTranscribe()
                } label: {
                    Label("Audio file", systemImage: "doc.waveform")
                }
                .buttonStyle(.glass)
                .help("Transcribe an audio file instead of the mic")

                Button {
                    Task { await model.run() }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(model.running || model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if model.running {
                    Button {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.glass)
                    .tint(.red)
                    .keyboardShortcut(".", modifiers: .command)
                }
                Spacer()
            }
        }
    }

    /// Always-on companion strip — same surface as the menu bar item.
    private var companionRow: some View {
        GlassEffectContainer {
            HStack(spacing: 10) {
                Circle()
                    .fill(model.serveState == .idle ? Color.secondary
                          : model.serveState == .listening ? .green : .orange)
                    .frame(width: 8, height: 8)
                Text(model.serveStatus)
                    .font(.callout)
                    .lineLimit(1)
                Spacer()
                Button(model.serveState == .idle ? "Listen" : "Sleep") {
                    model.toggleServe()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLoginItem() }))
                .toggleStyle(.checkbox)
                .font(.callout)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .rect(cornerRadius: 14))
        }
    }

    private var stepsFeed: some View {
        ScrollView {
            GlassEffectContainer(spacing: 10) {
                LazyVStack(spacing: 10) {
                    ForEach(Array(model.steps.enumerated()), id: \.offset) { _, rec in
                        stepRow(rec)
                    }
                    if model.steps.isEmpty {
                        Text(model.running ? "working…" : "steps land here")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 24)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
        .scrollIndicators(.automatic)
        .defaultScrollAnchor(.bottom)
    }

    private func stepRow(_ rec: StepRecord) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("#\(rec.index)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(actionLabel(rec.action))
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let out = rec.outcome {
                    Text(out)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if let esc = rec.escalation {
                Image(systemName: "arrow.up.right.circle")
                    .foregroundStyle(.orange)
                    .help("\(esc.to): \(esc.reason)")
            }
            if let conf = rec.confidence {
                Text(String(format: "%.2f", conf))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            badge(rec.decidedBy)
            if let v = rec.verified {
                Image(systemName: v ? "checkmark.seal.fill" : "xmark.seal")
                    .foregroundStyle(v ? .green : .red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        return Button { model.revealRunDir() } label: { row }
            .buttonStyle(.plain)
            .help("Reveal this run's artifacts")
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(model.status)
                .font(.callout)
            if let runDir = model.runDir {
                Button(runDir) { model.revealRunDir() }
                    .buttonStyle(.plain)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text("\(model.steps.count) steps")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 4)
    }

    private func permRow(_ label: String, ok: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
            Text(label).font(.callout)
            if !ok {
                Spacer()
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.mini)
            }
        }
    }

    private func badge(_ decidedBy: String) -> some View {
        let (text, color): (String, Color) = decidedBy.hasPrefix("s1")
            ? ("S1", .teal)
            : decidedBy.hasPrefix("s2") ? ("S2", .purple) : ("SYS", .gray)
        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2), in: .capsule)
            .foregroundStyle(color)
    }

    private var statusColor: Color {
        if model.running || model.listening { return .accentColor }
        switch model.status {
        case "done": return .green
        case "idle", "transcribed": return .secondary
        default: return model.status.hasPrefix("error") || model.status.hasPrefix("mic") || model.status.hasPrefix("stt") ? .red : .orange
        }
    }

    private func actionLabel(_ action: Action?) -> String {
        guard let action else { return "no action" }
        switch action {
        case .captureScreenshot(let r): return "screenshot — \(r)"
        case .verify(let e): return "verify — \(e)"
        case .done(let s): return "done — \(s)"
        case .moveMouse(let x, let y): return "move mouse (\(Int(x)), \(Int(y)))"
        case .click(let x, let y): return "click (\(Int(x)), \(Int(y)))"
        case .typeText(let t): return "type \"\(t)\""
        case .keyCombo(let k): return "keys \(k.joined(separator: "+"))"
        case .scroll(let dx, let dy): return "scroll (\(Int(dx)), \(Int(dy)))"
        case .axPress(let r): return "ax press \(r)"
        case .axSetValue(let r, let v): return "ax set \(r) = \"\(v)\""
        case .openApp(let n): return "open \(n)"
        case .wait(let s): return "wait \(s)s"
        case .shell(let c): return "shell: \(c)"
        case .custom(let n, _): return "custom: \(n)"
        }
    }
}
