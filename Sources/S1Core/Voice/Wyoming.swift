import Foundation
import Network

/// The Wyoming protocol (Open Home Foundation): the open, local voice
/// protocol Home Assistant's Assist uses — Whisper, Piper and friends on
/// this Mac or the LAN. Plain TCP: one JSON header line per event, then
/// optional extra data (`data_length` bytes of JSON) and an optional
/// payload (`payload_length` bytes, PCM audio).
///
/// s1 uses it as a speech provider: a transcription or voice model whose
/// address is `tcp://host:port` speaks Wyoming instead of the OpenAI-style
/// audio API (see `CloudSpeech`).
public enum Wyoming {
    public struct Event: Sendable, Equatable {
        public var type: String
        public var data: [String: JSONValue]
        public var payload: Data

        public init(_ type: String, _ data: [String: JSONValue] = [:], payload: Data = Data()) {
            self.type = type; self.data = data; self.payload = payload
        }

        /// Header line (data inline) followed by the payload.
        public func encoded() -> Data {
            var header: [String: Any] = ["type": type]
            if !data.isEmpty { header["data"] = data.mapValues(\.any) }
            if !payload.isEmpty { header["payload_length"] = payload.count }
            var out = (try? JSONSerialization.data(withJSONObject: header, options: [.sortedKeys])) ?? Data()
            out.append(0x0A)
            out.append(payload)
            return out
        }
    }

    /// A small JSON value — Wyoming event data is flat and simple.
    public enum JSONValue: Sendable, Equatable {
        case string(String), int(Int), double(Double), bool(Bool), object([String: JSONValue]),
             array([JSONValue]), null

        init(_ any: Any) {
            switch any {
            case let s as String: self = .string(s)
            case let b as Bool where type(of: any) == type(of: true): self = .bool(b)
            case let n as NSNumber:
                self = CFNumberIsFloatType(n) ? .double(n.doubleValue) : .int(n.intValue)
            case let o as [String: Any]: self = .object(o.mapValues(JSONValue.init))
            case let a as [Any]: self = .array(a.map(JSONValue.init))
            default: self = .null
            }
        }

        var any: Any {
            switch self {
            case .string(let s): s
            case .int(let i): i
            case .double(let d): d
            case .bool(let b): b
            case .object(let o): o.mapValues(\.any)
            case .array(let a): a.map(\.any)
            case .null: NSNull()
            }
        }

        public var string: String? { if case .string(let s) = self { return s }; return nil }
        public var int: Int? {
            switch self { case .int(let i): i; case .double(let d): Int(d); default: nil }
        }
    }

    /// Decode one event from the front of `buffer`; nil = need more bytes.
    /// Returns the event and how many bytes it used.
    static func decode(_ buffer: Data) throws -> (Event, Int)? {
        guard let nl = buffer.firstIndex(of: 0x0A) else { return nil }
        let headerEnd = nl - buffer.startIndex
        guard let header = try JSONSerialization.jsonObject(with: buffer.prefix(headerEnd)) as? [String: Any],
              let type = header["type"] as? String else { throw S1Error.aborted("bad Wyoming header") }
        var data = ((header["data"] as? [String: Any]) ?? [:]).mapValues(JSONValue.init)
        let dataLength = (header["data_length"] as? Int) ?? 0
        let payloadLength = (header["payload_length"] as? Int) ?? 0
        let total = headerEnd + 1 + dataLength + payloadLength
        guard buffer.count >= total else { return nil }
        let start = buffer.startIndex + headerEnd + 1
        if dataLength > 0,
           let extra = try JSONSerialization.jsonObject(with: buffer[start ..< start + dataLength]) as? [String: Any] {
            for (k, v) in extra { data[k] = JSONValue(v) }   // extra data wins over the header's
        }
        let payload = Data(buffer[(start + dataLength) ..< (start + dataLength + payloadLength)])
        return (Event(type, data, payload: payload), total)
    }

    // MARK: - WAV

    struct PCM: Equatable {
        var rate: Int, width: Int, channels: Int, samples: Data
    }

    /// The PCM inside a WAV file (RIFF, format 1).
    static func pcm(fromWAV d: Data) throws -> PCM {
        func u32(_ o: Int) -> Int { Int(d.subdata(in: o ..< o + 4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }) }
        func u16(_ o: Int) -> Int { Int(d.subdata(in: o ..< o + 2).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian }) }
        guard d.count >= 12, d.prefix(4) == Data("RIFF".utf8), d.subdata(in: 8 ..< 12) == Data("WAVE".utf8) else {
            throw S1Error.aborted("not a WAV file")
        }
        var o = 12, fmt: (rate: Int, width: Int, channels: Int)?
        while o + 8 <= d.count {
            let id = String(decoding: d.subdata(in: o ..< o + 4), as: UTF8.self), size = u32(o + 4)
            let body = o + 8
            guard body + size <= d.count else { break }
            if id == "fmt " { fmt = (u32(body + 4), u16(body + 14) / 8, u16(body + 2)) }
            if id == "data", let f = fmt {
                return PCM(rate: f.rate, width: f.width, channels: f.channels, samples: d.subdata(in: body ..< body + size))
            }
            o = body + size + (size & 1)
        }
        throw S1Error.aborted("WAV has no PCM data")
    }

    static func wav(_ p: PCM) -> Data {
        var d = Data()
        func put32(_ v: Int) { withUnsafeBytes(of: UInt32(v).littleEndian) { d.append(contentsOf: $0) } }
        func put16(_ v: Int) { withUnsafeBytes(of: UInt16(v).littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: "RIFF".utf8); put32(36 + p.samples.count); d.append(contentsOf: "WAVE".utf8)
        d.append(contentsOf: "fmt ".utf8); put32(16); put16(1); put16(p.channels); put32(p.rate)
        put32(p.rate * p.channels * p.width); put16(p.channels * p.width); put16(p.width * 8)
        d.append(contentsOf: "data".utf8); put32(p.samples.count); d.append(p.samples)
        return d
    }

    // MARK: - services

    /// `tcp://host:port` → (host, port).
    public static func address(_ base: String) -> (host: String, port: UInt16)? {
        guard let u = URL(string: base), u.scheme == "tcp", let h = u.host, let p = u.port,
              let port = UInt16(exactly: p) else { return nil }
        return (h, port)
    }

    /// Speech to text: the finished turn's audio → its transcript.
    public static func transcribe(_ wavFile: URL, base: String, language: String?, model: String?,
                                  timeout: TimeInterval = 30) async throws -> String {
        guard let addr = address(base) else { throw S1Error.aborted("bad Wyoming address \(base)") }
        let audio = try pcm(fromWAV: Data(contentsOf: wavFile))
        let fmt: [String: JSONValue] = ["rate": .int(audio.rate), "width": .int(audio.width), "channels": .int(audio.channels)]
        var asr: [String: JSONValue] = [:]
        if let language, !language.isEmpty { asr["language"] = .string(language) }
        if let model, !model.isEmpty, model != "default" { asr["name"] = .string(model) }
        var events = [Event("transcribe", asr), Event("audio-start", fmt)]
        let chunk = audio.rate * audio.width * audio.channels / 10   // 100 ms
        var at = audio.samples.startIndex
        while at < audio.samples.endIndex {
            let end = min(at + max(chunk, 1024), audio.samples.endIndex)
            events.append(Event("audio-chunk", fmt, payload: Data(audio.samples[at ..< end])))
            at = end
        }
        events.append(Event("audio-stop"))
        let conn = try await Connection.open(addr.host, addr.port, timeout: timeout)
        defer { conn.close() }
        try await conn.send(events.reduce(into: Data()) { $0.append($1.encoded()) })
        while true {
            let e = try await conn.next(timeout: timeout)
            if e.type == "transcript" { return e.data["text"]?.string ?? "" }
            if e.type == "error" { throw S1Error.aborted("Wyoming: \(e.data["text"]?.string ?? "error")") }
        }
    }

    /// Text to speech: the reply → a WAV for AVAudioPlayer.
    public static func synthesize(_ text: String, base: String, voice: String?,
                                  timeout: TimeInterval = 30) async throws -> Data {
        guard let addr = address(base) else { throw S1Error.aborted("bad Wyoming address \(base)") }
        var data: [String: JSONValue] = ["text": .string(text)]
        if let voice, !voice.isEmpty, voice != "default" { data["voice"] = .object(["name": .string(voice)]) }
        let conn = try await Connection.open(addr.host, addr.port, timeout: timeout)
        defer { conn.close() }
        try await conn.send(Event("synthesize", data).encoded())
        var pcm = PCM(rate: 22050, width: 2, channels: 1, samples: Data())
        while true {
            let e = try await conn.next(timeout: timeout)
            switch e.type {
            case "audio-start", "audio-chunk":
                if let r = e.data["rate"]?.int { pcm.rate = r }
                if let w = e.data["width"]?.int { pcm.width = w }
                if let c = e.data["channels"]?.int { pcm.channels = c }
                pcm.samples.append(e.payload)
            case "audio-stop":
                guard !pcm.samples.isEmpty else { throw S1Error.aborted("Wyoming returned no audio") }
                return wav(pcm)
            case "error":
                throw S1Error.aborted("Wyoming: \(e.data["text"]?.string ?? "error")")
            default: continue
            }
        }
    }

    /// `describe` → the server's `info`: proves it's a Wyoming server and
    /// names what it offers ("asr: faster-whisper", "tts: piper").
    public static func describe(base: String, timeout: TimeInterval = 5) async throws -> String {
        guard let addr = address(base) else { throw S1Error.aborted("bad Wyoming address \(base)") }
        let conn = try await Connection.open(addr.host, addr.port, timeout: timeout)
        defer { conn.close() }
        try await conn.send(Event("describe").encoded())
        while true {
            let e = try await conn.next(timeout: timeout)
            guard e.type == "info" else { continue }
            // Each service kind lists its programs; name the ones offered.
            let services = ["asr", "tts", "wake", "intent", "handle"].compactMap { kind -> String? in
                guard case .array(let programs)? = e.data[kind], !programs.isEmpty else { return nil }
                let names = programs.compactMap { p -> String? in
                    if case .object(let o) = p { return o["name"]?.string }; return nil
                }
                return names.isEmpty ? kind : "\(kind) \(names.joined(separator: "/"))"
            }
            return services.isEmpty ? "Wyoming server" : "Wyoming: " + services.joined(separator: ", ")
        }
    }

    // MARK: - connection

    /// One TCP connection with a read buffer, for request/response events.
    final class Connection: @unchecked Sendable {
        private let conn: NWConnection
        private var buffer = Data()

        private init(_ c: NWConnection) { conn = c }

        static func open(_ host: String, _ port: UInt16, timeout: TimeInterval) async throws -> Connection {
            let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
            let done = AtomicFlag()
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                c.stateUpdateHandler = { state in
                    switch state {
                    case .ready: if done.claim() { k.resume() }
                    case .failed(let e): if done.claim() { k.resume(throwing: e) }
                    case .cancelled: if done.claim() { k.resume(throwing: S1Error.aborted("Wyoming connection closed")) }
                    default: break
                    }
                }
                c.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if done.claim() { c.cancel(); k.resume(throwing: S1Error.aborted("can't reach Wyoming at \(host):\(port)")) }
                }
            }
            return Connection(c)
        }

        func send(_ data: Data) async throws {
            try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
                conn.send(content: data, completion: .contentProcessed { e in
                    if let e { k.resume(throwing: e) } else { k.resume() }
                })
            }
        }

        /// The next whole event, reading more bytes as needed.
        func next(timeout: TimeInterval) async throws -> Event {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                if let (e, used) = try Wyoming.decode(buffer) {
                    buffer.removeFirst(used)
                    return e
                }
                guard Date() < deadline else { throw S1Error.aborted("Wyoming server didn't answer") }
                let more = try await receive(timeout: deadline.timeIntervalSinceNow)
                guard !more.isEmpty else { throw S1Error.aborted("Wyoming server closed the connection") }
                buffer.append(more)
            }
        }

        private func receive(timeout: TimeInterval) async throws -> Data {
            let done = AtomicFlag()
            return try await withCheckedThrowingContinuation { (k: CheckedContinuation<Data, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { data, _, complete, error in
                    guard done.claim() else { return }
                    if let error { k.resume(throwing: error) }
                    else { k.resume(returning: data ?? (complete ? Data() : Data())) }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + max(timeout, 0.1)) {
                    if done.claim() { k.resume(throwing: S1Error.aborted("Wyoming server didn't answer")) }
                }
            }
        }

        func close() { conn.cancel() }
    }
}
