import Foundation

/// Hands-free dictation: "start dictating" turns the listener into a
/// dictation mic — every utterance is typed into the focused field (no
/// Reasoner, no commands) until "stop dictating", a stop phrase, ⇧⇧ or Esc.
public enum Dictation {
    public enum Command: Sendable, Equatable { case start, stop }

    static let startPhrases: Set<String> = [
        "start dictating", "start dictation", "dictation mode", "dictation on", "dictate",
        "type what i say", "type everything i say", "just type what i say",
        "dikte", "mulai dikte", "mode dikte", "ketik apa yang aku bilang",
        "ketik yang aku bilang", "ketik apa yang saya bilang", "ketik semua yang aku bilang",
    ]
    static let stopPhrases: Set<String> = [
        "stop dictating", "stop dictation", "end dictation", "dictation off", "done dictating",
        "selesai dikte", "berhenti dikte", "stop dikte", "udah dikte", "sudah dikte",
    ]

    /// The whole utterance is a dictation switch (fillers allowed:
    /// "okay, start dictating please").
    public static func command(_ text: String) -> Command? {
        let t = AXPolicy.stripFillers(text).lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        if startPhrases.contains(t) { return .start }
        if stopPhrases.contains(t) { return .stop }
        return nil
    }

    /// The text to type for one utterance: chunks after the first are
    /// separated by a space, as if one person kept talking.
    public static func chunk(_ text: String, first: Bool) -> String {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return first || t.isEmpty ? t : " " + t
    }
}
