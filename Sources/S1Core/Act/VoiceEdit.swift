import Foundation

/// Voice editing of the focused text: "hapus kata ayam", "replace cat with
/// dog". Pure text logic here; `CGEventActuator` selects the range in the
/// field and deletes or retypes it, so the app's own Undo covers the edit.
public enum VoiceEdit {
    /// Where `find` sits in `text` as a whole word (case-insensitive), as a
    /// UTF-16 range for AX. The LAST occurrence — what you just said or typed
    /// is usually what you want gone. Deleting also takes one neighbouring
    /// space so no double space is left behind.
    public static func range(of find: String, in text: String, deleting: Bool) -> NSRange? {
        let needle = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: needle) + #"(?![\p{L}\p{N}])"#
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = text as NSString
        guard var r = re.matches(in: text, range: NSRange(location: 0, length: ns.length)).last?.range else {
            return nil
        }
        if deleting {
            if r.location > 0, ns.character(at: r.location - 1) == 0x20 {
                r = NSRange(location: r.location - 1, length: r.length + 1)
            } else if r.location + r.length < ns.length, ns.character(at: r.location + r.length) == 0x20 {
                r = NSRange(location: r.location, length: r.length + 1)
            }
        }
        return r
    }

    /// The edit a spoken phrase asks for, from the words after the verb:
    /// "kata ayam" → (ayam, ""), "cat with dog" → (cat, dog).
    public static func parse(verb: String, arg: String) -> (find: String, replace: String)? {
        func clean(_ s: Substring) -> String {
            var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            for lead in ["the word ", "the words ", "word ", "words ", "kata ", "tulisan ", "teks "]
            where t.lowercased().hasPrefix(lead) {
                t = String(t.dropFirst(lead.count)); break
            }
            return t.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’.,!?").union(.whitespaces))
        }
        switch verb {
        case "delete", "hapus", "remove", "buang":
            let f = clean(Substring(arg))
            return f.isEmpty ? nil : (f, "")
        case "replace", "ganti", "ubah", "change":
            let seps = [" with ", " jadi ", " menjadi ", " dengan ", " to ", " ke "]
            let low = arg.lowercased()
            for sep in seps {
                if let r = low.range(of: sep) {
                    let i = arg.index(arg.startIndex, offsetBy: low.distance(from: low.startIndex, to: r.lowerBound))
                    let j = arg.index(i, offsetBy: sep.count)
                    let f = clean(arg[..<i]), t = clean(arg[j...])
                    if !f.isEmpty, !t.isEmpty { return (f, t) }
                }
            }
            return nil
        default:
            return nil
        }
    }
}
