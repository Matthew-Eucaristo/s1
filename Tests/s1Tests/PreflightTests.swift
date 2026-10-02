import XCTest
@testable import s1

final class PreflightTests: XCTestCase {
    func testExitCodeFailsOnMissing() {
        let checks = [
            PreflightCheck(name: "A", status: .ok, detail: "fine"),
            PreflightCheck(name: "B", status: .missing, detail: "nope", fix: "do X"),
        ]
        XCTAssertEqual(Preflight.exitCode(checks), 1)
    }

    func testExitCodeSkippedIsNotAFailure() {
        let checks = [PreflightCheck(name: "platform", status: .skipped, detail: "not macOS")]
        XCTAssertEqual(Preflight.exitCode(checks), 0)
    }

    func testFormatIncludesFixAndFailureResult() {
        let checks = [
            PreflightCheck(name: "Screen Recording", status: .missing, detail: "NOT granted", fix: "enable it"),
            PreflightCheck(name: "Accessibility", status: .ok, detail: "granted"),
        ]
        let text = Preflight.format(checks)
        XCTAssertTrue(text.contains("Screen Recording"))
        XCTAssertTrue(text.contains("fix: enable it"))
        XCTAssertTrue(text.contains("some checks failed"))
    }

    func testFormatAllGood() {
        let checks = [PreflightCheck(name: "A", status: .ok, detail: "fine")]
        XCTAssertTrue(Preflight.format(checks).contains("all good"))
    }
}
