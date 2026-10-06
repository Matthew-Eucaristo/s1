import SwiftUI
import S1Core

/// The s1 macOS app — one window, a menu-bar companion, Settings, and a
/// first-run setup, all over the same `AppModel`.
@available(macOS 26, *)
@main
struct S1App: App {
    @State private var model = AppModel.shared

    var body: some Scene {
        Window("s1", id: "s1") {
            ContentView(model: model)
                .frame(minWidth: 700, minHeight: 480)
        }
        .defaultSize(width: DemoContent.enabled ? 1320 : 1000, height: DemoContent.enabled ? 860 : 680)
        .windowToolbarStyle(.unified)
        .commands { S1Commands(model: model) }

        Window("Set Up s1", id: "onboarding") {
            OnboardingView(model: model)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView(model: model)
        }

        // The always-on companion: state at a glance, a quick command field.
        MenuBarExtra {
            MenuBarPanel(model: model)
        } label: {
            MenuBarLabel(state: model.serveState, running: model.running)
        }
        .menuBarExtraStyle(.window)
    }
}

@available(macOS 26, *)
private struct S1Commands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About s1") { AboutPanel.show() }
        }
        CommandGroup(after: .appInfo) {
            Button("Set Up s1…") {
                model.needsOnboarding = true
                openWindow(id: "onboarding")
            }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Command") {
                openWindow(id: "s1")
                model.focusGoalToken += 1
            }
            .keyboardShortcut("n")
            Button("Transcribe Audio File…") { model.pickAudioAndTranscribe() }
                .keyboardShortcut("o")
        }
        CommandMenu("Agent") {
            Button("Stop") { model.stop() }
                .keyboardShortcut(".")
                .disabled(!model.running && model.serveState != .running)
            Divider()
            Button(model.serveState == .idle ? "Start Listening" : "Stop Listening") { model.toggleServe() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button(model.listening ? "Stop Dictating" : "Speak a Command") { model.toggleListen() }
                .keyboardShortcut("l")
            Button("Show Launcher") { LauncherController.shared.show() }
                .keyboardShortcut(.space, modifiers: .option)
            Divider()
            Button("Clear Conversation") { model.clearConversation() }
                .keyboardShortcut("k")
                .disabled(model.running || model.turns.isEmpty)
        }
        CommandGroup(replacing: .help) {
            Button("s1 Website") { NSWorkspace.shared.open(URL(string: "https://s1-mac.pages.dev")!) }
            Button("s1 on GitHub") { NSWorkspace.shared.open(URL(string: "https://github.com/Matthew-Eucaristo/s1")!) }
        }
    }
}

/// Menu-bar glyph: the s1 mark at rest, live bars while listening, a
/// spinner-free "working" symbol while a run is in flight.
@available(macOS 26, *)
private struct MenuBarLabel: View {
    let state: Serve.State
    let running: Bool

    var body: some View {
        if state == .listening {
            LiveWaveform(barCount: 6, barWidth: 2.5, gap: 1.5)
                .frame(width: 18, height: 15)
                .accessibilityLabel("s1, listening")
        } else if state == .running || running {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("s1, working")
        } else if let glyph = NSImage(named: "s1-menubar") {
            Image(nsImage: { glyph.isTemplate = true; return glyph }())
                .accessibilityLabel("s1")
        } else {
            Image(systemName: "waveform")
                .accessibilityLabel("s1")
        }
    }
}

@available(macOS 26, *)
private struct MenuBarPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 28, height: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text("s1").font(.headline)
                    Text(stateLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
                Spacer()
                let on = model.serveState != .idle
                Button {
                    model.toggleServe()
                } label: {
                    Image(systemName: on ? "stop.fill" : "mic.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 30, height: 30)
                        .contentShape(.circle)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive().tint(on ? .red.opacity(0.55) : model.accent.opacity(0.35)), in: .circle)
                .help(on ? "Stop listening" : "Listen (⇧⇧)")
                .accessibilityLabel(on ? "Stop listening" : "Listen")
                .disabled(!model.companionAvailable)
            }

            if model.serveState == .listening || model.listening {
                HStack(spacing: 8) {
                    LiveWaveform(barCount: 16).frame(width: 60, height: 16)
                    Text(model.transcript.isEmpty ? String(localized: "Listening…") : model.transcript)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            } else if let t = model.currentTurn {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(t.steps.last.map { StepPresentation($0).title } ?? t.goal)
                        .font(.callout)
                        .lineLimit(1)
                    Spacer()
                    Button("Stop") { model.stop() }.controlSize(.small)
                }
            } else if let last = model.turns.last, let reply = last.reply {
                Label {
                    Text(reply).lineLimit(2)
                } icon: {
                    Image(systemName: last.state.symbol).foregroundStyle(last.state.tint)
                }
                .font(.callout)
            }

            HStack(spacing: 8) {
                TextField("Ask s1…", text: $model.goal)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .onSubmit { Task { await model.run() } }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
            }

            if !model.recentGoals.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(model.recentGoals.prefix(3), id: \.self) { g in
                        Button {
                            model.runAgain(g)
                        } label: {
                            Label(g, systemImage: "arrow.clockwise")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 3)
                        .disabled(model.running)
                    }
                }
                .font(.callout)
            }

            Divider()

            HStack {
                Button("Open s1") {
                    openWindow(id: "s1")
                    NSApp.activate()
                }
                Spacer()
                SettingsLink {
                    Image(systemName: "gearshape")
                }
                .help("Settings")
                Button {
                    model.shutdown()
                } label: {
                    Image(systemName: "power")
                }
                .help("Quit s1")
            }
            .buttonStyle(.borderless)
        }
        .padding(14)
        .frame(width: 300)
        .tint(model.accent)
        .onAppear {
            // The panel finishes appearing after onAppear; focusing sooner
            // makes it eat the first keystrokes.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                focused = true
            }
        }
    }

    private var stateLine: String {
        if !model.companionAvailable { return String(localized: "Companion off — terminal listener active") }
        switch model.serveState {
        case .listening: return String(localized: "Listening…")
        case .running: return String(localized: "Working…")
        case .idle: return model.running ? String(localized: "Working…") : String(localized: "Double-tap ⇧ to talk")
        }
    }
}
