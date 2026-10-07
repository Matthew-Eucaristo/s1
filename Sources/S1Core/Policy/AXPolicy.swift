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
    /// The deterministic grammar's policy name ("s1:ax" in run logs).
    public static let grammarName = "ax"
    public let name = AXPolicy.grammarName
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
        let goal = typeItRewrite(goal) ?? goal
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
                // "search for X" / "google X": in a browser, the address bar.
                if ["search", "google"].contains(verb), !arg.isEmpty {
                    var q = arg
                    for lead in ["for ", "the web for ", "google for ", "on google for "] where q.lowercased().hasPrefix(lead) {
                        q = String(q.dropFirst(lead.count))
                    }
                    return [Intent(verb: "addressbar", arg: ""), Intent(verb: "type", arg: q),
                            Intent(verb: "key", arg: "return")]
                }
                return Self.expand(Intent(verb: verb, arg: arg))
            }
    }

    /// One spoken intent → the steps it really means:
    /// - "pilih Large dari Size" / "select X from Y" → click Y, click X (open
    ///   the dropdown, pick the item — the item exists once the menu is open);
    /// - "select X" (not "select all") → click X;
    /// - "press tab 3 times" / "tekan panah bawah 5 kali" → the step, N times;
    /// - "press 1 2 3" → three key presses (a sequence, not a chord).
    static func expand(_ intent: Intent) -> [Intent] {
        var verb = intent.verb, arg = intent.arg
        if ["select", "pilih", "choose"].contains(verb) {
            for sep in [" from ", " dari ", " in ", " di "] {
                if let r = arg.range(of: sep, options: .caseInsensitive) {
                    let item = String(arg[..<r.lowerBound]), menu = String(arg[r.upperBound...])
                    if !item.isEmpty, !menu.isEmpty {
                        return [Intent(verb: "click", arg: menu), Intent(verb: "click", arg: item)]
                    }
                }
            }
            let all = ["all", "everything", "semua", "semuanya", "all text"]
            if !arg.isEmpty, !all.contains(arg.lowercased()) { verb = "click" }
        }
        guard !typeVerbs.contains(verb) else { return [Intent(verb: verb, arg: arg)] }
        var times = 1
        let words = ["once": 1, "twice": 2, "thrice": 3, "sekali": 1, "dua kali": 2, "tiga kali": 3]
        if let m = arg.firstMatch(of: /(?i)\s*(\d{1,2})\s*(?:times|time|kali|x)$/), let n = Int(m.1) {
            times = n; arg = String(arg[..<m.range.lowerBound])
        } else if let (w, n) = words.first(where: { arg.lowercased().hasSuffix(" " + $0.key) || arg.lowercased() == $0.key }) {
            times = n; arg = String(arg.dropLast(w.count)).trimmingCharacters(in: .whitespaces)
        }
        times = min(max(times, 1), 50)
        var steps = [Intent(verb: verb, arg: arg)]
        if ["press", "tekan", "key", "keys"].contains(verb), let keys = keyNames(arg),
           keys.count > 1, keys.allSatisfy({ !keyModifiers.contains($0) }) {
            steps = keys.map { Intent(verb: "key", arg: $0) }
        }
        return Array(repeating: steps, count: times).flatMap { $0 }
    }

    /// A running app the spoken name means, from the snapshot's app list.
    static func runningApp(_ spoken: String, in obs: Snapshot) -> String? {
        let name = AppResolver.spokenAppName(spoken)
        guard !name.isEmpty, !["window", "jendela", "tab", "notification", "notifikasi"].contains(name) else { return nil }
        let names = obs.appStates.map(\.name) + [obs.frontmostApp].compactMap { $0 }
        if let exact = names.first(where: { $0.lowercased() == name }) { return exact }
        return names.map { ($0, AppResolver.similarity(name, $0)) }
            .filter { $0.1 >= AppResolver.quitCutoff }.max { $0.1 < $1.1 }?.0
    }

    static let browsers: Set<String> = ["Google Chrome", "Safari", "Arc", "Firefox", "Microsoft Edge",
                                        "Brave Browser", "Orion", "Dia", "Vivaldi", "Opera", "Zen", "Chromium"]

    /// Best-matching on-screen element for a spoken label.
    static func best(_ needle: String, in tree: AXNode) -> AXNode? {
        tree.flattened.map { ($0, matchScore(needle, $0)) }
            .filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
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
        let original = s.trimmingCharacters(in: .whitespacesAndNewlines)
        var g = original
        let fillers = ["s1", "es satu", "es one", "hey s1", "hai s1", "hello", "hi", "hey", "halo", "hai",
                       "uh", "uhm", "um", "umm", "erm", "eh", "ehm", "hmm", "mm", "ah", "oh", "anu",
                       "okay", "ok", "tolong", "please", "coba", "bisa", "boleh", "mohon",
                       "can you", "could you", "would you", "ayo", "c'mon", "yuk"]
        var stripped = true
        while stripped {
            stripped = false
            let low = g.lowercased()
            for f in fillers where low == f || low.hasPrefix(f + " ") || low.hasPrefix(f + ",") || low.hasPrefix(f + ".") {
                g = String(g.dropFirst(f.count)).trimmingCharacters(
                    in: .whitespacesAndNewlines.union(.punctuationCharacters))
                stripped = true
                break
            }
        }
        // Trailing politeness: "close my reminder please?", "buka notes ya".
        for tail in [" please", " ya", " dong", " deh", " thanks", " thank you", " plz"] {
            let t = g.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            if t.lowercased().hasSuffix(tail) { g = String(t.dropLast(tail.count)); break }
        }
        // Only filler ("hello", "please"): keep it — chit-chat for the
        // Reasoner, not an empty command that finishes instantly as "done".
        return g.trimmingCharacters(in: .whitespaces).isEmpty ? original : g
    }

    /// "Okay, all good, please type it into my chat box" → "type Okay, all
    /// good": the words before "type it" ARE the text (kept verbatim —
    /// "okay" is part of what the user said, not filler here).
    static func typeItRewrite(_ goal: String) -> String? {
        let pattern = #"^(.+?)[\s,.;:!?-]+(?:(?:and|then|now|terus|lalu)\s+)?(?:(?:please|pls|tolong|can you|could you)\s+)?(?:type|write|ketik|tulis|input|enter)\s+(?:it|that|this|them|itu|ini|aja)(?:\s+(?:in|into|on|to|here|there|di|ke|disini|di sini)\b.*)?[\s.!?]*$"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let m = re.firstMatch(in: goal, range: NSRange(goal.startIndex..., in: goal)),
              let r = Range(m.range(at: 1), in: goal) else { return nil }
        let text = goal[r].trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;:-")))
        // "open Notes and type it" has no text before it — not a dictation.
        guard !text.isEmpty, !startsWithVerb(stripFillers(text)) else { return nil }
        return "type " + text
    }

    /// "tab 3", "the third tab", "tab terakhir" → ⌘N in a browser; "the
    /// TikTok tab", "tab tiktok" → press the tab whose title matches.
    /// nil = not about picking a tab (new/next/previous keep their own rules).
    static func tabDecision(_ phrase: String, in obs: Snapshot) -> Decision? {
        var p = phrase.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
        guard p.range(of: #"\btab\b"#, options: .regularExpression) != nil else { return nil }
        let before = p
        p = p.replacingOccurrences(
            of: #"^(?:(?:switch|go|move|jump|change|pindah|ganti|buka|open|select|pilih|click|klik)\s+)?(?:(?:to|ke)\s+)?(?:the\s+|my\s+)?"#,
            with: "", options: .regularExpression)
        // "close tab" / "new tab" aren't picks: a title needs a picking verb
        // ("go to the X tab") or the "tab X" form.
        let picking = p != before || p.hasPrefix("tab ")
        let ordinals: [String: Int] = [
            "first": 1, "1st": 1, "one": 1, "pertama": 1, "second": 2, "2nd": 2, "two": 2, "kedua": 2,
            "third": 3, "3rd": 3, "three": 3, "ketiga": 3, "fourth": 4, "4th": 4, "four": 4, "keempat": 4,
            "fifth": 5, "5th": 5, "five": 5, "kelima": 5, "sixth": 6, "6th": 6, "six": 6, "keenam": 6,
            "seventh": 7, "7th": 7, "seven": 7, "ketujuh": 7, "eighth": 8, "8th": 8, "eight": 8,
            "kedelapan": 8, "last": 9, "terakhir": 9,
        ]
        func capture(_ pattern: String) -> String? {
            guard let r = p.range(of: pattern, options: .regularExpression) else { return nil }
            return String(p[r])
        }
        var number: Int?, title: String?
        if let m = capture(#"^tab\s+(?:ke\s*-?\s*|nomor\s+|number\s+)?\d+$"#) {
            number = Int(m.filter(\.isNumber))
        } else if let m = capture(#"^\S+\s+tab$"#) {
            let w = String(m.dropLast(4))
            if let n = ordinals[w] { number = n } else { title = w }
        } else if let m = capture(#"^tab\s+\S+$"#), let n = ordinals[String(m.dropFirst(4))] {
            number = n
        } else if p.hasSuffix(" tab") {
            title = String(p.dropLast(4))
        } else if p.hasPrefix("tab ") {
            title = String(p.dropFirst(4))
        }
        let tabs = tabButtons(in: obs.axTree)
        if let n = number {
            if let app = obs.frontmostApp, browsers.contains(app), (1...9).contains(n) {
                return Decision(action: .keyCombo(keys: ["cmd", String(n)]), confidence: 0.95,
                                rationale: n == 9 ? "last tab" : "tab \(n)")
            }
            guard n >= 1, n <= tabs.count else { return nil }
            let tab = n == 9 && tabs.count < 9 ? tabs[tabs.count - 1] : tabs[n - 1]
            return Decision(action: .axPress(ref: tab.ref), confidence: 0.9, rationale: "tab \(n)")
        }
        if picking, let t = title {
            if ["next", "berikutnya", "selanjutnya", "lanjut"].contains(t) {
                return Decision(action: .keyCombo(keys: ["ctrl", "tab"]), confidence: 0.9, rationale: "next tab")
            }
            if ["previous", "prev", "sebelumnya"].contains(t) {
                return Decision(action: .keyCombo(keys: ["ctrl", "shift", "tab"]), confidence: 0.9,
                                rationale: "previous tab")
            }
        }
        guard picking, var t = title?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
              !["new", "baru", "next", "previous", "prev", "berikutnya", "sebelumnya", "lanjut",
                "this", "ini", "that", "itu", "a", "another"].contains(t) else { return nil }
        t = t.replacingOccurrences(of: #"^(?:the|my)\s+"#, with: "", options: .regularExpression)
        let scored = tabs.compactMap { tab -> (AXNode, Double)? in
            let name = (tab.title ?? tab.desc ?? "").lowercased()
            guard !name.isEmpty else { return nil }
            if name.contains(t) { return (tab, 1) }
            let score = AppResolver.similarity(t, String(name.prefix(max(t.count + 8, 16))))
            return score >= 0.6 ? (tab, score) : nil
        }
        guard let best = scored.max(by: { $0.1 < $1.1 }) else { return nil }
        return Decision(action: .axPress(ref: best.0.ref), confidence: best.1 >= 1 ? 0.92 : 0.8,
                        rationale: "switch to tab “\(best.0.title ?? best.0.desc ?? t)”")
    }

    /// The tab strip's tabs: radio buttons inside a tab group, in order.
    static func tabButtons(in tree: AXNode?) -> [AXNode] {
        guard let tree else { return [] }
        var out: [AXNode] = []
        func walk(_ n: AXNode, inTabs: Bool) {
            if inTabs, n.role == "AXRadioButton" { out.append(n) }
            for c in n.children { walk(c, inTabs: inTabs || n.role == "AXTabGroup") }
        }
        walk(tree, inTabs: false)
        return out
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
        "ubah", "rename", "ganti", "remove", "buang", "replace", "change",
        "choose", "hover", "arahkan", "google",
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
            // "… and then please search …": politeness before the verb.
            let rest = stripFillers(String(s[r.upperBound...]))
            let next = rest.split(separator: " ", maxSplits: 1).first?.lowercased() ?? ""
            // Inside a type segment, ordinary dictation words stay literal
            // — "type ready and next" is text; only unambiguous command
            // verbs ("click", "open") still split.
            if (verbs.contains(next) || editVerbs.contains(next))
               && !(typeWords.contains(next) && startsWithTypeVerb(s)) {
                return splitOnConj(String(s[..<r.lowerBound]), conj: conj) +
                       splitOnConj(rest, conj: conj)
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
            let rest = stripFillers(String(s[r.upperBound...]))
            let next = rest.split(separator: " ", maxSplits: 1).first?.lowercased() ?? ""
            if (verbs.contains(next) || editVerbs.contains(next))
               && !(typeWords.contains(next) && startsWithTypeVerb(s)) {
                return splitConjunctions(String(s[..<r.lowerBound])) +
                       splitConjunctions(rest)
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
        // A failed step stops the chain instead of cascading — "buka X lalu
        // ketik Y" must not type into a random app when the open failed —
        // and is never "done", even when it was the last intent.
        // "blocked:" counts too (denylist/gate stop), same as VLM's cursor.
        if let last = history.last,
           last.outcome?.hasPrefix("error:") == true || last.outcome?.hasPrefix("blocked:") == true {
            return Decision(action: nil, confidence: 0.15,
                            rationale: "previous step failed — abstaining instead of cascading")
        }
        // Once the Reasoner has acted, it owns the run: the grammar's intent
        // count no longer matches what happened, so it can't claim "done".
        if history.contains(where: { $0.decidedBy.hasPrefix("s2:") && $0.action != nil }) {
            return Decision(action: nil, confidence: 0.1,
                            rationale: "the Reasoner took over this run — it decides what's next")
        }
        guard history.count < intents.count else {
            return Decision(action: .done(summary: "goal completed"), confidence: 0.95,
                            rationale: "all \(intents.count) intents consumed")
        }
        let intent = intents[history.count]
        // "close/quit/tutup <a running app>" quits it gracefully — before
        // the notification skill, so "close my reminder" with Reminders open
        // closes Reminders.
        if ["close", "tutup", "quit", "keluar", "exit"].contains(intent.verb), !intent.arg.isEmpty,
           let app = Self.runningApp(intent.arg, in: observation) {
            return Decision(action: .quitApp(name: app), confidence: 0.9, rationale: "quit \(app)")
        }
        // Tabs by number or by title: "go to tab 3", "switch to the TikTok tab".
        if let d = Self.tabDecision(intent.verb + " " + intent.arg, in: observation) { return d }
        // Mac skills: settings panes, folders, system shortcuts by name.
        if let skill = MacSkills.match(intent.verb + " " + intent.arg) {
            return Decision(action: skill.action, confidence: 0.95, rationale: "Mac skill: \(skill.label)")
        }
        switch intent.verb {
        case "open", "buka", "launch":
            guard !intent.arg.isEmpty else {
                return Decision(action: nil, confidence: 0.15,
                                rationale: "'\(intent.verb)' needs an app name")
            }
            // Dictation ends sentences with a period: "Open Notepad." names "Notepad".
            var app = intent.arg.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces))
            // "open my editor" → the app memory says ("my editor is Zed").
            var why = "open \(app)"
            if let named = Memory.resolve(app) { why = "open \(app) → \(named) (memory)"; app = named }
            return Decision(action: .openApp(name: app), confidence: 0.9, rationale: why)
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
        case "addressbar":
            // Only browsers have one; elsewhere "search for X" means
            // something app-specific — the Reasoner decides.
            guard let app = observation.frontmostApp, Self.browsers.contains(app) else {
                return Decision(action: nil, confidence: 0.2, rationale: "search outside a browser — needs S2")
            }
            return Decision(action: .keyCombo(keys: ["cmd", "l"]), confidence: 0.95,
                            rationale: "focus \(app)'s address bar")
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
            let a = intent.arg.lowercased()
            if ["top", "paling atas", "awal", "ke atas sekali"].contains(where: a.contains) {
                return Decision(action: .keyCombo(keys: ["cmd", "up"]), confidence: 0.9, rationale: "scroll to top")
            }
            if ["bottom", "paling bawah", "akhir"].contains(where: a.contains) {
                return Decision(action: .keyCombo(keys: ["cmd", "down"]), confidence: 0.9, rationale: "scroll to bottom")
            }
            var d: (Double, Double) = (0, 300)          // "down"/"bawah" + bare "scroll"
            if a.contains("up") || a.contains("atas") { d = (0, -300) }
            else if a.contains("left") || a.contains("kiri") { d = (-300, 0) }
            else if a.contains("right") || a.contains("kanan") { d = (300, 0) }
            let k = ["a lot", "banyak", "jauh", "far"].contains(where: a.contains) ? 3.0
                : ["a little", "a bit", "sedikit", "dikit"].contains(where: a.contains) ? 0.35 : 1.0
            return Decision(action: .scroll(dx: d.0 * k, dy: d.1 * k), confidence: 0.9,
                            rationale: "scroll \(a.isEmpty ? "down" : a)")
        case "drag", "seret":
            // "drag report.pdf to Trash" / "seret X ke Y": element to element.
            let parts = intent.arg.components(separatedBy: " to ").count == 2
                ? intent.arg.components(separatedBy: " to ")
                : intent.arg.components(separatedBy: " ke ")
            guard parts.count == 2, let tree = observation.axTree,
                  let from = Self.best(parts[0].trimmingCharacters(in: .whitespaces), in: tree)?.frame,
                  let to = Self.best(parts[1].trimmingCharacters(in: .whitespaces), in: tree)?.frame else {
                return Decision(action: nil, confidence: 0.2, rationale: "drag what to where? — needs S2")
            }
            return Decision(action: .drag(fromX: from.x + from.w / 2, fromY: from.y + from.h / 2,
                                          toX: to.x + to.w / 2, toY: to.y + to.h / 2),
                            confidence: 0.8, rationale: "drag \(parts[0]) → \(parts[1])")
        case "hover", "arahkan":
            var needle = intent.arg
            for lead in ["over ", "on ", "ke ", "di "] where needle.lowercased().hasPrefix(lead) {
                needle = String(needle.dropFirst(lead.count)); break
            }
            guard let tree = observation.axTree, let f = Self.best(needle, in: tree)?.frame else {
                return Decision(action: nil, confidence: 0.2, rationale: "hover over what? — needs S2")
            }
            return Decision(action: .moveMouse(x: f.x + f.w / 2, y: f.y + f.h / 2), confidence: 0.85,
                            rationale: "hover \(needle)")
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
            let target = AppResolver.spokenAppName(intent.arg)
            guard intent.arg.isEmpty || ["window", "this window", "jendela", "jendela ini", "tab", "this tab", "ini"].contains(target) else {
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
            return Decision(action: .quitApp(name: ""), confidence: 0.9,
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
        case "delete", "hapus", "remove", "buang", "replace", "ganti", "ubah", "change":
            // Bare "delete" is the key; with words it's voice editing of the
            // focused text: "hapus kata ayam", "replace cat with dog".
            if intent.arg.isEmpty, ["delete", "hapus"].contains(intent.verb) {
                return Decision(action: .keyCombo(keys: ["delete"]), confidence: 0.9,
                                rationale: "delete key")
            }
            guard let edit = VoiceEdit.parse(verb: intent.verb, arg: intent.arg) else {
                return Decision(action: nil, confidence: 0.2,
                                rationale: "'\(intent.verb) \(intent.arg)' isn't a text edit — needs S2")
            }
            return Decision(action: .editText(find: edit.find, replace: edit.replace), confidence: 0.9,
                            rationale: edit.replace.isEmpty ? "delete “\(edit.find)” in the focused text"
                                                            : "replace “\(edit.find)” with “\(edit.replace)”")
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
