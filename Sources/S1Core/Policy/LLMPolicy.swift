import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Shared prompt plumbing for model-backed policies and the S2 reasoner:
/// serialize the observation compactly, ask for a JSON decision, parse it.
enum LLMDecisionCodec {
    /// Keep prompts small: role/title/value of the first ~60 AX nodes, window
    /// titles, and the app name. Token cost stays low and the model still
    /// grounds actions in real element refs (`e12`).
    static func observationText(_ obs: Snapshot) -> String {
        var lines = ["App: \(obs.frontmostApp ?? "?")"]
        // Every running app + its window titles — the model sees the whole
        // screen context (Spotlight-like), not just the frontmost window.
        for a in obs.appStates.prefix(12) {
            var s = a.isActive ? "* \(a.name)" : "  \(a.name)"
            if !a.windowTitles.isEmpty { s += ": " + a.windowTitles.prefix(3).joined(separator: " | ") }
            lines.append(s)
        }
        lines += obs.windows.prefix(8).map { "win \($0.pid): \($0.title ?? "")" }
        for n in obs.axTree?.flattened.prefix(60) ?? [] {
            var s = "\(n.ref) \(n.role)"
            if pressableRoles.contains(n.role) { s += " [pressable]" }
            if editableRoles.contains(n.role) { s += " [editable]" }
            if scrollableRoles.contains(n.role) { s += " [scrollable]" }
            if let t = n.title, !t.isEmpty { s += " \"\(t)\"" }
            if let d = n.desc, !d.isEmpty, d != n.title { s += " desc=\"\(d.prefix(40))\"" }
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
        "AXMenuBarItem",
    ]

    /// Scroll containers — hints the model where `scroll` makes sense.
    static let scrollableRoles: Set<String> = [
        "AXScrollArea", "AXTable", "AXOutline", "AXList", "AXWebArea",
    ]

    /// Roles that take text via axSetValue (or focus + typeText) — NOT axPress.
    static let editableRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField",
    ]

    /// Compact digest of recent steps so the model can react to failures.
    static func historyText(_ history: [StepRecord]) -> String {
        guard !history.isEmpty else { return "(none)" }
        return "COMPLETED — do NOT repeat these:\n" + history.suffix(6).map { r in
            "  step \(r.index): \(describe(r.action)) -> \(r.outcome ?? "?")"
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
        Reply with ONLY one JSON object — no prose, no fences, no examples:
        {"action":{"type":"<TYPE>","<FIELD>":"<VALUE>"},"confidence":<0.0 to 1.0>,"rationale":"<why this action, in this screen>"}
        - The goal may list several steps separated by commas — do them left to right; a "done" step means the task is finished.
        - "type" is exactly ONE of: click, moveMouse, axPress, axSetValue, typeText, keyCombo, scroll, openApp, wait, verify, captureScreenshot, done. Never write more than one.
        - Fields by type: click/moveMouse take "x","y"; axPress/axSetValue take "ref"; axSetValue also "value"; typeText takes "text"; keyCombo takes "keys" like "cmd+s"; scroll takes "dx","dy"; wait takes "ms"; verify/done take "expect".
        - Use "ref" (an AX element id like e3) whenever the target is in the AX tree — prefer axPress over click.
        - To open/launch an app, use openApp with the app name. Never try to press app/root nodes.
        - axPress only on nodes marked [pressable]. e0 is the application ROOT, not a button.
        - To put text in a node marked [editable], use axSetValue (or click it, then typeText). Never axPress it.
        - If a step just failed with an "error:" outcome, choose a DIFFERENT action.
        - "expect" is checked by re-observing the screen after the action; omit it unless a check is needed.
        - "keys" is a combo like "cmd+s" or ["cmd","s"].
        - "confidence" and "rationale" are TOP-LEVEL keys, siblings of "action" — never inside it.
        - confidence = how sure you are: 0.8-1.0 when the action clearly matches the next step, <0.5 when unsure.
        - If the previous action already accomplished a goal part, move to the NEXT part — never repeat it.
        - When every goal part is accomplished, reply with type "done".
        - confidence < threshold hands the step to the reasoner.
        """

    struct Wire: Decodable {
        struct A: Decodable {
            let type: String; let x: Double?; let y: Double?; let ref: String?
            let text: String?; let value: String?; let app: String?
            let dx: Double?; let dy: Double?; let ms: Double?; let expect: String?
            /// Small models sometimes nest these inside the action — capture both.
            let confidence: Double?; let rationale: String?
            /// Models send either "cmd+s" or ["cmd","s"] — take both.
            let keys: [String]
            enum CodingKeys: String, CodingKey {
                case type, x, y, ref, text, value, app, keys, dx, dy, ms, expect, confidence, rationale
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
                confidence = try c.decodeIfPresent(Double.self, forKey: .confidence)
                rationale = try c.decodeIfPresent(String.self, forKey: .rationale)
            }
        }
        let action: A?; let confidence: Double?; let rationale: String?
    }

    /// Extract the JSON object even when the model wraps it in prose or fences.
    static func parse(_ text: String) -> Decision? {
        guard let s = text.range(of: "{"), let e = text.range(of: "}", options: .backwards),
              s.lowerBound < e.upperBound else {
            // Truncated replies may not even close a brace — salvage anyway.
            return salvage(text)
        }
        let json = text[s.lowerBound ..< e.upperBound]
        guard let w = try? JSONDecoder().decode(Wire.self, from: Data(json.utf8)) else {
            return salvage(text)
        }
        return Decision(action: w.action.flatMap(LLMDecisionCodec.action),
                        confidence: w.confidence ?? w.action?.confidence ?? 0,
                        rationale: w.rationale ?? w.action?.rationale ?? "")
    }

    /// Last-resort field extraction for replies truncated mid-JSON (3B models
    /// do this): pull "type"/"ref"/"app"/"text"/"x"/"y" with regexes and build
    /// a conservative action with low confidence instead of giving up.
    static func salvage(_ text: String) -> Decision? {
        func field(_ name: String) -> String? {
            let pat = "\"" + name + "\"\\s*:\\s*\"([^\"]+)\""
            guard let r = text.range(of: pat, options: .regularExpression) else { return nil }
            var v = text[r].dropFirst(name.count + 2)          // drop `"name"`
            v = v.drop(while: { $0 == ":" || $0 == " " || $0 == "\"" }).dropLast()
            return String(v)
        }
        func num(_ name: String) -> Double? {
            let pat = "\"" + name + "\"\\s*:\\s*([0-9.]+)"
            guard let r = text.range(of: pat, options: .regularExpression) else { return nil }
            let v = text[r].dropFirst(name.count + 2).drop(while: { $0 == ":" || $0 == " " || $0 == "\"" })
            return Double(v)
        }
        guard let type = field("type") else { return nil }
        let a: Action?
        switch type {
        case "axPress":   a = field("ref").map { .axPress(ref: $0) }
        case "axSetValue": a = field("ref").map { .axSetValue(ref: $0, value: field("value") ?? field("text") ?? "") }
        case "typeText":  a = field("text").map { .typeText($0) }
        case "openApp":   a = (field("app") ?? field("text")).map { .openApp(name: $0) }
        case "click":     a = .click(x: num("x") ?? 0, y: num("y") ?? 0)
        case "keyCombo":  a = field("keys").map { .keyCombo(keys: $0.split(separator: "+").map { $0.lowercased() }) }
        case "wait":      a = .wait(seconds: (num("ms") ?? 500) / 1000)
        case "scroll":    a = .scroll(dx: num("dx") ?? 0, dy: num("dy") ?? 0)
        case "moveMouse": a = .moveMouse(x: num("x") ?? 0, y: num("y") ?? 0)
        case "verify":    a = field("expect").map { .verify(expectation: $0) }
        case "captureScreenshot": a = .captureScreenshot(reason: field("expect") ?? "salvaged")
        case "done":      a = .done(summary: field("expect") ?? "done")
        default:          a = nil
        }
        guard let a else { return nil }
        let conf = num("confidence") ?? 0.55  // salvaged reply — honest middle
        return Decision(action: a, confidence: conf,
                        rationale: "salvaged from truncated reply: \(type)")
    }

    /// Wire type → Action. Unknown types return nil: a model inventing an
    /// action name ("typewrite", "tap") must NOT silently become `done` —
    /// nil counts as abstention and escalates instead.
    static func action(_ a: Wire.A) -> Action? {
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
        case "done":      return .done(summary: a.expect ?? a.text ?? "done")
        default:          return nil
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

    public func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        // Deterministic decomposition (shared with AXPolicy): the model grounds
        // ONE intent per step — small local models can't track a whole plan.
        // A step that failed (error/blocked outcome) does NOT consume its
        // intent — the cursor stays so the model retries it differently.
        let intents = AXPolicy.intents(of: goal)
        let cursor: Int = if let last = history.last,
                             last.action != nil,
                             let o = last.outcome,
                             o.hasPrefix("error:") || o.hasPrefix("blocked:") {
            history.count - 1
        } else {
            history.count
        }
        guard cursor < intents.count else {
            return Decision(action: .done(summary: "goal completed"), confidence: 0.9,
                            rationale: "all \(intents.count) intents consumed")
        }
        let current = intents[cursor]
        let hint: String
        switch current.verb {
        case "open", "buka", "launch":  hint = "openApp"
        case "type", "ketik", "write", "tulis": hint = "typeText (or axSetValue on an [editable] node)"
        case "key", "keys", "hotkey", "press": hint = "keyCombo (e.g. \"cmd+f\") — or click/axPress for a UI element"
        case "wait", "tunggu":          hint = "wait"
        case "verify", "cek", "check", "pastikan": hint = "verify"
        case "screenshot", "capture", "screencap", "tangkap", "tangkapan", "foto", "potret", "ambil":
            hint = "captureScreenshot"
        case "scroll", "gulir", "geser": hint = "scroll (dx/dy pixel deltas)"
        case "done", "selesai":         hint = "done"
        default:                        hint = "whichever action type fits"
        }
        let plan = intents.enumerated().map { i, it in
            "\(i + 1). \(it.verb) \(it.arg)\(i == cursor ? "  <== CURRENT" : (i < cursor ? " (done)" : ""))"
        }.joined(separator: "\n")
        let prompt = """
            You are System 1 of a macOS agent: fast local decisions for GUI control.
            Goal: \(goal)
            Plan so far:
            \(plan)
            Decide the SINGLE action for the CURRENT step: "\(current.verb) \(current.arg)" — expected action type: \(hint).

            \(LLMDecisionCodec.observationText(observation))

            \(LLMDecisionCodec.historyText(history))
            \(LLMDecisionCodec.decisionFormat)
            """
        var image: String? = nil
        if useScreenshot, let path = observation.screenshotPath,
           let data = Self.downscaledPNG(path: path) {
            image = data
        }
        let sys = ChatMessage(role: "system", content: "You are a GUI-control decision engine. You output one compact JSON decision per request — never prose, never repeat completed steps.")
        let reply = try await client.chat([sys, ChatMessage(role: "user", content: prompt, imageBase64: image)])
        var d = LLMDecisionCodec.parse(reply)
        if d == nil {
            // Small models truncate or malform JSON sometimes — one strict retry.
            let retry = try await client.chat([sys, ChatMessage(role: "user",
                content: prompt + "\n\nIMPORTANT: reply with ONLY the JSON object, no prose, no fences.",
                imageBase64: image)])
            d = LLMDecisionCodec.parse(retry)
            if d == nil {
                return Decision(action: nil, confidence: 0,
                                rationale: "unparseable VLM reply: \(retry.prefix(400))",
                                rawReply: String(retry.prefix(800)))
            }
            d?.rawReply = String(retry.prefix(800))
            return d!
        }
        d?.rawReply = String(reply.prefix(800))
        return d!
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

    public func decide(observation: Snapshot, goal: String, history: [StepRecord],
                       reason: String) async throws -> Decision {
        let prompt = """
            You are System 2, the slow reasoner a fast System 1 escalates to.
            Goal: \(goal)
            System 1 was unsure: \(reason)

            \(LLMDecisionCodec.observationText(observation))

            \(LLMDecisionCodec.decisionFormat)
            """
        let reply = try await client.chat([ChatMessage(role: "user", content: prompt)])
        var d = LLMDecisionCodec.parse(reply)
            ?? Decision(action: nil, confidence: 0, rationale: "unparseable S2 reply")
        d.rawReply = String(reply.prefix(800))
        return d
    }
}
