import AppIntents
import S1Core

/// Siri/Shortcuts/Spotlight integration — the Apple-native way to drive s1:
/// "Hey Siri, ask s1 to open TextEdit" hits RunGoalIntent; the Toggle intent
/// wakes/sleeps the listening companion. Everything lands on the same
/// AppModel the UI drives, so state stays coherent.
@available(macOS 26, *)
struct RunGoalIntent: AppIntent {
    static let title: LocalizedStringResource = "Run s1 Goal"
    static let description = IntentDescription(
        "Run a command in s1 — open apps, type, click — using the same agent loop the app drives.")
    // The run is visual by definition; bring the window forward so the
    // user watches it happen.
    static let openAppWhenRun = true

    @Parameter(title: "Goal")
    var goal: String

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let busy = await MainActor.run { () -> Bool in
            // Also refuse when a CLI agent owns the screen — otherwise the
            // dialog would announce a run that run() then refuses. Ask the
            // Serve object synchronously: the mirrored serveState lags a
            // MainActor hop and would let a Siri run start mid-companion-run.
            if AppModel.shared.running || AppModel.shared.serveIsListening
                || S1Runner.anotherRunActive() {
                return true
            }
            AppModel.shared.goal = goal
            Task { await AppModel.shared.run() }
            return false
        }
        if busy { return .result(dialog: "s1 is busy — a run is already in progress") }
        return .result(dialog: "Running in s1: \(goal)")
    }
}

@available(macOS 26, *)
struct ToggleListeningIntent: AppIntent {
    static let title: LocalizedStringResource = "Toggle s1 Listening"
    static let description = IntentDescription(
        "Wake or sleep the s1 voice companion — same as pressing the hotkey.")
    // No need to steal focus to flip a switch.
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let listening = await MainActor.run { () -> Bool in
            AppModel.shared.toggleServe()
            // The UI-mirrored serveState lags a Task hop — ask the Serve
            // object itself or the dialog lies about the toggle.
            return AppModel.shared.serveIsListening
        }
        return .result(dialog: listening ? "s1 is listening" : "s1 is asleep")
    }
}

@available(macOS 26, *)
struct S1Shortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunGoalIntent(),
            phrases: [
                "Ask \(.applicationName) to \(\.$goal)",
                "Run \(\.$goal) in \(.applicationName)",
            ],
            shortTitle: "Run Goal",
            systemImageName: "play.circle")
        AppShortcut(
            intent: ToggleListeningIntent(),
            phrases: [
                "Toggle \(.applicationName) listening",
                "Wake \(.applicationName)",
            ],
            shortTitle: "Toggle Listening",
            systemImageName: "mic.circle")
    }
}
