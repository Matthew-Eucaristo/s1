import Foundation

/// Append-only JSON-lines files that can't grow forever: past `maxBytes`
/// the oldest half is dropped (cut at a line boundary). Private (0600).
enum JSONL {
    static func append(_ line: Data, to url: URL, maxBytes: Int) {
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let h = try? FileHandle(forWritingTo: url) else { return }
        defer { try? h.close() }
        guard let end = try? h.seekToEnd() else { return }
        if end > UInt64(maxBytes), let data = try? Data(contentsOf: url) {
            let keep = data.suffix(maxBytes / 2)
            let start = keep.firstIndex(of: 0x0A).map { keep.index(after: $0) } ?? keep.startIndex
            try? h.truncate(atOffset: 0)
            try? h.write(contentsOf: keep[start...])
        }
        try? h.write(contentsOf: line)
    }
}
