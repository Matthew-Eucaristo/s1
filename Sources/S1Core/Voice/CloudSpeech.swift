import AVFoundation
import Foundation

/// Optional hosted speech, OpenAI-compatible audio API (`/audio/transcriptions`,
/// `/audio/speech`): Groq Whisper, OpenAI, or any local server speaking the
/// same shape (Speaches / faster-whisper, NVIDIA NIM). Off by default — the
/// on-device Apple path stays the default and the fallback on any failure.
/// Apple still drives VAD + the live transcript; the cloud model only
/// re-transcribes the finished turn for accuracy.
public enum CloudSpeech {
    public static func sttURL(_ base: String) -> URL? {
        URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/audio/transcriptions")
    }

    public static func ttsURL(_ base: String) -> URL? {
        URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/ ")) + "/audio/speech")
    }

    /// Whisper's `prompt` biases spelling of custom words; it caps at 224
    /// tokens, so keep the list short (~150 words is safe).
    public static func prompt(vocabulary: [String]) -> String? {
        let words = vocabulary.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !words.isEmpty else { return nil }
        return words.prefix(150).joined(separator: ", ")
    }

    public static func multipart(file: Data, filename: String, fields: [(String, String)],
                                 boundary: String) -> Data {
        var d = Data()
        func add(_ s: String) { d.append(Data(s.utf8)) }
        for (k, v) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(k)\"\r\n\r\n\(v)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: audio/wav\r\n\r\n")
        d.append(file)
        add("\r\n--\(boundary)--\r\n")
        return d
    }

    private static func send(_ req: URLRequest, role: String, model: String) async throws -> Data {
        let started = Date()
        let host = req.url?.host ?? "?"
        func ms() -> Int { Int(Date().timeIntervalSince(started) * 1000) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DebugTrace.http(role: role, url: req.url!, status: code, ms: ms(), request: nil,
                            response: code == 200 && role == "tts" ? nil : data)
            guard code == 200 else {
                let snippet = String(decoding: data.prefix(200), as: UTF8.self).terminalSafe
                UsageLog.append(UsageRecord(role: role, host: host, model: model, ms: ms(), ok: false,
                                            error: UsageLog.scrub("HTTP \(code): \(snippet)")))
                throw S1Error.aborted("\(role) HTTP \(code): \(snippet)")
            }
            UsageLog.append(UsageRecord(role: role, host: host, model: model, ms: ms(), ok: true))
            return data
        } catch let e as S1Error { throw e } catch {
            UsageLog.append(UsageRecord(role: role, host: host, model: model, ms: ms(), ok: false,
                                        error: UsageLog.scrub(error.localizedDescription)))
            throw error
        }
    }

    /// Transcribe a finished WAV turn. `language` (ISO-639-1) is a hint
    /// from Apple's detection — it improves Whisper accuracy and latency.
    public static func transcribe(_ wav: URL, endpoint ep: Endpoint, language: String?,
                                  vocabulary: [String]) async throws -> String {
        guard let url = sttURL(ep.baseURL) else { throw S1Error.aborted("bad STT URL") }
        let boundary = "s1-\(UUID().uuidString)"
        var fields = [("model", ep.model), ("response_format", "json"), ("temperature", "0")]
        if let language, !language.isEmpty { fields.append(("language", language)) }
        if let p = prompt(vocabulary: vocabulary) { fields.append(("prompt", p)) }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.setValue("s1/\(S1Info.version)", forHTTPHeaderField: "User-Agent")
        if let k = ep.apiKey, !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        req.httpBody = multipart(file: try Data(contentsOf: wav), filename: "turn.wav",
                                 fields: fields, boundary: boundary)
        let data = try await send(req, role: "stt", model: ep.model)
        struct R: Decodable { var text: String }
        return try JSONDecoder().decode(R.self, from: data).text
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Synthesize speech as WAV bytes.
    public static func synthesize(_ text: String, endpoint ep: Endpoint, voice: String) async throws -> Data {
        guard let url = ttsURL(ep.baseURL) else { throw S1Error.aborted("bad TTS URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("s1/\(S1Info.version)", forHTTPHeaderField: "User-Agent")
        if let k = ep.apiKey, !k.isEmpty { req.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": ep.model, "input": text, "voice": voice, "response_format": "wav",
        ], options: [.sortedKeys])
        return try await send(req, role: "tts", model: ep.model)
    }

    /// Whether a TTS model can read `language` — Groq's Orpheus English
    /// model would mangle Indonesian; Apple's voice is better there.
    public static func ttsSpeaks(model: String, language: String) -> Bool {
        let m = model.lowercased()
        if m.contains("english") { return language.lowercased().hasPrefix("en") }
        if m.contains("arabic") { return language.lowercased().hasPrefix("ar") }
        return true
    }

    public static func defaultVoice(for ep: Endpoint) -> String {
        let host = URL(string: ep.baseURL)?.host ?? ""
        return host.contains("groq") ? "troy" : "alloy"
    }
}

public extension Endpoints {
    /// Cloud STT endpoint, nil = on-device only (the default).
    static func stt(env: [String: String] = ProcessInfo.processInfo.environment,
                    config: S1Config = .load(),
                    secret: (ModelRole) -> String? = Endpoints.keychainSecret) -> Endpoint? {
        endpoint(.stt, env: env, ep: config.stt, secret: secret)
    }

    /// Cloud TTS endpoint, nil = Apple voices (the default).
    static func tts(env: [String: String] = ProcessInfo.processInfo.environment,
                    config: S1Config = .load(),
                    secret: (ModelRole) -> String? = Endpoints.keychainSecret) -> Endpoint? {
        endpoint(.tts, env: env, ep: config.tts, secret: secret)
    }

    private static func endpoint(_ role: ModelRole, env: [String: String], ep: S1Config.ModelEndpoint?,
                                 secret: (ModelRole) -> String?) -> Endpoint? {
        let p = role.envPrefix
        guard let model = (env["\(p)_MODEL"] ?? ep?.model)?.trimmingCharacters(in: .whitespaces),
              !model.isEmpty, let base = env["\(p)_BASE"] ?? ep?.base, !base.isEmpty else { return nil }
        let key = env["\(p)_KEY"] ?? secret(role) ?? ep?.key
        if !isLocal(base), (key ?? "").isEmpty { return nil }
        return Endpoint(baseURL: base, model: model, apiKey: key)
    }
}
