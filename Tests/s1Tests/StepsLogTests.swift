import XCTest
@testable import s1

/// steps.jsonl is the audit trail: every step must produce exactly one valid
/// JSON line with the agreed schema.
final class StepsLogTests: XCTestCase {
    private var tempDir: String!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-steps-\(UUID().uuidString)")
            .path
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(atPath: tempDir)
        }
    }

    private var logPath: String {
        URL(fileURLWithPath: tempDir).appendingPathComponent("steps.jsonl").path
    }

    func testStepsJSONLIsCreatedAndWellFormed() throws {
        let script = [
            Action(kind: "move_mouse", x: 5, y: 5, confidence: 0.9),
            Action(kind: "wait", seconds: 0.01, confidence: 1.0),
            Action(kind: "key_press", key: "enter", confidence: 0.5), // gated
        ]
        let records = try Loop.run(policy: DummyPolicy(script: script),
                                   steps: 3,
                                   runDir: tempDir,
                                   actuator: Actuator(dryRun: true),
                                   perceiver: MockPerceiver())
        XCTAssertEqual(records.count, 3)

        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath))
        let content = try String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)
        let lines = content.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)

        for (index, line) in lines.enumerated() {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            let record = try XCTUnwrap(object, "line \(index) must be a JSON object")
            for key in ["ts", "step", "observation", "action", "gate", "result", "confidence"] {
                XCTAssertNotNil(record[key], "missing key '\(key)' in line \(index)")
            }
            XCTAssertEqual((record["step"] as? NSNumber)?.intValue, index)
            XCTAssertFalse((record["ts"] as? String ?? "").isEmpty)
        }

        // The gated enter press must be recorded as rejected, with its gate
        // decision and confidence intact.
        let lastObject = try JSONSerialization.jsonObject(with: Data(lines[2].utf8)) as? [String: Any]
        let lastRecord = try XCTUnwrap(lastObject)
        XCTAssertEqual((lastRecord["result"] as? [String: Any])?["status"] as? String, "rejected")
        XCTAssertEqual(((lastRecord["gate"] as? [String: Any])?["allowed"] as? NSNumber)?.boolValue, false)
        XCTAssertEqual((lastRecord["confidence"] as? NSNumber)?.doubleValue, 0.5)
    }

    func testPolicyStoppingEarlyEndsTheLoop() throws {
        let records = try Loop.run(policy: DummyPolicy(script: [Action(kind: "wait", seconds: 0.01)]),
                                   steps: 5,
                                   runDir: tempDir,
                                   actuator: Actuator(dryRun: true),
                                   perceiver: MockPerceiver())
        XCTAssertEqual(records.count, 1)

        let content = try String(contentsOf: URL(fileURLWithPath: logPath), encoding: .utf8)
        XCTAssertEqual(content.split(separator: "\n").count, 1)
    }
}
