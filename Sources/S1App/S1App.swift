import SwiftUI
import S1Core

/// The S1 macOS app — Liquid Glass shell + menu-bar companion over S1Core.
@available(macOS 26, *)
@main
struct S1App: App {
    // Shared so App Intents and the UI drive the same agent state.
    @State private var model = AppModel.shared

    var body: some Scene {
        WindowGroup("s1", id: "s1") {
            ContentView(model: model)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 880, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Command") {
                    model.goal = ""
                    model.focusGoalToken += 1
                }
                .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Agent") {
                Button("Run") { Task { await model.run() } }
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.running ||
                              model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop") { model.stop() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(!model.running)
                Divider()
                Button(model.serveState == .idle ? "Wake (start listening)" : "Sleep (stop listening)") {
                    model.toggleServe()
                }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                Button(model.listening ? "Stop Dictation" : "Dictate Command") { model.toggleListen() }
                    .keyboardShortcut("l", modifiers: .command)
                Divider()
                Button("Clear Steps") { model.clearFeed() }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(model.running || model.steps.isEmpty)
                Button("Reveal Run in Finder") { model.revealRunDir() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                    .disabled(model.runDir == nil)
            }
            CommandGroup(replacing: .help) {
                Button("s1 on GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/Matthew-Eucaristo/s1")!)
                }
            }
        }

        Settings {
            SettingsView(model: model)
        }

        // The always-on companion lives here: menu bar presence, global
        // hotkey armed, listening/running state at a glance. Label uses the
        // s1 mark as a template glyph (system tints it for light/dark);
        // falls back to an SF Symbol when built without the bundled PNGs.
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // State at a glance: the s1 glyph while idle, animated waveform
            // while listening, a badge while a run is in flight.
            switch model.serveState {
            case .idle:
                if let glyph = NSImage(named: "s1-menubar") {
                    Image(nsImage: { glyph.isTemplate = true; return glyph }())
                        .accessibilityLabel("s1, idle")
                } else {
                    Image(systemName: "waveform")
                        .accessibilityLabel("s1, idle")
                }
            case .listening:
                // The Siri tell Matthew asked for: live bars in the menu
                // bar itself — if his voice reaches the mic, they dance.
                LiveWaveform(barCount: 6, barWidth: 2.5, gap: 1.5)
                    .frame(width: 18, height: 15)
                    .accessibilityLabel("s1, listening")
            case .running:
                Image(systemName: "brain")
                    .accessibilityLabel("s1, running")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

@available(macOS 26, *)
private struct MenuBarView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    @FocusState private var goalFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("s1").font(.headline)
                if model.serveState == .listening {
                    LiveWaveform(barCount: 10)
                        .frame(width: 44, height: 14)
                        .accessibilityHidden(true)
                }
                Spacer()
                stateBadge
            }
            Text(model.serveStatus)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            if !model.transcript.isEmpty {
                Text("heard: \(model.transcript)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
            // Quick-goal: run a command without opening the window at all.
            HStack(spacing: 6) {
                TextField("Goal…", text: $model.goal)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout)
                    .focused($goalFocused)
                    .onSubmit { Task { await model.run() } }
                Button {
                    Task { await model.run() }
                } label: {
                    Image(systemName: "play.fill")
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .accessibilityLabel("Run")
                .disabled(model.running ||
                          model.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !model.recentGoals.isEmpty {
                Menu("Recent goals") {
                    ForEach(model.recentGoals.prefix(5), id: \.self) { g in
                        Button(g) { model.goal = g; Task { await model.run() } }
                    }
                }
                .controlSize(.small)
            }
            Divider()
            Button {
                model.toggleServe()
            } label: {
                Label(model.serveState == .idle ? "Listen (⇧⇧ / ⌃⌥Space)" : "Stop listening",
                      systemImage: model.serveState == .idle ? "mic.fill" : "stop.fill")
            }
            .buttonStyle(.glassProminent)
            Toggle("Launch at login", isOn: Binding(
                get: { model.launchAtLogin },
                set: { _ in model.toggleLoginItem() }))
            Divider()
            SettingsLink { Text("Settings…") }
                .keyboardShortcut(",", modifiers: .command)
            Button("Open s1") {
                openWindow(id: "s1")
                NSApp.activate()   // macOS 14+ API — ignores-other-apps is deprecated
            }
            Button("Quit s1") { model.shutdown() }
        }
        .padding(12)
        .frame(width: 250)
        .onAppear {
            // The popover window finishes appearing after onAppear; focusing
            // sooner makes it eat the first keystrokes.
            Task {
                try? await Task.sleep(for: .milliseconds(250))
                goalFocused = true
            }
        }
    }

    private var stateBadge: some View {
        let (text, color): (String, Color) = switch model.serveState {
        case .idle: ("idle", .secondary)
        case .listening: ("listening", .green)
        case .running: ("running", .orange)
        }
        return Text(text)
            .font(.caption2.weight(.bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(color.opacity(0.2), in: .capsule)
            .foregroundStyle(color)
    }
}
