import XCTest
@testable import s1

/// dry-run must exercise the whole loop (perceive -> decide -> gate -> log)
/// without ever performing a real action.
final class DryRunTests: XCTestCase {
    private let safeScript = [
        Action(kind: "move_mouse", x: 1, y: 1, confidence: 0.9),
        Action(kind: "click", x: 1, y: 1, confidence: 0.8),
        Action(kind: "type_text", text: "hi", confidence: 0.7),
    ]

    private var tempDir: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-dryrun-\(UUID().uuidString)")
            .path
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
    }

    func testDryRunNeverCallsTheBackend() throws {
        let backend = RecordingBackend()
        let records = try Loop.run(policy: DummyPolicy(script: safeScript),
                                   steps: 3,
                                   runDir: tempDir,
                                   actuator: Actuator(dryRun: true, backend: backend),
                                   perceiver: MockPerceiver())
        XCTAssertEqual(backend.calls.count, 0, "dry-run must not perform real actions")
        XCTAssertTrue(records.allSatisfy { $0.result.status == .dryRun })
    }

    func testLiveRunCallsTheBackend() throws {
        // Control experiment: proves the dry-run assertion above is meaningful
        // (the same setup without dryRun does reach the backend).
        let backend = RecordingBackend()
        let records = try Loop.run(policy: DummyPolicy(script: safeScript),
                                   steps: 3,
                                   runDir: tempDir,
                                   actuator: Actuator(dryRun: false, backend: backend),
                                   perceiver: MockPerceiver())
        XCTAssertEqual(backend.calls.count, 3)
        XCTAssertTrue(records.allSatisfy { $0.result.status == .executed })
    }

    func testDryRunStillAppliesTheGate() throws {
        let backend = RecordingBackend()
        let script = [Action(kind: "click", x: 1, y: 1, destructive: true)]
        let records = try Loop.run(policy: DummyPolicy(script: script),
                                   steps: 1,
                                   runDir: tempDir,
                                   actuator: Actuator(dryRun: true, backend: backend),
                                   perceiver: MockPerceiver())
        XCTAssertEqual(backend.calls.count, 0)
        XCTAssertEqual(records.first?.result.status, .rejected)
        XCTAssertEqual(records.first?.gate.allowed, false)
    }
}
