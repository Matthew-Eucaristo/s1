import Foundation
import CoreGraphics
import ImageIO

/// One immutable line in steps.jsonl — the evidence trail for a run.
public struct StepRecord: Codable, Sendable {
    public var index: Int
    public var time: Date
    public var observation: String            // Snapshot.summary
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

    /// One-line human digest shared by the CLI feed, the serve log, and
    /// anywhere a step needs to read plainly: "[3] s1:ax 0.95 typeText → typed".
    /// Action args and outcomes are model/app-derived — sanitised so an
    /// escape sequence embedded in them can't inject ANSI/OSC into the
    /// terminal or log showing this line. (steps.jsonl keeps raw values:
    /// JSON escaping already makes it terminal-safe.)
    public var digest: String {
        var s = "[\(index)] \(decidedBy)"
        if let c = confidence { s += String(format: " %.2f", c) }
        if let a = action { s += " \(String(describing: a).terminalSafe)" }
        if let o = outcome { s += " → \(o.terminalSafe)" }
        if let v = verified { s += v ? " ✓" : " ✗verify" }
        if let e = escalation { s += " ⚑→\(e.to)" }
        return s
    }
}

extension String {
    /// Strip C0/C1/DEL control characters (incl. ESC) so text derived from
    /// models, apps, or audio transcripts can't inject ANSI/OSC escape
    /// sequences when printed to a terminal or written into serve.log.
    public var terminalSafe: String {
        String(unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
    }
}

/// Per-run artifact writer: <run>/meta.json, <run>/steps.jsonl, <run>/screens/.
/// `~/.s1` holds the config file (possibly API keys), pid locks, and
/// per-run artifacts with verbatim goal text + screenshots — owner-only,
/// same convention as `~/.ssh`. Idempotent and non-destructive.
public enum S1Home {
    public static let path = NSHomeDirectory() + "/.s1"

    public static func ensurePrivate() {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: path, withIntermediateDirectories: true)
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
}

public actor RunLogger {
    public nonisolated let runDir: URL
    public nonisolated let goal: String
    /// Optional live observer for each logged step (e.g. a UI feed).
    private let onStep: (@Sendable (StepRecord) -> Void)?
    private let enc: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e
    }()

    /// `config` lands in meta.json — version/config fingerprint of the run.
    public init(goal: String, root: URL, config: [String: String],
                onStep: (@Sendable (StepRecord) -> Void)? = nil) throws {
        self.onStep = onStep
        self.goal = goal
        S1Home.ensurePrivate()
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let slug = goal.lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            .prefix(40)
        // An emoji/CJK-only goal slugs to "" — name the dir "run" instead of
        // leaving a trailing dash. Also re-trim: prefix(40) can end mid-dash.
        let slugBase = String(slug).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let slugName = slugBase.isEmpty ? "run" : slugBase
        // Same goal in the same second (e.g. app + serve firing together)
        // would share one dir and interleave its steps.jsonl — uniquify.
        var candidate = root.appendingPathComponent("\(stamp)-\(slugName)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = root.appendingPathComponent("\(stamp)-\(slugName)-\(n)")
            n += 1
        }
        runDir = candidate
        try FileManager.default.createDirectory(at: runDir.appendingPathComponent("screens"), withIntermediateDirectories: true)
        var meta = config
        meta["goal"] = goal
        meta["started"] = ISO8601DateFormatter().string(from: Date())
        try enc.encode(meta).write(
            to: runDir.appendingPathComponent("meta.json"), options: .atomic)
    }

    public func log(_ record: StepRecord) throws {
        let line = try record.jsonLine()
        let url = runDir.appendingPathComponent("steps.jsonl")
        // Always append — never the atomic-write path: `write(to:atomically:)`
        // REPLACES the file, so a failed handle would silently truncate the
        // whole evidence trail to this one line.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        h.seekToEndOfFile()
        h.write(Data((line + "\n").utf8))
        try h.close()
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
    case busy(String)
    /// An actuator-level operation failed outside the deny/abort paths —
    /// e.g. a model pull exiting non-zero.
    case actionFailed(String)

    public var description: String {
        switch self {
        case .permissionMissing(let p): return "missing permission: \(p)"
        case .screenshotFailed(let m): return "screenshot failed: \(m)"
        case .axFailed(let m): return "accessibility error: \(m)"
        case .aborted(let m): return "aborted: \(m)"
        case .busy(let m): return m
        case .actionFailed(let m): return m
        }
    }

    public var errorDescription: String? { description }
}
