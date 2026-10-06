import AppKit
import Foundation
import S1Core

/// Screenshot mode: `S1_DEMO=1 open S1.app` shows a fixed sample
/// conversation and history instead of the real ones, and leaves the
/// hotkeys alone — so README and website shots never expose real runs.
enum DemoContent {
    static var enabled: Bool { ProcessInfo.processInfo.environment["S1_DEMO"] != nil }

    /// A consistent frame for screenshots, whatever the window last was.
    @MainActor
    static func sizeWindow() {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title.hasPrefix("s1") }),
              let screen = w.screen ?? NSScreen.main else { return }
        let size = NSSize(width: 1320, height: 860)
        let f = screen.visibleFrame
        w.setFrame(NSRect(x: f.midX - size.width / 2, y: f.midY - size.height / 2,
                          width: size.width, height: size.height), display: true)
    }

    static let recent = ["open Notes and write the shopping list", "turn the volume down a bit", "new tab in Safari"]

    @MainActor
    static func turns() -> [Turn] {
        [
            turn("turn the volume down a bit", spoken: true, state: .done, reply: String(localized: "Done."), seconds: 0.4, steps: [
                step(0, "s1:ax", 0.98, #"{"keyCombo":{"keys":["volumedown"]}}"#, "pressed", true),
                step(1, "s1:ax", 0.98, #"{"keyCombo":{"keys":["volumedown"]}}"#, "pressed", true),
            ]),
            turn("open Notes and write the shopping list", spoken: true, state: .done, reply: String(localized: "Done."), seconds: 3.1, steps: [
                step(0, "s1:ax", 0.98, #"{"openApp":{"name":"Notes"}}"#, "opened Notes", true),
                step(1, "s1:ax", 0.97, #"{"keyCombo":{"keys":["cmd","n"]}}"#, "pressed", nil),
                step(2, "s1:ax", 0.96, #"{"typeText":{"_0":"Shopping list: eggs, coffee, limes"}}"#, "typed 34 characters", nil),
                step(3, "s1:ax", 0.95, #"{"verify":{"expectation":"Shopping list"}}"#, "found on screen", true),
            ]),
            turn("sign in to my bank and pay the electricity bill", spoken: false, state: .needsYou,
                 reply: String(localized: "This one needs you — passwords and payments are always yours."), seconds: 2.4, steps: [
                step(0, "s1:ax", 0.97, #"{"openApp":{"name":"Safari"}}"#, "opened Safari", true),
                step(1, "s2:llm:gemini-2.5-flash", 0.82, #"{"axPress":{"ref":"AXButton 'Sign In'"}}"#, "pressed", true),
                step(2, "s2:llm:gemini-2.5-flash", 0.80, #"{"axSetValue":{"ref":"AXSecureTextField 'Password'","value":"•••"}}"#,
                     "blocked: secure field", nil, gate: "needsHuman(secure field)"),
            ]),
        ]
    }

    static func history() -> [RunSummary] {
        let now = Date()
        let rows: [(String, String, TimeInterval)] = [
            ("open Notes and write the shopping list", "done", -60),
            ("turn the volume down a bit", "done", -240),
            ("sign in to my bank and pay the electricity bill", "needsHuman", -30),
            ("new tab in Safari", "done", -3_600),
            ("buka Spotify lalu putar musik", "done", -5_400),
            ("remember that my editor is Zed", "done", -90_000),
            ("find the setting for dark mode", "done", -95_000),
            ("save that as a skill called morning setup", "done", -260_000),
        ]
        return rows.enumerated().map { i, r in
            RunSummary(dir: URL(fileURLWithPath: "/demo/\(i)"), goal: r.0,
                       started: now.addingTimeInterval(r.2), finished: now.addingTimeInterval(r.2 + 3),
                       status: r.1, summary: nil, steps: 3)
        }
    }

    @MainActor
    private static func turn(_ goal: String, spoken: Bool, state: Turn.State, reply: String,
                             seconds: TimeInterval, steps: [StepRecord]) -> Turn {
        var t = Turn(goal: goal, spoken: spoken)
        t.steps = steps
        t.state = state
        t.reply = reply
        t.finished = t.started.addingTimeInterval(seconds)
        return t
    }

    private static func step(_ i: Int, _ by: String, _ conf: Double, _ action: String, _ outcome: String,
                             _ verified: Bool?, gate: String = "allow") -> StepRecord {
        var json = #"{"index":\#(i),"time":"2026-10-06T09:41:00Z","observation":"","decidedBy":"\#(by)","confidence":\#(conf),"#
            + #""action":\#(action),"gate":"\#(gate)","outcome":"\#(outcome)""#
        if let verified { json += #","verified":\#(verified)"# }
        json += "}"
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try! dec.decode(StepRecord.self, from: Data(json.utf8))
    }
}
