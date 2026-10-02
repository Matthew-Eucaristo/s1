import SwiftUI
import S1Core

/// The S1 macOS app — Liquid Glass shell + menu-bar companion over S1Core.
@available(macOS 26, *)
@main
struct S1App: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("s1", id: "s1") {
            ContentView(model: model)
        }
        .windowStyle(.automatic)
        .defaultSize(width: 880, height: 620)

        // The always-on companion lives here: menu bar presence, global
        // hotkey armed, listening/running state at a glance.
        MenuBarExtra("s1", systemImage: "waveform") {
            MenuBarView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

@available(macOS 26, *)
private struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("s1").font(.headline)
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
            Button("Open s1") {
                openWindow(id: "s1")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button("Quit s1") { NSApp.terminate(nil) }
        }
        .padding(12)
        .frame(width: 250)
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
