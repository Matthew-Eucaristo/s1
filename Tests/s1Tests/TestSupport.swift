import Foundation
@testable import s1

/// Deterministic perceiver for tests: never touches the real machine.
struct MockPerceiver: Perceiver {
    func observe(runDir: String) -> Observation {
        Observation(ts: "2026-01-01T00:00:00.000Z",
                    screenshot: "/mock/shot.png",
                    windowCount: 2,
                    windowTitles: ["window-a", "window-b"],
                    axFocusedApp: "MockApp",
                    errors: [])
    }
}

/// Backend spy: records every performed action, so tests can prove that a
/// dry-run performs none and a live run performs them all.
final class RecordingBackend: ActionBackend {
    private(set) var calls: [Action] = []

    func perform(_ action: Action) throws -> String {
        calls.append(action)
        return "ok"
    }
}
