import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Shared prompt plumbing for model-backed policies and the S2 reasoner:
/// serialize the observation compactly, ask for a JSON decision, parse it.
enum LLMDecisionCodec {
    /// Keep prompts small: role/title/value of the first ~120 AX nodes, window
    /// titles, and the app name. Token cost stays low and the model still
    /// grounds actions in real element refs (`e12`).
    static func observationText(_ obs: Observation) -> String {
        var lines = ["App: \(obs.frontmostApp ?? "?")"]
        lines += obs.windows.prefix(8).map { "win \($0.pid): \($0.title ?? "")" }
        for n in obs.axTree?.flattened.prefix(60) ?? [] {
            var s = "\(n.ref) \(n.role)"
            if pressableRoles.contains(n.role) { s += " [pressable]" }
            if editableRoles.contains(n.role) { s += " [editable]" }
            if let t = n.title, !t.isEmpty { s += " \"\(t)\"" }
            if let v = n.value, !v.isEmpty, v != n.title { s += " value=\"\(v.prefix(60))\"" }
            lines.append(s)
        }
        return lines.joined(separator: "\n")
    }

    /// Roles an axPress can meaningfully trigger — mirrored in the
    /// observation dump as [pressable] so models stop pressing roots/groups.
    static let pressableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXLink",
        "AXTab", "AXMenuButton", "AXPopUpButton", "AXRow", "AXCell",
    ]

    /// Roles that take text via axSetValue (or focus + typeText) — NOT axPress.
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField",
    ]

    /// Compact digest of recent steps so the model can react to failures.
    static func historyText(_ history: [StepRecord]) -> String {
        history.suffix(6).map { r in
            "\(r.index):\(describe(r.action)) -> \(r.outcome ?? "?")"
        }.joined(separator: "\n")
    }

    private static func describe(_ a: Action?) -> String {
        guard let a else { return "none" }
        switch a {
        case .openApp(let n): return "openApp(\(n))"
        case .typeText(let t): return "type(\(t.prefix(20)))"
        case .axPress(let r): return "axPress(\(r))"
        case .axSetValue(let r, let v): return "axSet(\(r),\(v.prefix(15)))"
        case .click(let x, let y): return "click(\(Int(x)),\(Int(y)))"
        case .keyCombo(let k): return "key(\(k.joined(separator: "+")))"
        case .wait(let s): return "wait(\(s))"
        case .captureScreenshot: return "screenshot"
        case .verify(let e): return "verify(\(e.prefix(30)))"
        case .done: return "done"
        case .scroll(let dx, let dy): return "scroll(\(dx),\(dy))"
        case .moveMouse(let x, let y): return "move(\(Int(x)),\(Int(y)))"
        case .shell(let c): return "shell(\(c.prefix(20)))"
        case .custom(let n, _): return "custom(\(n))"
        }
    }

    static let decisionFormat = """
        Reply with ONLY a JSON object:
        {"action":{"type":"click|moveMouse|axPress|axSetValue|typeText|keyCombo|scroll|openApp|wait|verify|captureScreenshot|done",\
        "x":0,"y":0,"ref":"e0","text":"...","value":"...","app":"...","keys":"cmd+s",\
        "dx":0,"dy":0,"ms":1000,"expect":"..."},
         "confidence":0.0,"rationale":"one sentence"}
        - Use "ref" (an AX element id like e3) whenever the target is in the AX tree — prefer axPress over click.
        - To open/launch an app, use openApp with the app name. Never try to press app/root nodes.
        - axPress only on nodes marked [pressable]. e0 is the application ROOT, not a button.
        - To put text in a node marked [editable], use axSetValue (or click it, then typeText). Never axPress it.
        - If a step just failed with an "error:" outcome, choose a DIFFERENT action.
        - "expect" is checked by re-observing the screen after the action; omit it unless a check is needed.
        - "keys" is a combo like "cmd+s" or ["cmd","s"].
        - confidence < threshold hands the step to the reasoner.
        """

    struct Wire: Decodable {
        struct A: Decodable {
            let type: String; let x: Double?; let y: Double?; let ref: String?
            let text: String?; let value: String?; let app: String?
            let dx: Double?; let dy: Double?; let ms: Double?; let expect: String?
            /// Models send either "cmd+s" or ["cmd","s"] — take both.
            let keys: [String]
            enum CodingKeys: String, CodingKey {
                case type, x, y, ref, text, value, app, keys, dx, dy, ms, expect
            }
            init(from d: Decoder) throws {
                let c = try d.container(keyedBy: CodingKeys.self)
                type = try c.decode(String.self, forKey: .type)
                x = try c.decodeIfPresent(Double.self, forKey: .x)
                y = try c.decodeIfPresent(Double.self, forKey: .y)
                ref = try c.decodeIfPresent(String.self, forKey: .ref)
                text = try c.decodeIfPresent(String.self, forKey: .text)
                value = try c.decodeIfPresent(String.self, forKey: .value)
                app = try c.decodeIfPresent(String.self, forKey: .app)
                dx = try c.decodeIfPresent(Double.self, forKey: .dx)
                dy = try c.decodeIfPresent(Double.self, forKey: .dy)
                ms = try c.decodeIfPresent(Double.self, forKey: .ms)
                expect = try c.decodeIfPresent(String.self, forKey: .expect)
                if let arr = try? c.decode([String].self, forKey: .keys) {
                    keys = arr
                } else if let s = try? c.decode(String.self, forKey: .keys) {
                    keys = s.split(separator: "+").map { $0.lowercased() }
                } else { keys = [] }
            }
        }
        let action: A?; let confidence: Double?; let rationale: String?
    }

    /// Extract the JSON object even when the model wraps it in prose or fences.
    static func parse(_ text: String) -> Decision? {
        guard let s = text.range(of: "{"), let e = text.range(of: "}", options: .backwards),
              s.lowerBound < e.upperBound else { return nil }
        let json = text[s.lowerBound ..< e.upperBound]
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)) else { return nil }
        return Decision(action: w.action.map(LLMDecisionCodec.action),
                        confidence: w.confidence ?? 0,
                        rationale: w.rationale ?? "")
    }

    static func action(_ a: Wire.A) -> Action {
        if let ref = a.ref, !ref.isEmpty, a.type == "click" { return .axPress(ref: ref) }
        switch a.type {
        case "moveMouse": return .moveMouse(x: a.x ?? 0, y: a.y ?? 0)
        case "click":     return .click(x: a.x ?? 0, y: a.y ?? 0)
        case "axPress":   return .axPress(ref: a.ref ?? "")
        case "axSetValue": return .axSetValue(ref: a.ref ?? "", value: a.value ?? a.text ?? "")
        case "typeText":  return .typeText(a.text ?? "")
        case "keyCombo":  return .keyCombo(keys: a.keys.map { $0.lowercased() })
        case "scroll":    return .scroll(dx: a.dx ?? 0, dy: a.dy ?? 0)
        case "openApp":   return .openApp(name: a.app ?? a.text ?? "")
        case "wait":      return .wait(seconds: (a.ms ?? 500) / 1000)
        case "captureScreenshot": return .captureScreenshot(reason: a.expect ?? "requested by model")
        case "verify":    return .verify(expectation: a.expect ?? "")
        default:          return .done(summary: a.expect ?? a.text ?? "done")
        }
    }
}

/// System 1 as a vision-language model behind an OpenAI-compatible endpoint —
/// Fara1.5-4B, GUI-Owl-1.5, Holo 4, gemma3, whatever the endpoint serves.
/// The protocol is the contract; swap endpoints, not code.
public struct VLMPolicy: Policy {
    public let name: String
    public let useScreenshot: Bool
    let client: ChatClient

    public var wantsScreenshot: Bool { useScreenshot }

    public init(endpoint: Endpoint, useScreenshot: Bool = true) {
        self.name = "vlm:\(endpoint.model)"
        self.client = ChatClient(endpoint: endpoint)
        self.useScreenshot = useScreenshot
    }

    public func decide(observation: Observation, goal: String, history: [StepRecord]) async throws -> Decision {
        let prompt = """
            You are System 1 of a macOS agent: fast local decisions for GUI control.
            Goal: \(goal)

            \(LLMDecisionCodec.observationText(observation))

            Steps already taken:
            \(LLMDecisionCodec.historyText(history))
            \(LLMDecisionCodec.decisionFormat)
            """
        var image: String? = nil
        if useScreenshot, let path = observation.screenshotPath,
           let data = Self.downscaledPNG(path: path) {
            image = data
        }
        let reply = try await client.chat([ChatMessage(role: "user", content: prompt, imageBase64: image)])
        return LLMDecisionCodec.parse(reply)
            ?? Decision(action: nil, confidence: 0, rationale: "unparseable VLM reply: \(reply.prefix(400))")
    }

    /// VLMs don't need retina pixels — a ~1024px-wide PNG keeps the prompt
    /// (and context window) small enough for local endpoints.
    static func downscaledPNG(path: String, maxWidth: Int = 1024) -> String? {
        let url = URL(fileURLWithPath: path)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let scale = min(1.0, Double(maxWidth) / Double(img.width))
        let w = Int(Double(img.width) * scale), h = Int(Double(img.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage(),
              let destData = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(destData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return (destData as Data).base64EncodedString()
    }
}

/// System 2: the reasoner invoked on low confidence. Bigger model, same
/// endpoint shape — local (Ollama/MLX) or cloud (API key) by config.
public struct LLMReasoner: Reasoner {
    public let name: String
    let client: ChatClient

    public init(endpoint: Endpoint) {
        self.name = "llm:\(endpoint.model)"
        self.client = ChatClient(endpoint: endpoint)
    }

    public func decide(observation: Observation, goal: String, history: [StepRecord],
                       reason: String) async throws -> Decision {
        let prompt = """
            You are System 2, the slow reasoner a fast System 1 escalates to.
            Goal: \(goal)
            System 1 was unsure: \(reason)

            \(LLMDecisionCodec.observationText(observation))

            \(LLMDecisionCodec.decisionFormat)
            """
        let reply = try await client.chat([ChatMessage(role: "user", content: prompt)])
        return LLMDecisionCodec.parse(reply)
            ?? Decision(action: nil, confidence: 0, rationale: "unparseable S2 reply")
    }
}
