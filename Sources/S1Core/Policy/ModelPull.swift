import Foundation

/// One-click local-model install: find `ollama`, run `ollama pull`, and
/// surface its streamed progress. Lives in S1Core so the app and any
/// future front end share the same discovery logic — GUI apps inherit a
/// sparse PATH, so binaries are probed at their standard install spots
/// rather than resolved through a shell.
public enum ModelPull {

    /// The `ollama` binary, or nil when Ollama isn't installed.
    /// Covers brew (arm64 + Intel), the Ollama.app distribution, and a
    /// PATH walk for anything custom.
    public static func ollamaBinary() -> String? {
        let known = [
            "/opt/homebrew/bin/ollama",
            "/usr/local/bin/ollama",
            "/Applications/Ollama.app/Contents/Resources/ollama",
        ]
        for p in known where FileManager.default.isExecutableFile(atPath: p) { return p }
        for dir in (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":") {
            let p = String(dir) + "/ollama"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// Shell command the user can run when Ollama itself is missing —
    /// the cask is the standard macOS install (the formula builds from
    /// source and takes much longer).
    public static let installHint = "brew install --cask ollama"

    /// A curated pick for the app's model catalog — one tap installs it.
    /// `vision` marks brains the VLM policy can ground screenshots with;
    /// text-only models are S2 candidates (reasoning) but can't see.
    public struct CatalogEntry: Sendable {
        public let name: String
        /// e.g. "3.3 GB" — what the download roughly costs.
        public let size: String
        /// One line on why you'd pick it.
        public let blurb: String
        public let vision: Bool
        public init(_ name: String, _ size: String, _ blurb: String, vision: Bool) {
            self.name = name; self.size = size; self.blurb = blurb
            self.vision = vision
        }
    }

    /// The shipped shortlist — smallest-useful first, all Apache/MIT and
    /// all one `ollama pull` away. S1 wants vision; S2 wants reasoning.
    public static let catalog: [CatalogEntry] = [
        .init("gemma3:4b", "3.3 GB",
              "default — sees screenshots, decent reasoning, ships tested", vision: true),
        .init("qwen2.5vl:3b", "3.1 GB",
              "smallest vision brain — snappier steps, weaker at long goals", vision: true),
        .init("qwen3-vl:8b", "6.1 GB",
              "strongest vision brain that fits 16 GB — best grounding, slower per step", vision: true),
        .init("llama3.2:3b", "2.0 GB",
              "text-only featherweight — S2 chats, cannot see screens", vision: false),
        .init("qwen3:8b", "5.2 GB",
              "stronger S2 reasoning — slower but better multi-step plans", vision: false),
        .init("gpt-oss:20b", "13 GB",
              "heaviest brain — best plans on Apple Silicon, needs the RAM", vision: false),
        .init("llava:7b", "4.7 GB",
              "classic vision agent — fallback when gemma3 stumbles", vision: true),
    ]

    /// Models already pulled — parses `ollama list` ("NAME  ID  SIZE  MODIFIED").
    /// Returns [] when ollama or its server is missing; never throws.
    public static func installed() -> [String] {
        guard let bin = ollamaBinary() else { return [] }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["list"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        guard (try? proc.run()) != nil else { return [] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return [] }
        return parseOllamaList(String(decoding: data, as: UTF8.self))
    }

    /// First column of each row after the `NAME ID SIZE MODIFIED` header.
    static func parseOllamaList(_ text: String) -> [String] {
        text.split(separator: "\n").dropFirst()
            .compactMap { $0.split(whereSeparator: \.isWhitespace).first.map(String.init) }
    }

    /// Removes CSI escape sequences (ESC [ … letter).
    static func stripANSI<S: StringProtocol>(_ s: S) -> String {
        var out = ""
        var inEscape = false
        for c in s {
            if inEscape {
                if c.isLetter { inEscape = false }
            } else if c == "\u{1B}" {
                inEscape = true
            } else {
                out.append(c)
            }
        }
        return out
    }

    /// Run `ollama pull <model>` to completion.
    /// `progress` gets the latest status line as it streams in — ollama
    /// redraws its bar with carriage returns, so each \r/\n-separated
    /// fragment replaces the previous one.
    /// Throws on non-zero exit with the last progress line as context.
    public static func pull(model: String,
                            progress: @Sendable @escaping (String) -> Void) async throws {
        guard let bin = ollamaBinary() else {
            throw S1Error.actionFailed("ollama not installed — \(installHint)")
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["pull", model]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let latest = LockedLine()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            for frag in chunk.split(whereSeparator: { $0 == "\r" || $0 == "\n" }) {
                // ollama decorates its bar with CSI sequences (\e[K, \e[?25l…) —
                // drop them so plain-text sinks (logs, the app feed) stay clean.
                let line = Self.stripANSI(frag)
                    .trimmingCharacters(in: .whitespaces)
                guard !line.isEmpty else { continue }
                latest.set(line)
                progress(line)
            }
        }
        try proc.run()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in c.resume() }
        }
        pipe.fileHandleForReading.readabilityHandler = nil
        guard proc.terminationStatus == 0 else {
            throw S1Error.actionFailed(
                "ollama pull \(model) failed (exit \(proc.terminationStatus))" +
                (latest.get().map { " — \($0)" } ?? ""))
        }
    }
}

/// Last-writer-wins string box for the pull's streaming progress —
/// the pipe handler runs on its own queue while the caller awaits exit.
private final class LockedLine: @unchecked Sendable {
    private let lock = NSLock()
    private var line: String?
    func set(_ s: String) { lock.lock(); line = s; lock.unlock() }
    func get() -> String? { lock.lock(); defer { lock.unlock() }; return line }
}
