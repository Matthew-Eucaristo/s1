import Foundation

/// Appends step records as JSONL to `<runDir>/steps.jsonl` — the audit trail.
///
/// Appends rather than overwrites, so consecutive runs accumulate; delete the
/// run directory to reset. One line per step:
///
///     {"ts": "...", "step": 0, "observation": {...}, "action": {...},
///      "gate": {"allowed": true, "risk": "safe", "reason": "ok"},
///      "result": {"status": "executed", "detail": "..."}, "confidence": 0.9}
public final class StepsLog {
    public let path: String

    public init(runDir: String) throws {
        let directory = URL(fileURLWithPath: runDir, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.path = directory.appendingPathComponent("steps.jsonl").path
    }

    public func append(_ record: StepRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record)
        data.append(0x0A) // trailing newline keeps it valid JSONL

        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: path) {
            _ = fileManager.createFile(atPath: path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
