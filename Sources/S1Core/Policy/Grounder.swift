import AppKit
import Foundation

/// Optional specialist for the one thing general VLMs are worst at: turning
/// "click Save" + a screenshot into a precise point. GUI-grounding models
/// (Holo, MAI-UI, GUI-Owl, Qwen3-VL) answer in a normalized [0,1000] space;
/// any of them behind an OpenAI-compatible endpoint plugs in here.
///
/// Configure via `~/.s1/config.json` `"grounder": {"model": "…"}` or
/// `S1_GROUNDER_MODEL` / `S1_GROUNDER_BASE`. Unset → no grounder, the VLM
/// grounds clicks itself.
public struct Grounder: Sendable {
    public let endpoint: Endpoint
    let client: ChatClient

    public init(endpoint: Endpoint) {
        self.endpoint = endpoint
        self.client = ChatClient(endpoint: endpoint)
    }

    /// The configured grounder, or nil when none is set.
    public static func configured(env: [String: String] = ProcessInfo.processInfo.environment,
                                  config: S1Config = .load()) -> Grounder? {
        Endpoints.grounder(env: env, config: config).map(Grounder.init)
    }

    static let system = """
        You are a GUI grounding model for computer-use automation. Given a \
        screenshot and a task, locate the single UI element the task refers to. \
        Reply with ONLY its click point as integers normalized to the image in \
        [0, 1000], origin top-left, formatted exactly: (x, y)
        """

    /// Click point for `target` in global screen points, or nil when the
    /// model found nothing parseable.
    public func locate(_ target: String, screenshotBase64: String) async throws -> (x: Double, y: Double)? {
        let reply = try await client.chat([
            ChatMessage(role: "system", content: Self.system),
            ChatMessage(role: "user", content: "Task: click \(target)", imageBase64: screenshotBase64),
        ], maxTokens: 96)
        guard let p = Self.parsePoint(reply) else { return nil }
        let b = Self.capturedDisplayBounds()
        return (b.minX + p.x / 1000 * b.width, b.minY + p.y / 1000 * b.height)
    }

    /// Normalized [0,1000] point from the reply shapes grounding models emit:
    /// `(x, y)`, `[x, y]`, `click(start_box='(x,y)')`, `<point>x y</point>`,
    /// `{"x": …, "y": …}`, or a 4-number bbox (`bbox_2d`) → its center.
    /// Out-of-range values mean the model used some other space — refuse
    /// rather than click a guess.
    static func parsePoint(_ reply: String) -> (x: Double, y: Double)? {
        var text = reply
        for marker in ["</think>", "Action:"] {
            if let r = text.range(of: marker, options: .backwards) { text = String(text[r.upperBound...]) }
        }
        if let xr = text.range(of: #""x"\s*:\s*(-?\d+(\.\d+)?)"#, options: .regularExpression),
           let yr = text.range(of: #""y"\s*:\s*(-?\d+(\.\d+)?)"#, options: .regularExpression),
           let x = Self.numbers(in: String(text[xr])).first,
           let y = Self.numbers(in: String(text[yr])).first {
            return Self.inRange(x, y)
        }
        text = text.replacingOccurrences(of: "bbox_2d", with: "bbox")
        let n = Self.numbers(in: text)
        if n.count >= 4, text.contains("bbox") || n.count == 4 {
            return Self.inRange((n[0] + n[2]) / 2, (n[1] + n[3]) / 2)
        }
        guard n.count >= 2 else { return nil }
        return Self.inRange(n[0], n[1])
    }

    static func numbers(in s: String) -> [Double] {
        var out: [Double] = []
        var cur = ""
        for ch in s {
            if ch.isNumber || (ch == "." && !cur.isEmpty) { cur.append(ch) }
            else if !cur.isEmpty { out.append(Double(cur) ?? 0); cur = "" }
        }
        if !cur.isEmpty { out.append(Double(cur) ?? 0) }
        return out
    }

    static func inRange(_ x: Double, _ y: Double) -> (x: Double, y: Double)? {
        (0...1000).contains(x) && (0...1000).contains(y) ? (x, y) : nil
    }

    /// Global-point bounds of the display `captureScreen()` shoots —
    /// the main screen — so normalized coords land on the same pixels.
    static func capturedDisplayBounds() -> CGRect {
        let id = (NSScreen.main?.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            ?? CGMainDisplayID()
        return CGDisplayBounds(id)
    }
}
