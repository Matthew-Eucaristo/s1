import Foundation

/// Semantic end-of-turn: silence alone cuts people off mid-thought ("open
/// my…", "buka yang…"). When the words so far end on something a sentence
/// can't end on, the listener waits a little longer for the rest.
public enum TurnEnd {
    /// Words a spoken command doesn't end on: articles, possessives,
    /// prepositions, conjunctions, bare verbs, hesitations (EN + ID).
    static let dangling: Set<String> = [
        "the", "a", "an", "my", "your", "this", "that", "to", "of", "for", "with", "in", "on",
        "at", "from", "and", "or", "but", "then", "so", "open", "close", "type", "press", "click",
        "can", "could", "would", "please", "uh", "um", "uhm", "erm", "eh", "ehm", "hmm", "like",
        "yang", "dan", "atau", "ke", "di", "dari", "untuk", "dengan", "buka", "tutup", "ketik",
        "klik", "tekan", "tolong", "terus", "lalu", "jadi", "nah", "anu", "itu", "si",
    ]

    /// Extra wait after silence when the sentence looks unfinished.
    public static let extraWait: TimeInterval = 1.3

    public static func looksUnfinished(_ text: String) -> Bool {
        let words = text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
        guard let last = words.last else { return false }
        return dangling.contains(String(last))
    }
}
