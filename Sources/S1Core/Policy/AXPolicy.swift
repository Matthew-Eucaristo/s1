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
    public var judgeable: Bool { false }
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
        // Dictation arrives as sentences: "Please type hi. Please open Notes."
        // A sentence that starts (after filler) with a verb is a new command;
        // any other sentence continues the previous one's text.
        var segments: [String] = []
        let sentences = goal.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"(?<=[.!?])\s+"#, with: "\u{0}", options: .regularExpression)
            .split(separator: "\u{0}").map(String.init)
        for sentence in sentences {
            let t = stripFillers(sentence)
            if segments.isEmpty || startsWithVerb(t) { segments.append(t) }
            else { segments[segments.count - 1] += " " + sentence }
        }
        // Punctuation is an unconditional separator. Word conjunctions are
        // NOT — "lalu"/"then" also appear inside text the user wants typed
        // ("ketik aku lalu pergi" must type all three words). Every one of
        // them goes through the same gate as "and"/"dan": split only when
        // the following word is a grammar verb.
        let conjWords = ["and then", "habis itu", "abis itu", "setelah itu",
                         "kemudian", "lantas", "lalu", "then",
                         "terus", "trus"]
        var parts: [String] = []
        for segment in segments {
            for piece in segment.components(separatedBy: CharacterSet(charactersIn: ",;"))
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }) where !piece.isEmpty {
                // Text keeps its commas: "type, I want to eat" and "type hello,
                // world" are one thing to type, not a verb plus an unknown one.
                if let last = parts.last, startsWithTypeVerb(last), !startsWithVerb(stripFillers(piece)) {
                    let bare = last.split(separator: " ").count == 1
                    parts[parts.count - 1] = last + (bare ? " " : ", ") + piece
                } else {
                    parts.append(stripFillers(piece))
                }
            }
        }
        for c in conjWords { parts = parts.flatMap { splitOnConj($0, conj: c) } }
        return parts
            // "and"/"dan" are ambiguous — real words inside typed text
            // ("milk and honey") AND conjunctions ("open X and type Y").
            // Split only when the following word is a grammar verb.
            .flatMap { splitConjunctions($0) }
            .flatMap { part -> [Intent] in
                let words = part.split(separator: " ", maxSplits: 1)
                var verb = words.first?.lowercased() ?? ""
                var arg = words.count > 1 ? String(words[1]) : ""
                // A trailing conjunction can't open a new command — "buka
                // notes lalu" must not hunt for an app literally called
                // "notes lalu". Text verbs are exempt: their arg is literal.
                if !typeVerbs.contains(verb) {
                    arg = stripTrailingConjunction(arg)
                }
                // Click flavors normalize to marker verbs so decide() shares
                // one AX-resolution path: "double click Save" → dclick Save,
                // "klik kanan X" → rclick X, "right click X" → rclick X.
                let low = arg.lowercased()
                if ["double", "dobel"].contains(verb) {
                    if low.hasPrefix("click ") { arg = String(arg.dropFirst(6)); verb = "dclick" }
                    else if low.hasPrefix("klik ") { arg = String(arg.dropFirst(5)); verb = "dclick" }
                } else if verb == "right", low.hasPrefix("click ") {
                    arg = String(arg.dropFirst(6)); verb = "rclick"
                } else if verb == "klik" {
                    if low.hasPrefix("dua kali ") { arg = String(arg.dropFirst(9)); verb = "dclick" }
                    else if low.hasPrefix("kanan ") { arg = String(arg.dropFirst(6)); verb = "rclick" }
                }
                // "find X" / "cari X" desugars to open-the-find-bar + type —
                // two ordinary steps the loop already sequences.
                if ["find", "cari"].contains(verb), !arg.isEmpty {
                    return [Intent(verb: "key", arg: "cmd f"), Intent(verb: "type", arg: arg)]
                }
                return [Intent(verb: verb, arg: arg)]
            }
    }

    /// Every verb the grammar (and the model hints) understands — used to
    /// decide whether "and"/"dan" starts a new command or is literal text.
    /// Includes verbs the grammar doesn't implement: "buka Notes dan tutup"
    /// must still split so the second half abstains cleanly instead of
    /// polluting the first half's argument ("Notes dan tutup").
    /// Every way people say "put this text here".
    static let typeVerbs: Set<String> = ["type", "ketik", "write", "tulis", "chat", "input",
                                         "reply", "balas", "enter", "masukkan"]
    /// Clipboard/edit verbs. They split "and/then" only outside typed text —
    /// "type copy and paste" still types all three words.
    static let editVerbs: Set<String> = ["copy", "salin", "paste", "tempel", "cut", "potong",
                                         "undo", "redo", "save", "simpan"]

    /// Leading politeness/wake filler dictation loves to prepend — "tolong
    /// buka …", "please open …", "hey s1, open …". Without this the first
    /// word becomes an unknown verb and escalates.
    static func stripFillers(_ s: String) -> String {
        var g = s.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    static func startsWithVerb(_ s: String) -> Bool {
        let first = s.split(separator: " ", maxSplits: 1).first
            .map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) } ?? ""
        return verbs.contains(first) || editVerbs.contains(first)
    }

    static func startsWithTypeVerb(_ s: String) -> Bool {
        typeVerbs.contains(s.split(separator: " ", maxSplits: 1).first?.lowercased() ?? "")
    }

    static let verbs: Set<String> = [
        "open", "buka", "launch", "type", "ketik", "write", "tulis",
        "chat", "input", "reply", "balas", "masukkan",
        "key", "keys", "hotkey", "wait", "tunggu",
        "screenshot", "capture", "screencap", "tangkap", "tangkapan",
        "foto", "potret", "ambil", "scroll", "gulir", "geser",
        "verify", "cek", "check", "pastikan", "done", "selesai", "finish",
        "click", "press", "klik", "tekan", "set", "isi",
        "take", "grab", "snap",
        // Window/tab/app control — all implemented below as keyCombos or
        // media keys, no model needed.
        "tutup", "close", "quit", "keluar", "exit", "matikan", "hide",
        "sembunyikan", "minimize", "kecilkan", "maximize", "besarkan",
        "fullscreen", "layar", "new", "baru", "tab", "next", "previous",
        "prev", "sebelumnya", "back", "kembali", "forward", "maju",
        "reload", "refresh", "muat", "switch", "lock", "kunci",
        // Media + edit.
        "play", "pause", "jeda", "skip", "lewati", "mute", "bisukan",
        "senyap", "bisu", "volume", "suara", "naikkan", "keraskan",
        "cari", "find", "search", "save", "simpan", "undo", "redo",
        "zoom", "select", "pilih", "stop", "berhenti", "delete", "hapus",
        "double", "dobel", "right",
        "restart", "mulai", "start", "drag", "seret", "drop", "resize",
        "ubah", "rename", "ganti",
    ]

    /// Drop a dangling conjunction at the end of a part ("buka notes lalu"
    /// → "buka notes"). Repeated in case transcription chains them
    /// ("… dan lalu").
    static func stripTrailingConjunction(_ s: String) -> String {
        let conjs = ["dan", "and", "lalu", "then", "terus", "trus", "lantas",
                     "kemudian", "setelah itu", "habis itu", "abis itu", "and then"]
        var out = s.trimmingCharacters(in: .whitespaces)
        var changed = true
        while changed {
            changed = false
            for c in conjs where out.lowercased().hasSuffix(" " + c) {
                out = String(out.dropLast(c.count + 1))
                    .trimmingCharacters(in: .whitespaces)
                changed = true
                break
            }
        }
        return out
    }

    /// Split " A <conj> B " only when B starts with a grammar verb —
    /// otherwise the conjunction is literal text the user wants typed.
    /// Recurses so several conjunctions chain correctly.
    static func splitOnConj(_ s: String, conj: String) -> [String] {
        let needle = " +\(NSRegularExpression.escapedPattern(for: conj)) +"
        var searchFrom = s.startIndex
        while let r = s.range(of: needle, options: [.regularExpression, .caseInsensitive],
                              range: searchFrom ..< s.endIndex) {
            let next = s[r.upperBound...]
                .split(separator: " ", maxSplits: 1).first?.lowercased() ?? ""
            // Inside a type segment, ordinary dictation words stay literal
            // — "type ready and next" is text; only unambiguous command
            // verbs ("click", "open") still split.
            if (verbs.contains(next) || editVerbs.contains(next))
               && !(typeWords.contains(next) && startsWithTypeVerb(s)) {
                return splitOnConj(String(s[..<r.lowerBound]), conj: conj) +
                       splitOnConj(String(s[r.upperBound...]), conj: conj)
            }
            searchFrom = r.upperBound
        }
        return [s]
    }

    /// Split " A and B "/" A dan B " only when B starts with a grammar verb —
    /// otherwise it's literal text the user wants typed. Recurses so several
    /// conjunctions chain correctly.
    static func splitConjunctions(_ s: String) -> [String] {
        var searchFrom = s.startIndex
        while let r = s.range(of: " +(and|dan) +", options: [.regularExpression, .caseInsensitive],
                              range: searchFrom ..< s.endIndex) {
            let next = s[r.upperBound...]
                .split(separator: " ", maxSplits: 1).first?.lowercased() ?? ""
            if (verbs.contains(next) || editVerbs.contains(next))
               && !(typeWords.contains(next) && startsWithTypeVerb(s)) {
                return splitConjunctions(String(s[..<r.lowerBound])) +
                       splitConjunctions(String(s[r.upperBound...]))
            }
            searchFrom = r.upperBound
        }
        return [s]
    }

    /// How a Judge sees one candidate control: role, label, and where it is.
    static func label(_ n: AXNode) -> String {
        let role = n.role.replacingOccurrences(of: "AX", with: "")
        let name = n.title ?? n.desc ?? n.help ?? n.value ?? n.ref
        let at = n.frame.map { " at (\(Int($0.x)), \(Int($0.y)))" } ?? ""
        return "\(role) \"\(name.prefix(60))\"\(at)"
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

    /// Verbs that are ALSO ordinary dictation words — inside a segment that
    /// starts with a type verb they stay literal text, not command starts.
    /// "type ready and next" stays one intent; "type … and click Save"
    /// still splits because nobody dictates "click Save" into a field.
    static let typeWords: Set<String> = editVerbs.union([
        "close", "quit", "exit", "hide", "new", "next", "previous", "prev",
        "back", "forward", "switch", "lock", "play", "pause", "stop", "skip",
        "mute", "volume", "find", "search", "zoom", "select", "delete",
        "double", "right", "drag", "drop", "resize", "start", "restart",
        "ganti", "set", "isi",
    ])

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
                                || CGEventActuator.keyCodes[$0] != nil
                                || CGEventActuator.mediaKeys[$0] != nil }) else { return nil }
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
            // Dictation ends sentences with a period: "Open Notepad." names "Notepad".
            let app = intent.arg.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            return Decision(action: .openApp(name: app), confidence: 0.9,
                            rationale: "open \(app)")
        case _ where Self.typeVerbs.contains(intent.verb):
            // A bare "enter" after typing is the Return key, not text.
            if intent.arg.isEmpty, intent.verb == "enter" {
                return Decision(action: .keyCombo(keys: ["return"]), confidence: 0.95,
                                rationale: "key press enter")
            }
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
            // Route through keyNames: aliases ("panah kiri" → left) resolve
            // here too — the raw split only knows literal keyCodes, so
            // "key panah kiri" would otherwise die at the actuator. A nil
            // means every token already failed validation, so abstain to
            // S2 instead of posting a guaranteed-error keyCombo.
            guard let keys = Self.keyNames(intent.arg) else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "unknown key name '\(intent.arg)'")
            }
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
        case "click", "press", "klik", "tekan", "set", "isi", "dclick", "rclick":
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
                // "set username" alone is meaningless — without a separator
                // the old fallback would write the field's own name into
                // it. Abstain so S2 can figure out the real intent.
                guard let v = setValue, !v.isEmpty else {
                    return Decision(action: nil, confidence: 0.15,
                                    rationale: "'\(intent.verb)' needs a value: '\(intent.verb) <field> to <value>'")
                }
                setValue = v
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
            // The action that targets one matched element, or nil (no frame).
            func target(_ n: AXNode) -> Action? {
                if let setValue { return .axSetValue(ref: n.ref, value: setValue) }
                if intent.verb == "dclick" || intent.verb == "rclick" {
                    // AXPress is single-click semantics — flavor clicks go
                    // pixel at the element's center instead.
                    guard let f = n.frame else { return nil }
                    return intent.verb == "dclick"
                        ? .doubleClick(x: f.x + f.w / 2, y: f.y + f.h / 2)
                        : .rightClick(x: f.x + f.w / 2, y: f.y + f.h / 2)
                }
                if AXPolicy.pressableRoles.contains(n.role) { return .axPress(ref: n.ref) }
                // No frame → clicking (0,0) would hit the menu bar corner.
                guard let f = n.frame else { return nil }
                return .click(x: f.x + f.w / 2, y: f.y + f.h / 2)
            }
            guard let action = target(node) else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "matched \(node.ref) but it has no frame to click")
            }
            // Ambiguity penalty: second-place close behind → less sure, and
            // the close calls go along so a Judge can pick the right one.
            let runnerUp = candidates.dropFirst().first?.1 ?? 0
            let ambiguous = runnerUp > score - 0.15
            let confidence = min(0.95, score * (ambiguous ? 0.75 : 1.0))
            let options: [Decision.Option]? = ambiguous
                ? candidates.prefix(5).filter { $0.1 > score - 0.15 }.compactMap { c in
                    target(c.0).map { Decision.Option(label: Self.label(c.0), action: $0) }
                  }
                : nil
            return Decision(action: action, confidence: confidence,
                            rationale: "matched \(node.ref) \(node.role) \"\(node.title ?? node.desc ?? node.help ?? "")\" score=\(score)",
                            options: (options?.count ?? 0) > 1 ? options : nil)
        case _ where Self.editVerbs.contains(intent.verb),
             "select", "pilih":
            // Standard edit shortcuts on whatever is focused/selected. A real
            // object ("paste it into Notes", "copy the link") needs S2.
            let a = intent.arg.lowercased().trimmingCharacters(in: .punctuationCharacters)
            let bare = ["", "it", "this", "that", "selection", "the selection", "text", "the text",
                        "ini", "itu", "teks", "teksnya", "here", "di sini", "disini"]
            let all = ["all", "everything", "semua", "semuanya", "all text"]
            let combo: [String]?
            switch intent.verb {
            case "copy", "salin": combo = bare.contains(a) ? ["cmd", "c"] : nil
            case "paste", "tempel": combo = bare.contains(a) ? ["cmd", "v"] : nil
            case "cut", "potong": combo = bare.contains(a) ? ["cmd", "x"] : nil
            case "undo": combo = a.isEmpty ? ["cmd", "z"] : nil
            case "redo": combo = a.isEmpty ? ["cmd", "shift", "z"] : nil
            case "save", "simpan": combo = bare.contains(a) ? ["cmd", "s"] : nil
            default: combo = all.contains(a) ? ["cmd", "a"] : nil     // select/pilih all
            }
            guard let combo else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "'\(intent.verb) \(intent.arg)' needs a target — S2")
            }
            return Decision(action: .keyCombo(keys: combo), confidence: 0.95,
                            rationale: "\(intent.verb) (\(combo.joined(separator: "+")))")
        // ---- Window / tab / app control: plain keyCombos, no model needed.
        case "close", "tutup":
            guard intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "close what? — object targets need S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "w"]), confidence: 0.9,
                            rationale: "close front window")
        case "quit", "keluar", "exit":
            guard intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "quit what? — named apps need S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "q"]), confidence: 0.9,
                            rationale: "quit frontmost app")
        case "minimize", "kecilkan":
            let a = intent.arg.lowercased()
            if a.contains("volume") || a.contains("suara") {
                return Decision(action: .keyCombo(keys: ["volumedown"]), confidence: 0.9,
                                rationale: "volume down")
            }
            guard a.isEmpty || ["window", "jendela"].contains(a) else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "minimize what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "m"]), confidence: 0.9,
                            rationale: "minimize window")
        case "hide", "sembunyikan":
            guard intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.2, rationale: "hide what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "h"]), confidence: 0.9,
                            rationale: "hide app")
        case "fullscreen", "maximize", "besarkan", "layar":
            let a = intent.arg.lowercased()
            if a.contains("volume") || a.contains("suara") {
                return Decision(action: .keyCombo(keys: ["volumeup"]), confidence: 0.9,
                                rationale: "volume up")
            }
            guard a.isEmpty || ["window", "jendela", "penuh", "layar"].contains(a) else {
                return Decision(action: nil, confidence: 0.2, rationale: "maximize what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["ctrl", "cmd", "f"]), confidence: 0.9,
                            rationale: "toggle fullscreen")
        case "zoom":
            switch intent.arg.lowercased() {
            case "in", "masuk", "perbesar", "+":
                return Decision(action: .keyCombo(keys: ["cmd", "equal"]), confidence: 0.9,
                                rationale: "zoom in")
            case "out", "keluar", "perkecil", "-":
                return Decision(action: .keyCombo(keys: ["cmd", "minus"]), confidence: 0.9,
                                rationale: "zoom out")
            case "reset", "normal", "100", "default":
                return Decision(action: .keyCombo(keys: ["cmd", "0"]), confidence: 0.9,
                                rationale: "zoom reset")
            default:
                return Decision(action: nil, confidence: 0.2, rationale: "zoom how? — needs S2")
            }
        case "new", "baru":
            switch intent.arg.lowercased() {
            case "tab":
                return Decision(action: .keyCombo(keys: ["cmd", "t"]), confidence: 0.9,
                                rationale: "new tab")
            case "window", "jendela":
                return Decision(action: .keyCombo(keys: ["cmd", "n"]), confidence: 0.9,
                                rationale: "new window")
            case "incognito", "private", "pribadi":
                return Decision(action: .keyCombo(keys: ["cmd", "shift", "n"]), confidence: 0.9,
                                rationale: "new private window")
            default:
                return Decision(action: nil, confidence: 0.2, rationale: "new what? — needs S2")
            }
        case "tab":
            switch intent.arg.lowercased() {
            case "baru":
                return Decision(action: .keyCombo(keys: ["cmd", "t"]), confidence: 0.9,
                                rationale: "new tab")
            case "next", "berikutnya", "lanjut":
                return Decision(action: .keyCombo(keys: ["ctrl", "tab"]), confidence: 0.9,
                                rationale: "next tab")
            case "previous", "prev", "sebelumnya":
                return Decision(action: .keyCombo(keys: ["ctrl", "shift", "tab"]), confidence: 0.9,
                                rationale: "previous tab")
            default:
                return Decision(action: nil, confidence: 0.2, rationale: "tab what? — needs S2")
            }
        case "next", "lanjut":
            switch intent.arg.lowercased() {
            case "tab": return Decision(action: .keyCombo(keys: ["ctrl", "tab"]), confidence: 0.9,
                                        rationale: "next tab")
            case "track", "lagu", "song", "music":
                return Decision(action: .keyCombo(keys: ["nexttrack"]), confidence: 0.9,
                                rationale: "next track")
            case "", "app", "aplikasi":
                return Decision(action: .keyCombo(keys: ["cmd", "tab"]), confidence: 0.9,
                                rationale: "next app")
            default: return Decision(action: nil, confidence: 0.2, rationale: "next what? — needs S2")
            }
        case "previous", "prev", "sebelumnya":
            switch intent.arg.lowercased() {
            case "tab": return Decision(action: .keyCombo(keys: ["ctrl", "shift", "tab"]),
                                        confidence: 0.9, rationale: "previous tab")
            case "track", "lagu", "song", "music":
                return Decision(action: .keyCombo(keys: ["prevtrack"]), confidence: 0.9,
                                rationale: "previous track")
            default: return Decision(action: nil, confidence: 0.2, rationale: "previous what? — needs S2")
            }
        case "back", "kembali":
            let a = intent.arg.lowercased()
            if ["track", "lagu", "song", "music"].contains(a) {
                return Decision(action: .keyCombo(keys: ["prevtrack"]), confidence: 0.9,
                                rationale: "previous track")
            }
            guard a.isEmpty else {
                return Decision(action: nil, confidence: 0.2, rationale: "back where? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "leftbracket"]), confidence: 0.85,
                            rationale: "navigate back")
        case "forward", "maju":
            guard intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.2, rationale: "forward where? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "rightbracket"]), confidence: 0.85,
                            rationale: "navigate forward")
        case "reload", "refresh":
            let a = intent.arg.lowercased()
            guard a.isEmpty || ["page", "halaman"].contains(a) else {
                return Decision(action: nil, confidence: 0.2, rationale: "reload what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "r"]), confidence: 0.9,
                            rationale: "reload")
        case "muat":
            guard ["ulang", "lagi"].contains(intent.arg.lowercased()) else {
                return Decision(action: nil, confidence: 0.15, rationale: "'muat' needs 'ulang'/'lagi'")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "r"]), confidence: 0.9,
                            rationale: "reload")
        case "delete", "hapus":
            guard intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.2, rationale: "delete what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["delete"]), confidence: 0.9,
                            rationale: "delete key")
        case "switch":
            switch intent.arg.lowercased() {
            case "", "app", "aplikasi", "apps":
                return Decision(action: .keyCombo(keys: ["cmd", "tab"]), confidence: 0.9,
                                rationale: "app switcher")
            case "window", "jendela":
                return Decision(action: .keyCombo(keys: ["cmd", "grave"]), confidence: 0.9,
                                rationale: "next window")
            default:
                return Decision(action: nil, confidence: 0.2, rationale: "switch to what? — needs S2")
            }
        case "lock", "kunci":
            guard intent.arg.isEmpty || ["screen", "layar"].contains(intent.arg.lowercased()) else {
                return Decision(action: nil, confidence: 0.2, rationale: "lock what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["ctrl", "cmd", "q"]), confidence: 0.85,
                            rationale: "lock screen")
        // ---- Media / volume: NX_SYSDEFINED aux keys, no model needed.
        case "play", "pause", "jeda":
            guard intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "'\(intent.verb) <thing>' needs S2")
            }
            return Decision(action: .keyCombo(keys: ["playpause"]), confidence: 0.9,
                            rationale: "play/pause")
        case "skip", "lewati":
            guard intent.arg.isEmpty || ["track", "lagu", "song", "music"].contains(intent.arg.lowercased()) else {
                return Decision(action: nil, confidence: 0.2, rationale: "skip what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["nexttrack"]), confidence: 0.9,
                            rationale: "next track")
        case "mute", "bisukan", "senyap", "bisu":
            let a = intent.arg.lowercased()
            guard a.isEmpty || ["volume", "suara"].contains(a) else {
                return Decision(action: nil, confidence: 0.2, rationale: "mute what? — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["mute"]), confidence: 0.9,
                            rationale: "mute")
        case "volume", "suara", "naikkan", "keraskan":
            let a = intent.arg.lowercased()
            // The verb itself is the direction — "keraskan suara" parses
            // as verb=keraskan arg=suara (the noun, not "up").
            if ["naikkan", "keraskan"].contains(intent.verb) {
                guard a.contains("volume") || a.contains("suara") else {
                    return Decision(action: nil, confidence: 0.2,
                                    rationale: "'\(intent.verb)' needs 'volume'/'suara' — needs S2")
                }
                return Decision(action: .keyCombo(keys: ["volumeup"]), confidence: 0.9,
                                rationale: "volume up")
            }
            switch a {
            case "up", "naik", "besar", "keras", "keraskan", "volume up", "naikkan volume", "keraskan volume", "keraskan suara", "naikkan suara":
                return Decision(action: .keyCombo(keys: ["volumeup"]), confidence: 0.9,
                                rationale: "volume up")
            case "down", "turun", "kecil", "volume down", "kecilkan volume", "kecilkan suara", "turunkan volume":
                return Decision(action: .keyCombo(keys: ["volumedown"]), confidence: 0.9,
                                rationale: "volume down")
            case "mute", "mati", "off", "bisukan", "senyap":
                return Decision(action: .keyCombo(keys: ["mute"]), confidence: 0.9,
                                rationale: "mute")
            default:
                return Decision(action: nil, confidence: 0.2,
                                rationale: "volume how? — up/down/mute")
            }
        default:
            return Decision(action: nil, confidence: 0.1,
                            rationale: "unknown verb '\(intent.verb)' — needs a smarter brain")
        }
    }
}
