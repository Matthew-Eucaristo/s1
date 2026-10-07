import Foundation

/// Hands-free dictation: "start dictating" turns the listener into a
/// dictation mic — every utterance is typed into the focused field (no
/// Reasoner, no commands) until "stop dictating", a stop phrase, ⇧⇧ or Esc.
public enum Dictation {
    public enum Command: Sendable, Equatable { case start, stop }

    static let startPhrases: Set<String> = [
        "type what i say", "type everything i say", "just type what i say",
        "ketik apa yang aku bilang", "ketik yang aku bilang", "ketik apa yang saya bilang",
        "ketik semua yang aku bilang",
    ]
    private static let word = #"(?:dictat(?:e|ing|ion)|dikte|mendikte)"#
    private static let tail = #"(?:\s+(?:mode|on|this|that|for me|now|please|ya|dong|sekarang|ini))*"#
    private static let startRegex = #"^(?:(?:let'?s|i want to|i'?d like to|start|begin|turn on|mulai|aku mau|saya mau)\s+)*"#
        + word + tail + "$"
    private static let stopRegex = #"^(?:stop|end|finish|turn off|done|i'?m done|selesai|berhenti|udah|sudah|matikan)\s+"#
        + word + #"(?:\s+(?:mode|now|please|ya|dong|sekarang))*$|^"# + word + #"\s+off$"#

    /// The whole utterance is a dictation switch (fillers allowed:
    /// "okay, please dictate this", "start dictating", "selesai dikte").
    public static func command(_ text: String) -> Command? {
        let t = AXPolicy.stripFillers(text).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if startPhrases.contains(t) || t.range(of: startRegex, options: .regularExpression) != nil { return .start }
        if t.range(of: stopRegex, options: .regularExpression) != nil { return .stop }
        return nil
    }

    /// The text to type for one utterance: chunks after the first are
    /// separated by a space, as if one person kept talking.
    public static func chunk(_ text: String, first: Bool) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return first || t.isEmpty ? t : " " + t
    }
}
