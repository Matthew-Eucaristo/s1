import Foundation
import CoreGraphics
import ImageIO

/// One immutable line in steps.jsonl — the evidence trail for a run.
public struct StepRecord: Codable, Sendable {
    public var index: Int
    public var time: Date
    public var observation: String            // Observation.summary
    public var decidedBy: String              // "s1:<policy>" | "s2:<reasoner>"
    public var confidence: Double?
    public var rationale: String?
    /// Raw LLM reply for this step (truncated) — the model's actual output.
    public var modelReply: String?
    public var action: Action?
    public var gate: String                   // GateVerdict.label
    public var outcome: String?               // actuator result summary
    public var verified: Bool?
    public var escalation: Escalation?

    public struct Escalation: Codable, Sendable {
        public var to: String                 // "s2:<reasoner>" | "human"
        public var reason: String
    }

    public func jsonLine() throws -> String {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(self)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Per-run artifact writer: <run>/meta.json, <run>/steps.jsonl, <run>/screens/.
public actor RunLogger {
    public nonisolated let runDir: URL
    public nonisolated let goal: String
    /// Optional live observer for each logged step (e.g. a UI feed).
    private let onStep: (@Sendable (StepRecord) -> Void)?
    private var stepCount = 0
    private let enc: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// `config` lands in meta.json — version/config fingerprint of the run.
    public init(goal: String, root: URL, config: [String: String],
                onStep: (@Sendable (StepRecord) -> Void)? = nil) throws {
        self.onStep = onStep
        self.goal = goal
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let slug = goal.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        runDir = root.appendingPathComponent("\(stamp)-\(slug)")
        try FileManager.default.createDirectory(at: runDir.appendingPathComponent("screens"), withIntermediateDirectories: true)
        var meta = config
        meta["goal"] = goal
        meta["started"] = ISO8601DateFormatter().string(from: Date())
        try enc.encode(meta).write(to: runDir.appendingPathComponent("meta.json"))
    }

    public func log(_ record: StepRecord) throws {
        let line = try record.jsonLine()
        let url = runDir.appendingPathComponent("steps.jsonl")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data((line + "\n").utf8)); try h.close()
        } else {
            try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
        }
        stepCount += 1
        onStep?(record)
    }

    private var shotCount = 0

    /// Save a CGImage as PNG under screens/ and return the repo-relative name.
    public func saveScreenshot(_ image: CGImage) throws -> String {
        let name = "step-\(shotCount).png"
        shotCount += 1
        let url = runDir.appendingPathComponent("screens/\(name)")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            throw S1Error.screenshotFailed("cannot create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw S1Error.screenshotFailed("png finalize failed")
        }
        return "screens/\(name)"
    }
}

public enum S1Error: Error, CustomStringConvertible, LocalizedError {
    case permissionMissing(String)
    case screenshotFailed(String)
    case axFailed(String)
    case aborted(String)

    public var description: String {
        switch self {
        case .permissionMissing(let p): return "missing permission: \(p)"
        case .screenshotFailed(let m): return "screenshot failed: \(m)"
        case .axFailed(let m): return "accessibility error: \(m)"
        case .aborted(let m): return "aborted: \(m)"
        }
    }

    public var errorDescription: String? { description }
}
