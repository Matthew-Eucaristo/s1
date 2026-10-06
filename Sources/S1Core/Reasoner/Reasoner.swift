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

    /// A local server tolerates Ollama-only request keys (`think`,
    /// `options`) — a strict OpenAI-spec endpoint (OpenAI, OpenRouter, Groq)
    /// 400s on unknown fields, so the wire body keeps them local-only.
    /// Match the HOST, not the URL text: "api.x.com/?next=localhost" or
    /// "mylocalhost.evil.com" are remote servers, not loopback.
    /// A hosted endpoint with no API key can't answer — callers treat the
    /// role as unconfigured instead of failing every request with a 401.
    public var needsKey: Bool { !isLocal && (apiKey ?? "").isEmpty }

    public var isLocal: Bool {
        guard let host = URLComponents(string: baseURL)?.host?.lowercased(),
              !host.isEmpty else {
            // Unparseable base → substring heuristic, same as before.
            let b = baseURL.lowercased()
            return b.contains("localhost") || b.contains("127.0.0.1")
                || b.contains("[::1]")
        }
        let h = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return h == "localhost" || h == "127.0.0.1" || h == "::1"
            || h.hasSuffix(".local") || h.hasSuffix(".localhost")
    }
}

public struct ChatMessage: Codable, Sendable {
    public var role: String
    public var content: String
    /// Base64 JPEG for models that read images (judge, reasoner).
    public var imageBase64: String?

    public init(role: String, content: String, imageBase64: String? = nil) {
        self.role = role; self.content = content; self.imageBase64 = imageBase64
    }
}

/// Minimal OpenAI-compatible chat client — no SDK dependency, ~80 lines.
public struct ChatClient: Sendable {
    public var endpoint: Endpoint
    /// Who is calling — tags usage records with the role (`reasoner`, …).
    public var role: String
    public init(endpoint: Endpoint, role: String = "chat") {
        self.endpoint = endpoint
        self.role = role
    }

    /// DeepSeek V4 models think by default; a decision engine wants the
    /// fast non-thinking path (official `thinking` toggle, OpenAI format).
    static func providerExtras(model: String) -> [String: Any] {
        model.lowercased().contains("deepseek") ? ["thinking": ["type": "disabled"]] : [:]
    }

    static func requestBody(endpoint: Endpoint, messages: [ChatMessage], maxTokens: Int,
                            temperature: Double, extras: Bool = true,
                            tools: [[String: Any]] = []) -> [String: Any] {
        // Messages go out in order: stable system prompt first, volatile
        // screen/state last — the prefix providers cache automatically.
        let wire: [[String: Any]] = messages.map { m in
            if let img = m.imageBase64 {
                return ["role": m.role, "content": [
                    ["type": "text", "text": m.content],
                    ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img)"]],
                ]]
            }
            return ["role": m.role, "content": m.content]
        }
        var body: [String: Any] = [
            "model": endpoint.model,
            "messages": wire,
            "temperature": temperature,
            "stream": false,
        ]
        if !tools.isEmpty { body["tools"] = tools }
        if endpoint.isLocal {
            // Ollama knobs: skip reasoning traces for fast decisions and
            // pin the KV window — strict remote specs reject these keys.
            body["think"] = false
            body["options"] = ["num_ctx": endpoint.numCtx, "num_predict": maxTokens]
            body["max_tokens"] = maxTokens
            // Ollama evicts a model after ~5min idle; a voice agent then
            // re-pays the full GB load on every other turn. Hold it warm.
            body["keep_alive"] = "30m"
        } else {
            // Strict OpenAI spec: reasoning models only take the newer key,
            // chat models accept it too — the safe remote cap.
            body["max_completion_tokens"] = maxTokens
            if extras { body.merge(providerExtras(model: endpoint.model)) { a, _ in a } }
        }
        return body
    }

    /// Assistant text plus usage from a chat-completions reply. Falls back
    /// to `reasoning_content` when a thinking model spent its turn there.
    static func parse(_ data: Data) throws -> (text: String, served: String?, counts: TokenCounts) {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw S1Error.aborted("LLM reply not JSON")
        }
        let msg = ((obj["choices"] as? [[String: Any]])?.first?["message"]) as? [String: Any]
        var text = msg?["content"] as? String ?? ""
        if text.isEmpty, let r = msg?["reasoning_content"] as? String { text = r }
        // Web search citations (OpenRouter `url_citation`): keep the sources.
        let urls = ((msg?["annotations"] as? [[String: Any]]) ?? []).compactMap {
            ($0["url_citation"] as? [String: Any])?["url"] as? String
        }
        var seen = Set<String>()
        let sources = urls.filter { seen.insert($0).inserted }.prefix(5)
        if !sources.isEmpty, !sources.allSatisfy({ text.contains($0) }) {
            text += "\nSources: " + sources.joined(separator: " · ")
        }
        return (text, obj["model"] as? String, UsageLog.counts(fromUsage: obj["usage"] as? [String: Any]))
    }

    /// Send chat messages; returns the assistant text. When `imageBase64` is
    /// set on a message it is sent as an OpenAI vision `image_url` part.
    /// Every call is metered to the usage log (numbers only, no content).
    public func chat(_ messages: [ChatMessage], maxTokens: Int = 1024,
                     temperature: Double = 0.0, tools: [[String: Any]] = []) async throws -> String {
        guard let url = URL(string: "\(endpoint.baseURL)/chat/completions") else {
            throw S1Error.aborted("invalid endpoint base URL '\(endpoint.baseURL)' — check config")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300   // local models on CPU can be slow
        for (k, v) in Self.headers(for: endpoint) { req.setValue(v, forHTTPHeaderField: k) }
        if let key = endpoint.apiKey, !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in endpoint.extraHeaders { req.setValue(v, forHTTPHeaderField: k) }

        let started = Date()
        let host = URL(string: endpoint.baseURL)?.host ?? endpoint.baseURL
        func record(ok: Bool, served: String? = nil, counts: TokenCounts = TokenCounts(), error: String? = nil) {
            UsageLog.append(UsageRecord(role: role, host: host, model: endpoint.model, served: served,
                input: counts.input, output: counts.output, cached: counts.cached,
                cacheMiss: counts.cacheMiss, reasoning: counts.reasoning,
                ms: Int(Date().timeIntervalSince(started) * 1000), ok: ok,
                error: error.map(UsageLog.scrub)))
        }
        let withExtras = !endpoint.isLocal && !Self.providerExtras(model: endpoint.model).isEmpty
        var attempt = 0
        while true {
            let body = Self.requestBody(endpoint: endpoint, messages: messages, maxTokens: maxTokens,
                                        temperature: temperature, extras: attempt == 0, tools: tools)
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let data: Data, resp: URLResponse
            let sent = Date()
            do { (data, resp) = try await Self.session.data(for: req) }
            catch {
                DebugTrace.http(role: role, url: url, status: 0, ms: Int(Date().timeIntervalSince(sent) * 1000),
                                request: req.httpBody, response: nil, error: error.localizedDescription)
                record(ok: false, error: error.localizedDescription); throw error
            }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            DebugTrace.http(role: role, url: url, status: code, ms: Int(Date().timeIntervalSince(sent) * 1000),
                            request: req.httpBody, response: data)
            // A gateway that rejects the provider toggle gets one plain retry.
            if code == 400, withExtras, attempt == 0 { attempt += 1; continue }
            guard code == 200 else {
                let snippet = String(decoding: data.prefix(300), as: UTF8.self)
                record(ok: false, error: "HTTP \(code): \(snippet)")
                throw S1Error.aborted("LLM \(code): \(snippet)")
            }
            let r = try Self.parse(data)
            record(ok: true, served: r.served, counts: r.counts)
            return r.text
        }
    }

    /// Non-secret headers. OpenCode Go rejects requests without a stable
    /// per-conversation `x-opencode-session` (400 MissingSessionID) and asks
    /// clients to identify themselves — same id → same cache-warm backend.
    public static func headers(for endpoint: Endpoint,
                               session: String = Conversation.shared.sessionID()) -> [String: String] {
        var h = ["Content-Type": "application/json", "User-Agent": "s1/\(S1Info.version)"]
        if !endpoint.isLocal { h["x-opencode-session"] = session; h["x-session-id"] = session }
        return h
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


/// Web search, the cheapest correct way for the Reasoner in use:
/// - a model that searches by itself (Groq Compound, OpenAI `-search` models,
///   OpenRouter `:online`, Perplexity Sonar) is simply asked;
/// - OpenAI models use OpenAI's built-in `web_search` tool (Responses API);
/// - any OpenRouter model uses the `openrouter:web_search` server tool;
/// - everything else has no web access, and the Reasoner is told so.
/// OpenAI and OpenRouter bill searches; `webSearch: false` turns them off.
public enum WebSearch {
    public enum Kind: Equatable, Sendable { case none, native, openAI, openRouter }

    public static func kind(_ e: Endpoint) -> Kind {
        let host = URL(string: e.baseURL)?.host ?? ""
        let m = e.model.lowercased()
        if m.contains("compound") || m.contains("-search") || m.hasSuffix(":online") || m.contains("sonar") {
            return .native
        }
        if host.hasSuffix("openrouter.ai") { return .openRouter }
        if host == "api.openai.com" { return .openAI }
        return .none
    }

    /// The switch: Settings → Models, `webSearch` in config, `S1_WEB=off`.
    public static func enabled(_ cfg: S1Config = .load(),
                               env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        if let e = env["S1_WEB"]?.lowercased() { return !["0", "off", "false", "no"].contains(e) }
        return cfg.webSearch != false
    }

    public static func available(_ e: Endpoint) -> Bool { kind(e) != .none && enabled() }

    static let instructions = "Search the web and answer in at most 5 short sentences with the key facts and dates. Keep the source links."

    /// A short answer with sources, sized to fit back into the Reasoner's history.
    public static func run(_ query: String, endpoint: Endpoint) async throws -> String {
        let client = ChatClient(endpoint: endpoint, role: "search")
        let messages = [ChatMessage(role: "system", content: instructions),
                        ChatMessage(role: "user", content: query)]
        let text: String
        switch kind(endpoint) {
        case .none: throw S1Error.aborted("web search isn't available with this Reasoner")
        case .native: text = try await client.chat(messages, maxTokens: 700)
        case .openRouter: text = try await client.chat(messages, maxTokens: 700,
                                                       tools: [["type": "openrouter:web_search"]])
        case .openAI: text = try await openAIResponses(query, endpoint: endpoint)
        }
        return String(text.prefix(1800))
    }

    /// OpenAI's Responses API with the hosted `web_search` tool.
    static func openAIResponses(_ query: String, endpoint: Endpoint) async throws -> String {
        guard let url = URL(string: "\(endpoint.baseURL)/responses") else { throw S1Error.aborted("bad OpenAI URL") }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 90
        for (k, v) in ChatClient.headers(for: endpoint) { req.setValue(v, forHTTPHeaderField: k) }
        if let key = endpoint.apiKey, !key.isEmpty { req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization") }
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": endpoint.model, "instructions": instructions, "input": query,
            "tools": [["type": "web_search"]], "max_output_tokens": 900,
        ] as [String: Any])
        let (data, resp) = try await ChatClient.session.data(for: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw S1Error.aborted("web search HTTP \(code): \(String(decoding: data.prefix(200), as: UTF8.self))")
        }
        return try parseResponses(data)
    }

    /// Text plus cited URLs from a Responses API reply.
    static func parseResponses(_ data: Data) throws -> String {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = obj["output"] as? [[String: Any]] else { throw S1Error.aborted("web search reply not understood") }
        var text = "", urls: [String] = []
        for item in output where item["type"] as? String == "message" {
            for part in item["content"] as? [[String: Any]] ?? [] {
                text += part["text"] as? String ?? ""
                urls += (part["annotations"] as? [[String: Any]] ?? []).compactMap { $0["url"] as? String }
            }
        }
        var seen = Set<String>()
        let sources = urls.filter { seen.insert($0).inserted }.prefix(5)
        if !sources.isEmpty, !sources.allSatisfy({ text.contains($0) }) {
            text += "\nSources: " + sources.joined(separator: " · ")
        }
        guard !text.isEmpty else { throw S1Error.aborted("web search returned nothing") }
        return text
    }
}
