import XCTest
@testable import s1

final class CLITests: XCTestCase {
    func testParseRejectsInvalidInput() {
        XCTAssertNil(CLIMain.parse([]))
        XCTAssertNil(CLIMain.parse(["frobnicate"]))
        XCTAssertNil(CLIMain.parse(["dry-run", "--steps", "abc"]))
        XCTAssertNil(CLIMain.parse(["dry-run", "--steps", "0"]))
        XCTAssertNil(CLIMain.parse(["run", "--wat"]))
    }

    func testParseReadsOptions() {
        let options = CLIMain.parse(["run", "--policy", "dummy", "--steps", "7",
                                     "--run-dir", "/tmp/x", "--allow-destructive"])
        XCTAssertEqual(options?.command, "run")
        XCTAssertEqual(options?.steps, 7)
        XCTAssertEqual(options?.runDir, "/tmp/x")
        XCTAssertEqual(options?.allowDestructive, true)
    }

    func testDryRunCommandWritesLogAndReturnsZero() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("s1-cli-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        var output: [String] = []
        let code = CLIMain.run(arguments: ["dry-run", "--steps", "3", "--run-dir", tempDir],
                               perceiver: MockPerceiver(),
                               out: { output.append($0) })
        XCTAssertEqual(code, 0)
        let logPath = URL(fileURLWithPath: tempDir).appendingPathComponent("steps.jsonl").path
        XCTAssertTrue(FileManager.default.fileExists(atPath: logPath))
        XCTAssertTrue(output.contains { $0.contains("dry-run: no real actions were executed") })
        XCTAssertTrue(output.contains { $0.contains("log: \(tempDir)/steps.jsonl") })
    }

    func testPreflightCommandNeverCrashesOnAnyPlatform() {
        var output: [String] = []
        let code = CLIMain.run(arguments: ["preflight"], out: { output.append($0) })
        // 0 = all good / not applicable, 1 = missing permissions on macOS
        XCTAssertTrue(code == 0 || code == 1)
        XCTAssertTrue(output.joined(separator: "\n").contains("s1 preflight"))
    }

    func testEmptyArgumentsShowUsage() {
        var output: [String] = []
        let code = CLIMain.run(arguments: [], out: { output.append($0) })
        XCTAssertEqual(code, 2)
        XCTAssertTrue(output.joined().contains("usage:"))
    }
}
