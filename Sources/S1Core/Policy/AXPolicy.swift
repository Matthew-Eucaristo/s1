import Foundation

/// Deterministic System 1: no model, no network. Parses the goal into a small
/// command grammar and resolves targets against the AX tree. Confidence is a
/// real score (match quality), so weak parses naturally escalate to S2.
///
/// Grammar (English + Indonesian): `open/buka <app>` · `click/klik <label>` ·
/// `type/ketik <text>` · `key <combo>` · `wait/tunggu <s|ms>` ·
/// `scroll/gulir <arah>` · `screenshot/tangkap` · `verify/cek` · `done/selesai`
/// — the honest baseline every smarter S1 must beat before earning a place
/// in the loop.
public struct AXPolicy: Policy {
    public let name = "ax"
    /// Seconds waited between queued sub-commands; the policy consumes one
    /// intent per step, using history length as its position cursor.
    public init() {}

    struct Intent {
        var verb: String
        var arg: String
    }

    /// Split "open TextEdit, type hello, done" into ordered intents.
    /// Also splits on conjunctions — voice transcriptions rarely use commas:
    /// "buka TextEdit lalu ketik halo" → [buka TextEdit, ketik halo].
    static func intents(of goal: String) -> [Intent] {
        // Drop leading politeness/wake filler that dictation loves to prepend —
        // "tolong buka …", "please open …", "s1 buka …", "hey s1, open …".
        // Without this the first word becomes an unknown verb and escalates.
        var g = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let fillers = ["s1", "es satu", "es one", "hey s1", "hai s1", "tolong", "please",
                       "coba", "bisa", "boleh", "mohon", "can you", "could you",
                       "ayo", "c'mon", "yuk"]
        var stripped = true
        while stripped {
            stripped = false
            let low = g.lowercased()
            for f in fillers where low == f || low.hasPrefix(f + " ") || low.hasPrefix(f + ",") {
                g = String(g.dropFirst(f.count)).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(.punctuationCharacters))
                stripped = true
                break
            }
        }
        return g
            .replacingOccurrences(of: " lalu ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " then ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " dan ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " and then ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " terus ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " trus ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " kemudian ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " habis itu ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " abis itu ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " setelah itu ", with: ",", options: .caseInsensitive)
            .replacingOccurrences(of: " lantas ", with: ",", options: .caseInsensitive)
            .components(separatedBy: CharacterSet(charactersIn: ",;"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { part -> Intent in
                let words = part.split(separator: " ", maxSplits: 1)
                let verb = words.first?.lowercased() ?? ""
                let arg = words.count > 1 ? String(words[1]) : ""
                return Intent(verb: verb, arg: arg)
            }
    }

    /// Element match quality 0...1: exact title 1.0, prefix 0.8, contains 0.6.
    static func matchScore(_ needle: String, _ node: AXNode) -> Double {
        let n = needle.lowercased()
        let fields = [node.title, node.desc, node.value, n == "" ? nil : node.role].compactMap { $0?.lowercased() }
        var best = 0.0
        for f in fields {
            if f == n { best = max(best, 1.0) }
            else if f.hasPrefix(n) { best = max(best, 0.8) }
            else if f.contains(n) { best = max(best, 0.6) }
        }
        return best
    }

    /// Roles that take a press rather than a text set.
    static let pressableRoles: Set<String> = [
        "AXButton", "AXMenuItem", "AXCheckBox", "AXRadioButton", "AXLink",
        "AXTab", "AXMenuButton", "AXPopUpButton", "AXRow",
    ]

    public func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        let intents = AXPolicy.intents(of: goal)
        guard history.count < intents.count else {
            return Decision(action: .done(summary: "goal completed"), confidence: 0.95,
                            rationale: "all \(intents.count) intents consumed")
        }
        // A failed step stops the chain instead of cascading — "buka X lalu
        // ketik Y" must not type into a random app when the open failed.
        if let last = history.last, last.outcome?.hasPrefix("error:") == true {
            return Decision(action: nil, confidence: 0.15,
                            rationale: "previous step failed — abstaining instead of cascading")
        }
        let intent = intents[history.count]
        switch intent.verb {
        case "open", "buka", "launch":
            return Decision(action: .openApp(name: intent.arg), confidence: 0.9,
                            rationale: "open \(intent.arg)")
        case "type", "ketik", "write", "tulis":
            return Decision(action: .typeText(intent.arg), confidence: 0.95,
                            rationale: "type literal text")
        case "key", "keys", "hotkey":
            return Decision(action: .keyCombo(keys: intent.arg.split(separator: "+").map { $0.lowercased() }),
                            confidence: 0.95,
                            rationale: "key combo")
        case "wait", "tunggu":
            // "wait 2" means seconds to a human; "wait 2000" means ms.
            // Explicit suffixes win; bare numbers >= 100 read as ms.
            let arg = intent.arg.lowercased()
            let n = Double(arg.replacingOccurrences(of: "ms", with: "")
                .replacingOccurrences(of: "s", with: "")) ?? 0.5
            let secs = arg.hasSuffix("ms") ? n / 1000 : (arg.hasSuffix("s") ? n : (n >= 100 ? n / 1000 : n))
            return Decision(action: .wait(seconds: secs), confidence: 0.95,
                            rationale: "wait \(secs)s")
        case "screenshot", "capture", "screencap", "tangkap", "tangkapan", "foto", "potret", "ambil":
            return Decision(action: .captureScreenshot(reason: "requested in goal"), confidence: 0.95,
                            rationale: "screenshot requested")
        case "scroll", "gulir", "geser":
            // Voice says directions, pixels come out (wheel1 = vertical).
            let d: (Double, Double)
            switch intent.arg.lowercased() {
            case "up", "atas":              d = (0, -300)
            case "left", "kiri":           d = (-300, 0)
            case "right", "kanan":         d = (300, 0)
            default:                       d = (0, 300)   // "down"/"bawah" + bare "scroll"
            }
            return Decision(action: .scroll(dx: d.0, dy: d.1), confidence: 0.9,
                            rationale: "scroll \(intent.arg.isEmpty ? "down" : intent.arg)")
        case "verify", "cek", "check", "pastikan":
            return Decision(action: .verify(expectation: intent.arg), confidence: 0.9,
                            rationale: "verify '\(intent.arg)' on screen")
        case "done", "selesai", "finish":
            return Decision(action: .done(summary: "done"), confidence: 0.95, rationale: "done intent")
        case "click", "press", "klik", "tekan", "set", "isi":
            guard let tree = observation.axTree else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "need AX tree to find '\(intent.arg)'")
            }
            let candidates: [(AXNode, Double)] = tree.flattened
                .map { ($0, AXPolicy.matchScore(intent.arg, $0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            guard let (node, score) = candidates.first else {
                return Decision(action: nil, confidence: 0.25,
                                rationale: "no AX element matches '\(intent.arg)'")
            }
            let isPressable = AXPolicy.pressableRoles.contains(node.role)
            let action: Action
            if intent.verb == "set" || intent.verb == "isi" {
                action = .axSetValue(ref: node.ref, value: intent.arg)
            } else if isPressable {
                action = .axPress(ref: node.ref)
            } else {
                let f = node.frame
                let cx: Double = (f?.x ?? 0) + (f?.w ?? 0) / 2
                let cy: Double = (f?.y ?? 0) + (f?.h ?? 0) / 2
                action = .click(x: cx, y: cy)
            }
            // Ambiguity penalty: second-place close behind → less sure.
            let runnerUp = candidates.dropFirst().first?.1 ?? 0
            let confidence = min(0.95, score * (runnerUp > score - 0.15 ? 0.75 : 1.0))
            return Decision(action: action, confidence: confidence,
                            rationale: "matched \(node.ref) \(node.role) \"\(node.title ?? "")\" score=\(score)")
        default:
            return Decision(action: nil, confidence: 0.1,
                            rationale: "unknown verb '\(intent.verb)' — needs a smarter brain")
        }
    }
}
