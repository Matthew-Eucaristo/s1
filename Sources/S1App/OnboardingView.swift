import SwiftUI
import S1Core

/// First-run setup — opens until `onboarded` lands in config.json, and from
/// the app menu ("Set Up s1…"). Only what s1 genuinely needs, every step
/// skippable, the recommended choice always the default button.
/// `s1 setup` is the same flow in Terminal.
@available(macOS 26, *)
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var step = Step.welcome
    @State private var forward = true
    /// Asked once — after that, Continue works with or without the grant.
    @State private var askedForAccess = false

    enum Step: Int, CaseIterable { case welcome, permissions, models, executor, ready }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                page(step)
                    .id(step)
                    .transition(reduceMotion ? .opacity : .asymmetric(
                        insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                        removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()

            HStack {
                if step == .welcome {
                    Button("Skip Setup") { finish() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                } else {
                    Button("Back") { go(-1) }
                }
                Spacer()
                HStack(spacing: 7) {
                    ForEach(Step.allCases, id: \.self) { s in
                        Capsule()
                            .fill(s == step ? model.accent : Color.secondary.opacity(0.3))
                            .frame(width: s == step ? 18 : 7, height: 7)
                    }
                }
                .animation(.smooth, value: step)
                .accessibilityHidden(true)
                Spacer()
                Button(primaryTitle) { primary() }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    .keyboardShortcut(.defaultAction)
                    .disabled(step == .executor && model.cuaInstalling)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
        }
        .frame(width: 620, height: 560)
        .background(.background)
        .tint(model.accent)
    }

    // MARK: pages

    @ViewBuilder
    private func page(_ s: Step) -> some View {
        switch s {
        case .welcome: welcome
        case .permissions: permissions
        case .models: models
        case .executor: executor
        case .ready: ready
        }
    }

    private func header(_ symbol: String, _ tint: Color, _ title: LocalizedStringKey,
                        _ body: LocalizedStringKey) -> some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 76, height: 76)
                .glassEffect(.regular.tint(tint.opacity(0.18)), in: .circle)
                .symbolEffect(.bounce, value: step)
            Text(title)
                .font(.system(size: 26, weight: .bold))
            Text(body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
        }
    }

    private var welcome: some View {
        VStack(spacing: 26) {
            Spacer()
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
                .accessibilityHidden(true)
            VStack(spacing: 8) {
                Text("Welcome to s1")
                    .font(.system(size: 32, weight: .bold))
                Text("Say what you want done. s1 does it on your Mac — and shows every step it took.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            VStack(alignment: .leading, spacing: 12) {
                feature("waveform", "Talk from anywhere", "Double-tap ⇧, then just say it.")
                feature("bolt", "Instant for the everyday", "Opening, typing and shortcuts need no model at all.")
                feature("checkmark.shield", "Careful by design", "Passwords, purchases and anything irreversible wait for you.")
            }
            .frame(maxWidth: 400)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private func feature(_ symbol: String, _ title: LocalizedStringKey, _ detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary)
            }
        }
    }

    private var permissions: some View {
        VStack(spacing: 24) {
            Spacer()
            header("hand.raised.fill", .orange, "Let s1 use your Mac",
                   "Only Accessibility is required. The rest unlock the shortcut, your voice and screenshots.")
            VStack(spacing: 4) {
                PermissionRow(title: "Accessibility", detail: "Required — see and use apps.",
                              granted: model.permissions.accessibility, pane: .accessibility)
                PermissionRow(title: "Input Monitoring", detail: "The ⇧⇧ shortcut.",
                              granted: model.permissions.inputMonitoring, pane: .inputMonitoring)
                PermissionRow(title: "Microphone", detail: "Voice commands.",
                              granted: model.permissions.microphone, pane: .microphone)
                PermissionRow(title: "Screen Recording", detail: "Checking work with screenshots.",
                              granted: model.permissions.screenRecording, pane: .screenRecording)
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 480)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var models: some View {
        VStack(spacing: 22) {
            Spacer()
            header("sparkles", model.accent, "Pick your models",
                   "Optional. The built-in grammar needs no model. Add a Judge (System 1) to pick targets and check results, and a Reasoner (System 2) to plan everything else.")
            VStack(spacing: 10) {
                QuickConnect(model: model, id: "typesafe", role: .judge)
                QuickConnect(model: model, id: "opencode", role: .reasoner)
            }
            .frame(maxWidth: 480)
            Button("Use a different provider…") { pickingOther = true }
                .buttonStyle(.link)
            Spacer()
        }
        .padding(.horizontal, 40)
        .sheet(isPresented: $pickingOther) { AddProviderSheet(model: model) }
    }
    @State private var pickingOther = false

    private var executor: some View {
        VStack(spacing: 22) {
            Spacer()
            header("cursorarrow.rays", .blue, "Work in the background",
                   "Cua Driver lets s1 type and press keys without taking over your cursor or focus. Installed with CUA's official installer.")
            Group {
                if CuaInstaller.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.headline)
                } else if model.cuaInstalling || !model.cuaInstallLog.isEmpty {
                    ScrollView {
                        Text(model.cuaInstallLog.isEmpty ? String(localized: "Installing…") : model.cuaInstallLog)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .defaultScrollAnchor(.bottom)
                    .frame(height: 120)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 12))
                } else {
                    Text("You can skip this — s1 falls back to its own input path.")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 480)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var ready: some View {
        VStack(spacing: 24) {
            Spacer()
            header("checkmark.seal.fill", .green, "You're all set",
                   "Try it now: double-tap ⇧ and say “open Notes”. Or type in the s1 window.")
            VStack(spacing: 12) {
                LabeledContent("Talk to s1") { KeyCaps(keys: ["⇧", "⇧"]) }
                LabeledContent("Launcher") { KeyCaps(keys: ["⌥", "Space"]) }
                LabeledContent("Dictate anywhere") { KeyCaps(keys: ["⌃", "⌥", "D"]) }
                Divider()
                Toggle("Open s1 at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { _ in model.toggleLoginItem() }))
            }
            .padding(16)
            .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 16, style: .continuous))
            .frame(maxWidth: 380)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    // MARK: navigation

    private var primaryTitle: LocalizedStringKey {
        switch step {
        case .welcome: "Get Started"
        case .permissions: model.permissions.accessibility || askedForAccess ? "Continue" : "Grant Access"
        case .models: model.models.providers.isEmpty ? "Skip for Now" : "Continue"
        case .executor:
            CuaInstaller.installed || !model.cuaInstallLog.isEmpty || model.cuaInstalling ? "Continue" : "Install"
        case .ready: "Start Using s1"
        }
    }

    private func primary() {
        switch step {
        case .permissions where !model.permissions.accessibility && !askedForAccess:
            askedForAccess = true
            model.requestPermissions()
        case .executor where !CuaInstaller.installed && model.cuaInstallLog.isEmpty && !model.cuaInstalling:
            Task { await model.installCuaDriver() }
        case .ready:
            finish()
        default:
            go(1)
        }
    }

    private func go(_ delta: Int) {
        guard let next = Step(rawValue: step.rawValue + delta) else { return }
        forward = delta > 0
        withAnimation(.smooth(duration: 0.35)) { step = next }
    }

    private func finish() {
        model.markOnboarded()
        dismissWindow(id: "onboarding")
    }
}

/// One recommended provider as an inline card: paste the key, done.
@available(macOS 26, *)
private struct QuickConnect: View {
    let model: AppModel
    let id: String
    let role: ModelRole
    @State private var key = ""
    @State private var working = false
    @State private var error: String?

    private var template: ProviderTemplate { ProviderCatalog.template(id)! }
    private var connected: Bool { model.models.providers.contains { $0.id == id } }

    var body: some View {
        HStack(spacing: 12) {
            ProviderBadge(template: template, size: 34)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(template.name).font(.headline)
                    Text(role.short)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(.tint.opacity(0.15), in: .capsule)
                        .foregroundStyle(.tint)
                }
                if connected {
                    Label("Connected", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                } else {
                    HStack {
                        SecureField(template.keyHint ?? "API key", text: $key)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { Task { await connect() } }
                        if working {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Connect") { Task { await connect() } }
                                .disabled(key.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                    } else if let link = template.keyURL, let u = URL(string: link) {
                        Link("Get a key at \(u.host ?? link)", destination: u).font(.caption)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 14, style: .continuous))
        .animation(.smooth, value: connected)
    }

    private func connect() async {
        working = true
        defer { working = false }
        error = nil
        if case .failure(let f) = await model.models.connect(ProviderConfig(id: id), key: key) {
            error = f.message
        } else {
            key = ""
        }
    }
}
