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

    /// Wait duration from natural text: leading number + optional unit
    /// ("2", "2s", "2 seconds", "2 detik", "500ms", "1,5 detik", "2 menit").
    /// Unparseable args fall back to a conservative 0.5s.
    static func parseWaitSeconds(_ arg: String) -> Double {
        let t = arg.replacingOccurrences(of: ",", with: ".")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = t.split(separator: " ", maxSplits: 1)
        if let n = Double(parts.first ?? "") {
            let unit = parts.count > 1 ? parts[1].lowercased() : ""
            switch unit {
            case "ms", "milidetik", "milisekon", "millisecond", "milliseconds":
                return n / 1000
            case "menit", "minute", "minutes":
                return n * 60
            default:
                return n >= 100 && unit.isEmpty ? n / 1000 : n
            }
        }
        // Attached suffix forms: "500ms", "2s". Keep the sign — a negative
        // arg must clamp to 0 downstream, not become a positive wait.
        let sign: Double = t.hasPrefix("-") ? -1 : 1
        let digits = t.drop(while: { $0 == "-" }).prefix(while: { $0.isNumber || $0 == "." })
        guard let m = Double(digits) else { return 0.5 }
        let v = sign * m
        return t.hasSuffix("ms") ? v / 1000 : v
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
            // "and"/"dan" are ambiguous — real words inside typed text
            // ("milk and honey") AND conjunctions ("open X and type Y").
            // Split only when the following word is a grammar verb.
            .flatMap { splitConjunctions($0) }
            .map { part -> Intent in
                let words = part.split(separator: " ", maxSplits: 1)
                let verb = words.first?.lowercased() ?? ""
                let arg = words.count > 1 ? String(words[1]) : ""
                return Intent(verb: verb, arg: arg)
            }
    }

    /// Every verb the grammar (and the model hints) understands — used to
    /// decide whether "and"/"dan" starts a new command or is literal text.
    static let verbs: Set<String> = [
        "open", "buka", "launch", "type", "ketik", "write", "tulis",
        "key", "keys", "hotkey", "wait", "tunggu",
        "screenshot", "capture", "screencap", "tangkap", "tangkapan",
        "foto", "potret", "ambil", "scroll", "gulir", "geser",
        "verify", "cek", "check", "pastikan", "done", "selesai", "finish",
        "click", "press", "klik", "tekan", "set", "isi",
        "take", "grab", "snap",
    ]

    /// Split " A and B "/" A dan B " only when B starts with a grammar verb —
    /// otherwise it's literal text the user wants typed. Recurses so several
    /// conjunctions chain correctly.
    static func splitConjunctions(_ s: String) -> [String] {
        var searchFrom = s.startIndex
        while let r = s.range(of: " +(and|dan) +", options: [.regularExpression, .caseInsensitive],
                              range: searchFrom ..< s.endIndex) {
            let next = s[r.upperBound...]
                .split(separator: " ", maxSplits: 1).first?.lowercased() ?? ""
            if verbs.contains(next) {
                return splitConjunctions(String(s[..<r.lowerBound])) +
                       splitConjunctions(String(s[r.upperBound...]))
            }
            searchFrom = r.upperBound
        }
        return [s]
    }

    /// Element match quality 0...1: exact title 1.0, prefix 0.8, contains 0.6.
    static func matchScore(_ needle: String, _ node: AXNode) -> Double {
        let n = needle.lowercased()
        let fields = [node.title, node.desc, node.help, node.value, n == "" ? nil : node.role].compactMap { $0?.lowercased() }
        var best = 0.0
        for f in fields {
            if f == n { best = max(best, 1.0) }
            else if f.hasPrefix(n) { best = max(best, 0.8) }
            else if f.contains(n) { best = max(best, 0.6) }
        }
        return best
    }

    /// Roles that take a press rather than a text set — same set the LLM
    /// prompts advertise as [pressable]; one source of truth.
    static let pressableRoles: Set<String> = AXSemantics.pressable

    /// Voice-friendly key aliases — Indonesian + English — mapped onto the
    /// names CGEventActuator.keyCodes understands. Only multi-word phrases
    /// and locale words need entries; single English key names pass through.
    static let keyAliases: [String: String] = [
        "enter": "return", "spasi": "space", "spacebar": "space",
        "hapus": "delete", "backspace": "delete",
        "escape": "esc",
        "panah kiri": "left", "panah kanan": "right",
        "panah atas": "up", "panah bawah": "down",
        "arrow left": "left", "arrow right": "right",
        "arrow up": "up", "arrow down": "down",
        "left arrow": "left", "right arrow": "right",
        "up arrow": "up", "down arrow": "down",
        "page up": "pageup", "page down": "pagedown",
    ]

    static let keyModifiers: Set<String> =
        ["cmd", "command", "shift", "opt", "option", "alt", "ctrl", "control"]

    /// Interpret "enter" / "cmd s" / "panah kiri" as a keyCombo when every
    /// token is a modifier or a known key — nil when it's UI text instead.
    static func keyNames(_ arg: String) -> [String]? {
        if let alias = keyAliases[arg.lowercased()] { return [alias] }
        let keys = arg.lowercased()
            .split(separator: "+")
            .flatMap { $0.split(separator: " ") }
            .map(String.init)
        guard !keys.isEmpty,
              keys.allSatisfy({ keyModifiers.contains($0)
                                || CGEventActuator.keyCodes[$0] != nil }) else { return nil }
        return keys
    }

    public func decide(observation: Snapshot, goal: String, history: [StepRecord]) async throws -> Decision {
        let intents = AXPolicy.intents(of: goal)
        guard history.count < intents.count else {
            return Decision(action: .done(summary: "goal completed"), confidence: 0.95,
                            rationale: "all \(intents.count) intents consumed")
        }
        // A failed step stops the chain instead of cascading — "buka X lalu
        // ketik Y" must not type into a random app when the open failed.
        // "blocked:" counts too (denylist/gate stop), same as VLM's cursor.
        if let last = history.last,
           last.outcome?.hasPrefix("error:") == true || last.outcome?.hasPrefix("blocked:") == true {
            return Decision(action: nil, confidence: 0.15,
                            rationale: "previous step failed — abstaining instead of cascading")
        }
        let intent = intents[history.count]
        switch intent.verb {
        case "open", "buka", "launch":
            guard !intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs an app name")
            }
            return Decision(action: .openApp(name: intent.arg), confidence: 0.9,
                            rationale: "open \(intent.arg)")
        case "type", "ketik", "write", "tulis":
            guard !intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs text")
            }
            return Decision(action: .typeText(intent.arg), confidence: 0.95,
                            rationale: "type literal text")
        case "key", "keys", "hotkey":
            guard !intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs a combo like cmd+s")
            }
            // "cmd+s" typed, "cmd s" said — both split into the combo list.
            let keys = intent.arg.lowercased()
                .split(separator: "+")
                .flatMap { $0.split(separator: " ") }
                .map(String.init)
            return Decision(action: .keyCombo(keys: keys),
                            confidence: 0.95,
                            rationale: "key combo")
        case "wait", "tunggu":
            // "wait 2" means seconds to a human; "wait 2000" means ms.
            // Explicit suffixes and unit words win ("2 seconds", "2 detik",
            // "500 ms"); bare numbers >= 100 read as ms.
            let arg = intent.arg.lowercased()
            let secs = Self.parseWaitSeconds(arg)
            return Decision(action: .wait(seconds: secs), confidence: 0.95,
                            rationale: "wait \(secs)s")
        case "screenshot", "capture", "screencap", "tangkap", "tangkapan", "foto", "potret", "ambil":
            return Decision(action: .captureScreenshot(reason: "requested in goal"), confidence: 0.95,
                            rationale: "screenshot requested")
        case "take", "grab", "snap":
            // EN wraps the noun after a generic verb: "take a screenshot",
            // "grab the screen". Anything else these verbs could take
            // (a note, a break) is not a screenshot — abstain instead.
            let a = intent.arg.lowercased()
            guard a.contains("screenshot") || a.contains("screen")
                    || a.contains("picture") || a.contains("photo") else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs a screenshot-like noun")
            }
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
            guard !intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs an expectation")
            }
            return Decision(action: .verify(expectation: intent.arg), confidence: 0.9,
                            rationale: "verify '\(intent.arg)' on screen")
        case "done", "selesai", "finish":
            return Decision(action: .done(summary: "done"), confidence: 0.95, rationale: "done intent")
        case "click", "press", "klik", "tekan", "set", "isi":
            guard !intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs a target")
            }
            // "tekan enter" / "press return" / "press cmd s" — when the arg
            // is a key name (or combo), it's a keystroke, not an AX click.
            // Without this the policy searches the tree for a node literally
            // named "enter" and abstains on the most common follow-up a user
            // says after typing. Only the keystroke verbs route here —
            // "klik a" still means click the element named "a".
            if ["tekan", "press"].contains(intent.verb),
               let combo = Self.keyNames(intent.arg) {
                return Decision(action: .keyCombo(keys: combo), confidence: 0.95,
                                rationale: "key press \(intent.arg)")
            }
            // "isi <field> dengan <value>" / "set <field> to <value>" —
            // the needle is the field name; the value is what lands in it.
            var needle = intent.arg, setValue: String? = nil
            if intent.verb == "set" || intent.verb == "isi" {
                for sep in [" dengan ", " menjadi ", " to ", "=", ":"] {
                    if let r = intent.arg.range(of: sep, options: .caseInsensitive) {
                        needle = String(intent.arg[intent.arg.startIndex..<r.lowerBound])
                            .trimmingCharacters(in: .whitespaces)
                        setValue = String(intent.arg[r.upperBound...])
                            .trimmingCharacters(in: .whitespaces)
                        break
                    }
                }
                if setValue == nil { setValue = intent.arg }
            }
            guard !needle.isEmpty else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs a field name")
            }
            guard let tree = observation.axTree else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "need AX tree to find '\(needle)'")
            }
            let candidates: [(AXNode, Double)] = tree.flattened
                .map { ($0, AXPolicy.matchScore(needle, $0)) }
                .filter { $0.1 > 0 }
                .sorted { $0.1 > $1.1 }
            guard let (node, score) = candidates.first else {
                return Decision(action: nil, confidence: 0.25,
                                rationale: "no AX element matches '\(needle)'")
            }
            let isPressable = AXPolicy.pressableRoles.contains(node.role)
            let action: Action
            if let setValue {
                action = .axSetValue(ref: node.ref, value: setValue)
            } else if isPressable {
                action = .axPress(ref: node.ref)
            } else {
                // No frame → clicking (0,0) would hit the menu bar corner.
                guard let f = node.frame else {
                    return Decision(action: nil, confidence: 0.2,
                                    rationale: "matched \(node.ref) but it has no frame to click")
                }
                action = .click(x: f.x + f.w / 2, y: f.y + f.h / 2)
            }
            // Ambiguity penalty: second-place close behind → less sure.
            let runnerUp = candidates.dropFirst().first?.1 ?? 0
            let confidence = min(0.95, score * (runnerUp > score - 0.15 ? 0.75 : 1.0))
            return Decision(action: action, confidence: confidence,
                            rationale: "matched \(node.ref) \(node.role) \"\(node.title ?? node.desc ?? node.help ?? "")\" score=\(score)")
        default:
            return Decision(action: nil, confidence: 0.1,
                            rationale: "unknown verb '\(intent.verb)' — needs a smarter brain")
        }
    }
}
