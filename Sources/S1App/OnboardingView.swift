import SwiftUI
import S1Core

/// First-run setup wizard — opens once (until `onboarded` lands in
/// config.json) and walks the only things s1 genuinely needs:
///   welcome → permissions → Cua Driver → API keys → done.
/// Every step has a skip path; the recommended default is always the
/// button on the right. `s1 setup` is the same flow for the terminal.
@available(macOS 26, *)
struct OnboardingView: View {
    @Bindable var model: AppModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var step = 0
    @State private var decisionKey = ""
    @State private var s2Key = ""

    var body: some View {
        VStack(spacing: 0) {
            // Progress dots — five steps, current highlighted.
            HStack(spacing: 8) {
                ForEach(0..<5, id: \.self) { i in
                    Circle()
                        .fill(i == step ? Color.accentColor
                                        : i < step ? Color.accentColor.opacity(0.4)
                                                   : Color.secondary.opacity(0.25))
                        .frame(width: 7, height: 7)
                        .animation(.spring(response: 0.3), value: step)
                }
            }
            .padding(.top, 18)

            Group {
                switch step {
                case 0: welcomeStep
                case 1: permissionsStep
                case 2: cuaStep
                case 3: keysStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 36)

            Divider()
            footer
        }
        .frame(width: 560, height: 480)
    }

    // MARK: - steps

    private var welcomeStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "waveform.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse)
            Text("Welcome to s1").font(.largeTitle.weight(.bold))
            Text("A voice-first agent for your Mac — say it, watch it act,\n" +
                 "every step logged. Local-first and fully open source.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6) {
                Label("⇧⇧ or ⌃⌥Space wakes the listener", systemImage: "mic")
                Label("⌥Space opens the launcher", systemImage: "command.circle")
                Label("⌃⌥D dictates into whatever you're typing", systemImage: "keyboard")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.top, 6)
            Spacer()
        }
    }

    private var permissionsStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "hand.raised.circle.fill")
                .font(.system(size: 44)).foregroundStyle(.orange)
            Text("Permissions").font(.title.weight(.bold))
            Text("Only Accessibility is required — it's how s1 sees and\n" +
                 "touches your screen. The rest unlock extras.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) {
                PermRow(label: "Accessibility (required)",
                        ok: model.permissions.accessibility, pane: "Privacy_Accessibility")
                PermRow(label: "Input Monitoring (global hotkey)",
                        ok: model.permissions.inputMonitoring, pane: "Privacy_ListenEvent")
                PermRow(label: "Screen Recording (screenshots / vision)",
                        ok: model.permissions.screenRecording, pane: "Privacy_ScreenCapture")
                PermRow(label: "Microphone (voice commands)",
                        ok: model.permissions.microphone, pane: "Privacy_Microphone")
            }
            .frame(maxWidth: 420)
            Button("Request missing permissions") { model.requestPermissions() }
                .controlSize(.small)
            Spacer()
        }
    }

    private var cuaStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "cursorarrow.rays")
                .font(.system(size: 44)).foregroundStyle(.tint)
            Text("Cua Driver").font(.title.weight(.bold))
            Text("Recommended — s1 types, presses keys and launches apps in\n" +
                 "the background without stealing your focus. Installed with\n" +
                 "CUA's own installer; s1's built-in path is the fallback.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            if CuaInstaller.installed {
                Label("Already installed — nothing to do", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else if model.cuaInstalling || !model.cuaInstallLog.isEmpty {
                ScrollView {
                    Text(model.cuaInstallLog.isEmpty ? "installing…" : model.cuaInstallLog)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: 460, maxHeight: 110)
                .padding(8)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
            } else {
                Text(CuaInstaller.officialCommand)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(2)
                    .frame(maxWidth: 460)
            }
            Spacer()
        }
    }

    private var keysStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "key.fill").font(.system(size: 40)).foregroundStyle(.tint)
            Text("Model keys").font(.title.weight(.bold))
            Text("Optional — s1 acts on its own without them. Keys unlock the\n" +
                 "step judge and the reasoning brain. Stored in the Keychain.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            VStack(spacing: 12) {
                keyField(role: .decision, draft: $decisionKey,
                         title: "S1 decision judge — TypeSafe Jev",
                         hint: "typesafe.ai")
                keyField(role: .s2, draft: $s2Key,
                         title: "S2 reasoning — OpenCode Go (DeepSeek V4.1 Flash)",
                         hint: "opencode.ai")
            }
            .frame(maxWidth: 440)
            Spacer()
        }
    }

    private func keyField(role: ModelRole, draft: Binding<String>,
                          title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.callout.weight(.medium))
                Spacer()
                if model.hasKey(role) {
                    Label("saved", systemImage: "checkmark.circle.fill")
                        .font(.caption).foregroundStyle(.green)
                } else {
                    Link(hint, destination: URL(string: "https://\(hint)")!)
                        .font(.caption)
                }
            }
            HStack {
                SecureField(model.hasKey(role) ? "saved — type to replace" : "paste key (optional)",
                            text: draft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") { model.saveKey(draft.wrappedValue, for: role); draft.wrappedValue = "" }
                    .disabled(draft.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var doneStep: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 48)).foregroundStyle(.green)
            Text("You're set").font(.title.weight(.bold))
            Text("Try it: press ⇧⇧ and say “open Notes” — or type a goal\n" +
                 "in the window. Everything lives in ~/.s1 as plain files\n" +
                 "you can read, edit and check (`s1 doctor`).")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Toggle("Launch s1 at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { _ in model.toggleLoginItem() }))
            .frame(maxWidth: 240)
            Spacer()
        }
    }

    // MARK: - footer nav

    private var footer: some View {
        HStack {
            Button("Skip setup") { finish() }
                .foregroundStyle(.secondary)
                .controlSize(.small)
            Spacer()
            if step > 0 { Button("Back") { step -= 1 } }
            Button(step == 4 ? "Done"
                    : step == 2 && !CuaInstaller.installed && !model.cuaInstalling
                        && model.cuaInstallLog.isEmpty ? "Install & continue" : "Continue") {
                advance()
            }
            .buttonStyle(.borderedProminent)
            .disabled(step == 2 && model.cuaInstalling)
        }
        .padding(14)
    }

    private func advance() {
        if step == 2, !CuaInstaller.installed, !model.cuaInstalling,
           model.cuaInstallLog.isEmpty {
            // The recommended path is one click — the official installer
            // runs inline and Continue lights up again when it's done.
            Task { await model.installCuaDriver() }
            return
        }
        if step == 4 { finish() } else { step += 1 }
    }

    private func finish() {
        model.markOnboarded()
        dismissWindow(id: "onboarding")
    }
}
