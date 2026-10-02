import Foundation

/// A chat-completions endpoint. One protocol shape covers Ollama, LM Studio,
/// mlx_vlm.server, vLLM, OpenRouter, OpenAI — anything OpenAI-compatible.
public struct Endpoint: Sendable {
    public var baseURL: String          // e.g. http://localhost:11434/v1
    public var model: String
    public var apiKey: String?          // nil for local servers
    public var extraHeaders: [String: String]
    /// Ollama KV context — decision prompts are small; 16k+ wastes memory/latency.
    public var numCtx: Int

    public init(baseURL: String, model: String, apiKey: String? = nil,
                extraHeaders: [String: String] = [:], numCtx: Int = 8192) {
        self.baseURL = baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        self.model = model
        self.apiKey = apiKey
        self.extraHeaders = extraHeaders
        self.numCtx = numCtx
    }

    /// Built-in presets; env vars override (`S1_S2_BASE`, `S1_S2_MODEL`, `S1_S2_KEY`, `S1_NUM_CTX`).
    public static func s2Default(env: [String: String] = ProcessInfo.processInfo.environment) -> Endpoint {
        Endpoint(
            baseURL: env["S1_S2_BASE"] ?? "http://localhost:11434/v1",
            model: env["S1_S2_MODEL"] ?? "gemma3:4b",
            apiKey: env["S1_S2_KEY"],
            numCtx: env["S1_NUM_CTX"].flatMap(Int.init) ?? 8192)
    }
}

public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String
    /// Base64 PNG for vision-capable models (VLMPolicy).
    public var imageBase64: String?

    public init(role: String, content: String, imageBase64: String? = nil) {
        self.role = role; self.content = content; self.imageBase64 = imageBase64
    }
}

/// Minimal OpenAI-compatible chat client — no SDK dependency, ~80 lines.
public struct ChatClient: Sendable {
    public var endpoint: Endpoint
    public init(endpoint: Endpoint) { self.endpoint = endpoint }

    /// Send chat messages; returns the assistant text. When `imageBase64` is
    /// set on a message it is sent as an OpenAI vision `image_url` part.
    public func chat(_ messages: [ChatMessage], maxTokens: Int = 1024,
                     temperature: Double = 0.0) async throws -> String {
        let url = URL(string: "\(endpoint.baseURL)/chat/completions")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300   // local models on CPU can be slow
        if let key = endpoint.apiKey { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        for (k, v) in endpoint.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let wire: [[String: Any]] = messages.map { m in
            if let img = m.imageBase64 {
                return ["role": m.role, "content": [
                    ["type": "text", "text": m.content],
                    ["type": "image_url", "image_url": ["url": "data:image/png;base64,\(img)"]],
                ]]
            }
            return ["role": m.role, "content": m.content]
        }
        let body: [String: Any] = [
            "model": endpoint.model,
            "messages": wire,
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": false,
            "think": false,   // Ollama: skip reasoning traces for fast S1/S2 decisions; ignored elsewhere
            "options": ["num_ctx": endpoint.numCtx, "num_predict": maxTokens],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, resp) = try await Self.session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw S1Error.aborted("no http response") }
        guard http.statusCode == 200 else {
            throw S1Error.aborted("LLM \(http.statusCode): \(String(decoding: data.prefix(300), as: UTF8.self))")
        }
        struct R: Decodable { struct C: Decodable { struct M: Decodable { let content: String }; let message: M }; let choices: [C] }
        let r = try JSONDecoder().decode(R.self, from: data)
        return r.choices.first?.message.content ?? ""
    }

    /// One session for the process — keeps TCP/TLS connections warm across
    /// per-step calls instead of paying connect+handshake every decision.
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 300    // local models on CPU can be slow
        config.timeoutIntervalForResource = 600
        config.httpMaximumConnectionsPerHost = 2
        return URLSession(configuration: config)
    }()
}
