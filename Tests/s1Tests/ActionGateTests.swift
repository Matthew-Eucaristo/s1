import XCTest
@testable import s1

/// The gate is the safety-critical part of v0: destructive and unknown
/// actions must be rejected unless explicitly permitted.
final class ActionGateTests: XCTestCase {
    private func dryActuator(allowDestructive: Bool = false) -> Actuator {
        Actuator(dryRun: true, allowDestructive: allowDestructive)
    }

    func testSafeActionAllowed() {
        let execution = dryActuator().execute(Action(kind: "move_mouse", x: 1, y: 2))
        XCTAssertTrue(execution.gate.allowed)
        XCTAssertEqual(execution.gate.risk, .safe)
        XCTAssertEqual(execution.result.status, .dryRun)
    }

    func testExplicitDestructiveRejected() {
        let execution = dryActuator().execute(Action(kind: "click", x: 1, y: 2, destructive: true))
        XCTAssertFalse(execution.gate.allowed)
        XCTAssertEqual(execution.gate.risk, .destructive)
        XCTAssertEqual(execution.result.status, .rejected)
    }

    func testExplicitDestructiveAllowedWithFlag() {
        let execution = dryActuator(allowDestructive: true)
            .execute(Action(kind: "click", x: 1, y: 2, destructive: true))
        XCTAssertTrue(execution.gate.allowed)
    }

    func testDeleteShortcutRejected() {
        let actuator = dryActuator()
        let actions = [
            Action(kind: "key_press", key: "delete", modifiers: ["cmd"]),
            Action(kind: "key_press", key: "cmd+delete"),
            Action(kind: "hotkey", keys: ["cmd", "shift", "delete"]),
        ]
        for action in actions {
            let execution = actuator.execute(action)
            XCTAssertFalse(execution.gate.allowed, "should be rejected: \(action)")
            XCTAssertEqual(execution.gate.risk, .destructive)
        }
    }

    func testEnterRejectedAsCommit() {
        let execution = dryActuator().execute(Action(kind: "key_press", key: "enter"))
        XCTAssertFalse(execution.gate.allowed)
        XCTAssertTrue(execution.gate.reason.contains("commit"))
    }

    func testUnknownKindRejected() {
        let execution = dryActuator().execute(Action(kind: "rm_rf", text: "/"))
        XCTAssertFalse(execution.gate.allowed)
        XCTAssertEqual(execution.gate.risk, .unknown)
        XCTAssertEqual(execution.result.status, .rejected)
    }

    func testKeyActionWithoutKeyNameRejected() {
        let execution = dryActuator().execute(Action(kind: "key_press"))
        XCTAssertFalse(execution.gate.allowed)
        XCTAssertEqual(execution.gate.risk, .unknown)
    }

    func testPlainBackspaceWithoutModifierIsSafe() {
        // backspace alone is reversible input; only the shortcuts are gated
        let execution = dryActuator().execute(Action(kind: "key_press", key: "delete"))
        XCTAssertTrue(execution.gate.allowed)
    }
}
