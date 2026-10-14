import Foundation

/// Model Context Protocol over stdio (newline-delimited JSON-RPC 2.0), both
/// eras: a modern (2026-07-28) server gets `server/discover` and per-request
/// `_meta`; a legacy one (2025-11-25 and earlier) the `initialize`
/// handshake. Which one is decided once per server process, as the spec's
/// stdio backward-compatibility probe says.
public enum MCP {
    public static let modernVersion = "2026-07-28"
    public static let legacyVersion = "2025-11-25"
    static let metaVersion = "io.modelcontextprotocol/protocolVersion"
    static let metaClientInfo = "io.modelcontextprotocol/clientInfo"
    static let metaClientCaps = "io.modelcontextprotocol/clientCapabilities"
    static let metaServerInfo = "io.modelcontextprotocol/serverInfo"
    /// UnsupportedProtocolVersionError.
    static let unsupportedVersion = -32022

    public struct Tool: Sendable, Equatable {
        public var name: String
        public var description: String
        /// Argument names from the input schema, required ones first.
        public var arguments: [String]
        /// The server says the tool only reads (`annotations.readOnlyHint`).
        public var readOnly: Bool
    }

    public struct RPCError: Error, LocalizedError, Sendable {
        public var code: Int
        public var message: String
        public var data: [String: String] = [:]
        public var errorDescription: String? { "MCP error \(code): \(message)" }
    }

    /// Tool list from a `tools/list` result.
    static func tools(from result: [String: Any]) -> [Tool] {
        ((result["tools"] as? [[String: Any]]) ?? []).compactMap { t in
            guard let name = t["name"] as? String else { return nil }
            let schema = t["inputSchema"] as? [String: Any]
            let props = ((schema?["properties"] as? [String: Any]) ?? [:]).keys.sorted()
            let required = (schema?["required"] as? [String]) ?? []
            let args = required + props.filter { !required.contains($0) }
            let ann = t["annotations"] as? [String: Any]
            return Tool(name: name, description: (t["description"] as? String) ?? (t["title"] as? String) ?? "",
                        arguments: args, readOnly: (ann?["readOnlyHint"] as? Bool) == true)
        }
    }

    /// The text a `tools/call` result carries: its text parts, else the
    /// structured content as JSON. Errors come back as text too — the
    /// Reasoner reads them and decides.
    static func text(of result: [String: Any]) -> String {
        if (result["resultType"] as? String) == "input_required" {
            return "error: the tool asked for more input, which s1 can't give"
        }
        let parts = ((result["content"] as? [[String: Any]]) ?? []).compactMap { c -> String? in
            switch c["type"] as? String {
            case "text": return c["text"] as? String
            case "resource": return ((c["resource"] as? [String: Any])?["text"] as? String)
            case "image", "audio": return "[\(c["type"] as? String ?? "media")]"
            default: return nil
            }
        }
        var out = parts.joined(separator: "\n")
        if out.isEmpty, let s = result["structuredContent"],
           JSONSerialization.isValidJSONObject(["v": s]),
           let d = try? JSONSerialization.data(withJSONObject: s, options: [.sortedKeys, .fragmentsAllowed]) {
            out = String(decoding: d, as: UTF8.self)
        }
        return (result["isError"] as? Bool) == true ? "error: " + out : out
    }
}

/// One MCP server process and the JSON-RPC conversation with it.
public actor MCPStdioClient {
    public let name: String
    private let config: MCPServerConfig
    private var process: Process?
    private var stdin: FileHandle?
    private var nextID = 1
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var modern = false
    private var version = MCP.legacyVersion
    private var readerTask: Task<Void, Never>?

    public init(name: String, config: MCPServerConfig) {
        self.name = name
        self.config = config
    }

    /// Start the server and settle which protocol era it speaks.
    public func start() async throws {
        guard process == nil else { return }
        let p = Process()
        // The command as a user would type it: resolved through PATH.
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = [config.command] + (config.args ?? [])
        var env = ProcessInfo.processInfo.environment
        // GUI apps start with a bare PATH; servers are usually npx/uvx installs.
        env["PATH"] = (env["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:" + NSHomeDirectory() + "/.local/bin"
        for (k, v) in config.env ?? [:] { env[k] = v }
        p.environment = env
        let input = Pipe(), output = Pipe()
        p.standardInput = input
        p.standardOutput = output
        p.standardError = FileHandle.nullDevice
        try p.run()
        process = p
        stdin = input.fileHandleForWriting
        let reader = output.fileHandleForReading
        readerTask = Task { [weak self] in
            do {
                for try await line in reader.bytes.lines {
                    await self?.receive(line)
                }
            } catch {}
            await self?.closed()
        }
        try await settleEra()
    }

    /// The stdio probe: `server/discover` with our modern version. A result,
    /// or a modern error, means modern; anything else (or silence) legacy.
    private func settleEra() async throws {
        do {
            let r = try await request("server/discover", [:], modernMeta: true, timeout: 5)
            let supported = (r["supportedVersions"] as? [String]) ?? []
            guard supported.contains(MCP.modernVersion) else {
                throw MCP.RPCError(code: MCP.unsupportedVersion, message: "server speaks \(supported) only")
            }
            modern = true
            version = MCP.modernVersion
            return
        } catch let e as MCP.RPCError where e.code == MCP.unsupportedVersion {
            throw MCP.RPCError(code: e.code, message: "\(name) doesn't support MCP \(MCP.modernVersion) (\(e.message))")
        } catch {
            // Legacy: the handshake.
        }
        let r = try await request("initialize", [
            "protocolVersion": MCP.legacyVersion,
            "capabilities": [String: Any](),
            "clientInfo": ["name": "s1", "version": S1Info.version],
        ], modernMeta: false, timeout: 20)
        version = (r["protocolVersion"] as? String) ?? MCP.legacyVersion
        try notify("notifications/initialized")
    }

    public func listTools() async throws -> [MCP.Tool] {
        var all: [MCP.Tool] = []
        var cursor: String?
        for _ in 0 ..< 5 {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let r = try await request("tools/list", params, modernMeta: modern, timeout: 20)
            all += MCP.tools(from: r)
            cursor = r["nextCursor"] as? String
            if cursor == nil { break }
        }
        return all
    }

    public func call(_ tool: String, arguments: [String: Any]) async throws -> String {
        let r = try await request("tools/call", ["name": tool, "arguments": arguments],
                                  modernMeta: modern, timeout: 60)
        return MCP.text(of: r)
    }

    public func stop() {
        try? stdin?.close()
        let p = process
        process = nil
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p?.isRunning == true { p?.terminate() } }
        fail(MCP.RPCError(code: -1, message: "\(name) stopped"))
    }

    // MARK: - JSON-RPC

    private func request(_ method: String, _ params: [String: Any], modernMeta: Bool,
                         timeout: TimeInterval) async throws -> [String: Any] {
        var params = params
        if modernMeta {
            params["_meta"] = [
                MCP.metaVersion: MCP.modernVersion,
                MCP.metaClientInfo: ["name": "s1", "version": S1Info.version],
                MCP.metaClientCaps: [String: Any](),
            ]
        }
        let id = nextID
        nextID += 1
        let message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method, "params": params]
        let timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            await self?.expire(id, method)
        }
        defer { timer.cancel() }
        return try await withCheckedThrowingContinuation { c in
            pending[id] = c
            do { try write(message) } catch {
                pending[id] = nil
                c.resume(throwing: error)
            }
        }
    }

    private func notify(_ method: String) throws {
        try write(["jsonrpc": "2.0", "method": method])
    }

    private func write(_ message: [String: Any]) throws {
        guard let stdin, JSONSerialization.isValidJSONObject(message) else {
            throw MCP.RPCError(code: -1, message: "\(name) isn't running")
        }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try stdin.write(contentsOf: data)
    }

    private func receive(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let id = (obj["id"] as? Int) ?? (obj["id"] as? String).flatMap(Int.init),
              let c = pending.removeValue(forKey: id) else { return }   // notifications, logs
        if let e = obj["error"] as? [String: Any] {
            let data = ((e["data"] as? [String: Any]) ?? [:]).mapValues { "\($0)" }
            c.resume(throwing: MCP.RPCError(code: (e["code"] as? Int) ?? 0,
                                            message: (e["message"] as? String) ?? "error", data: data))
        } else {
            c.resume(returning: (obj["result"] as? [String: Any]) ?? [:])
        }
    }

    private func expire(_ id: Int, _ method: String) {
        pending.removeValue(forKey: id)?.resume(throwing: MCP.RPCError(code: -2, message: "\(method) timed out"))
    }

    private func closed() {
        process = nil
        fail(MCP.RPCError(code: -1, message: "\(name) exited"))
    }

    private func fail(_ error: Error) {
        let all = pending
        pending = [:]
        for c in all.values { c.resume(throwing: error) }
    }
}

/// The configured MCP servers, started on first use and kept for the
/// process: their tools for the Reasoner's prompt, and calls into them.
public actor MCPTools {
    public static let shared = MCPTools()

    private var clients: [String: MCPStdioClient] = [:]
    private var tools: [String: [MCP.Tool]] = [:]
    private var failed: [String: String] = [:]
    private var loadedFor: [String: MCPServerConfig]?

    /// Servers from config, minus disabled ones.
    public static func configured(_ cfg: S1Config = .load()) -> [String: MCPServerConfig] {
        (cfg.mcpServers ?? [:]).filter { $0.value.disabled != true }
    }

    /// Start every configured server (once) and read its tools. Bounded:
    /// a server that won't answer in time is skipped, not waited for.
    func load(_ servers: [String: MCPServerConfig] = MCPTools.configured()) async {
        if loadedFor == servers { return }
        for (_, c) in clients { await c.stop() }
        clients = [:]; tools = [:]; failed = [:]
        loadedFor = servers
        await withTaskGroup(of: (String, MCPStdioClient?, [MCP.Tool], String?).self) { group in
            for (name, cfg) in servers {
                group.addTask {
                    let client = MCPStdioClient(name: name, config: cfg)
                    do {
                        try await client.start()
                        return (name, client, try await client.listTools(), nil)
                    } catch {
                        await client.stop()
                        return (name, nil, [], error.localizedDescription)
                    }
                }
            }
            for await (name, client, list, error) in group {
                if let client { clients[name] = client; tools[name] = list }
                if let error { failed[name] = error }
            }
        }
    }

    /// The Reasoner's view of the tools, or nil with none configured.
    public func promptSection(budget: Int = 2500) async -> String? {
        let servers = Self.configured()
        guard !servers.isEmpty else { return nil }
        await load(servers)
        var lines: [String] = []
        for (server, list) in tools.sorted(by: { $0.key < $1.key }) {
            for t in list {
                let args = t.arguments.isEmpty ? "" : " (args: \(t.arguments.joined(separator: ", ")))"
                lines.append("- \(server)/\(t.name)\(t.readOnly ? " [read-only]" : ""): \(t.description.prefix(160))\(args)")
            }
        }
        guard !lines.isEmpty else { return nil }
        var out = "MCP tools you may call — reply {\"action\":{\"type\":\"mcp\",\"server\":\"<server>\",\"tool\":\"<tool>\",\"arguments\":{…}}}. "
            + "Read-only tools run at once; any other asks the user first. Prefer a tool over clicking when one does the job:\n"
        for l in lines where out.count + l.count < budget { out += l + "\n" }
        return out
    }

    /// Whether a call may run without asking: the server marks the tool
    /// read-only, or the user listed it in `autoApprove`.
    public func trusted(server: String, tool: String) async -> Bool {
        if Self.configured()[server]?.autoApprove?.contains(tool) == true { return true }
        await load()
        return tools[server]?.first { $0.name == tool }?.readOnly == true
    }

    public func call(server: String, tool: String, argumentsJSON: String) async throws -> String {
        await load()
        guard let client = clients[server] else {
            throw MCP.RPCError(code: -1, message: failed[server].map { "\(server) isn't available: \($0)" }
                               ?? "no MCP server called \(server)")
        }
        guard tools[server]?.contains(where: { $0.name == tool }) == true else {
            throw MCP.RPCError(code: -1, message: "\(server) has no tool called \(tool)")
        }
        let args = (try? JSONSerialization.jsonObject(with: Data(argumentsJSON.utf8))) as? [String: Any] ?? [:]
        return try await client.call(tool, arguments: args)
    }

    /// Servers that failed to start, for `s1 doctor` and the CLI.
    public func status() async -> (ok: [String: Int], failed: [String: String]) {
        await load()
        return (tools.mapValues(\.count), failed)
    }
}
