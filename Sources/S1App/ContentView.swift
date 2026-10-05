import SwiftUI
import S1Core

/// Liquid Glass shell: voice input up top, live step feed below.
/// Everything configurable lives in Settings (⌘,).
@available(macOS 26, *)
struct ContentView: View {
    @Bindable var model: AppModel

    @FocusState private var goalFocused: Bool

    var body: some View {
        VStack(spacing: 14) {
            if !model.permissions.ready { onboardingBanner }
            else if !model.missingKeys.isEmpty { keysBanner }
            commandCard
            controlRow
            companionRow
            stepsFeed
            statusBar
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .frame(minWidth: 620, minHeight: 500)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                SettingsLink {
                    Label("Settings", systemImage: "gearshape")
                }
                .help("Settings (⌘,)")
            }
        }
        .onChange(of: model.focusGoalToken) { goalFocused = true }
        .onAppear { goalFocused = true }
    }

    // MARK: - pieces

    /// Hosted brains need a key once; until then s1 still runs on its
    /// deterministic grammar, so this is a hint, not a gate.
    private var keysBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "key.fill").foregroundStyle(.orange).accessibilityHidden(true)
            Text("Add an API key for \(model.missingKeys.joined(separator: " and ")) to turn on the hosted models.")
                .font(.callout)
            Spacer()
            SettingsLink { Text("Add Key…") }
        }
        .padding(10)
        .glassEffect(in: .rect(cornerRadius: 12))
    }

    private var commandCard: some View {
        GlassEffectContainer {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Command — e.g. buka TextEdit lalu ketik halo", text: $model.goal, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .lineLimit(1...3)
                    .focused($goalFocused)
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

    /// Names the grants still missing — the banner claims exactly what
    /// isn't granted yet rather than a hardcoded pair.
    private var missingPermissions: String {
        "Accessibility"
    }

    /// First-run guidance: without AX + Screen Recording nothing works,
    /// so the biggest surface in the window points straight at the fix.
    private var onboardingBanner: some View {
        GlassEffectContainer {
            HStack(spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.title2)
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Grant \(missingPermissions) to begin")
                        .font(.callout.weight(.semibold))
                    Text("Turn on S1 in Privacy & Security → Accessibility. Already on but still here? Click Fix — an updated app needs a fresh grant.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Fix") { model.resetAccessibility() }
                    .controlSize(.small)
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
        SpokenLanguage.code(SpokenLanguage.candidates(for: model.locale)[0]) == "id"
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
                .help("Dictate a command (⌘L) — on-device, auto language")
                .accessibilityLabel(model.listening ? "Stop listening" : "Listen")
                .accessibilityHint("Records a voice command, transcribes on-device, runs it")

                if model.listening {
                    // Live proof the mic is capturing — Siri-style bars,
                    // flat when it hears silence.
                    LiveWaveform()
                        .frame(width: 150, height: 30)
                        .transition(.opacity)
                        .accessibilityHidden(true)
                }

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
                    .accessibilityHidden(true)   // decorative; the text beside it carries state
                Text(model.serveStatus)
                    .font(.callout)
                    .lineLimit(1)
                if model.serveState == .listening {
                    LiveWaveform(barCount: 16)
                        .frame(width: 76, height: 16)
                        .accessibilityHidden(true)
                }
                Spacer()
                Button(model.serveState == .idle ? "Listen" : "Sleep") {
                    model.toggleServe()
                }
                .buttonStyle(.glass)
                .controlSize(.small)
                .help("Always-on companion (⌘⇧L, or ⇧⇧ / ⌃⌥Space anywhere)")
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
                    .accessibilityLabel("escalated to \(esc.to)")
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
                    .accessibilityLabel(v ? "verified" : "not verified")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
        return Button { model.revealRunDir() } label: { row }
            .buttonStyle(.plain)
            .help("Reveal this run's artifacts")
            // One spoken line per step instead of every child announced raw.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(stepSummary(rec))
            .accessibilityHint("Reveal run artifacts")
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)   // decorative; status text follows
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

    /// VoiceOver line for one step — action, outcome, brain, verification.
    private func stepSummary(_ rec: StepRecord) -> String {
        var s = "step \(rec.index): \(actionLabel(rec.action))"
        if let out = rec.outcome { s += ", \(out)" }
        s += ", \(rec.decidedBy.hasPrefix("s2") ? "system 2" : rec.decidedBy.hasPrefix("s1") ? "system 1" : "system")"
        if let esc = rec.escalation { s += ", escalated to \(esc.to)" }
        if let v = rec.verified { s += v ? ", verified" : ", verification failed" }
        return s
    }

    private func actionLabel(_ action: Action?) -> String {
        guard let action else { return "no action" }
        switch action {
        case .captureScreenshot(let r): return "screenshot — \(r)"
        case .verify(let e): return "verify — \(e)"
        case .done(let s): return "done — \(s)"
        case .moveMouse(let x, let y): return "move mouse (\(Int(x)), \(Int(y)))"
        case .click(let x, let y): return "click (\(Int(x)), \(Int(y)))"
        case .rightClick(let x, let y): return "right-click (\(Int(x)), \(Int(y)))"
        case .doubleClick(let x, let y): return "double-click (\(Int(x)), \(Int(y)))"
        case .drag(let fx, let fy, let tx, let ty):
            return "drag (\(Int(fx)), \(Int(fy))) → (\(Int(tx)), \(Int(ty)))"
        case .typeText(let t): return "type \"\(t)\""
        case .keyCombo(let k): return "keys \(k.joined(separator: "+"))"
        case .scroll(let dx, let dy): return "scroll (\(Int(dx)), \(Int(dy)))"
        case .axPress(let r): return "ax press \(r)"
        case .axSetValue(let r, let v): return "ax set \(r) = \"\(v)\""
        case .axAction(let r, let n): return "\(n) \(r)"
        case .axSetAttribute(let r, let a, let v): return "\(a)=\(v) \(r)"
        case .openApp(let n): return "open \(n)"
        case .wait(let s): return "wait \(s)s"
        case .shell(let c): return "shell: \(c)"
        case .custom(let n, _): return "custom: \(n)"
        }
    }
}
