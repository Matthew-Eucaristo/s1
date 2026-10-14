import AppKit
import Foundation

/// s1 as an MCP server (`s1 mcp`, stdio): other agents read the Mac's screen
/// through it and hand it goals to do. Dual-era like the client: a modern
/// (2026-07-28) request is served statelessly from its `_meta`; `initialize`
/// selects the legacy handshake.
///
/// Everything a goal does goes through s1's own loop — the safety gate, the
/// run lock, the stop file, the focus guard. A step the gate stops is never
/// approved by the calling agent: the run ends "needs you" and says so.
public final class MCPServer: Sendable {
    public static let supported = [MCP.modernVersion, MCP.legacyVersion, "2025-06-18", "2025-03-26", "2024-11-05"]

    /// What tools do, injectable so tests never touch the screen.
    public struct Handlers: Sendable {
        public var readScreen: @Sendable () async throws -> String
        public var listMenus: @Sendable () async -> String
        public var listSkills: @Sendable () -> String
        public var run: @Sendable (_ goal: String, _ dryRun: Bool) async throws -> String

        public init(readScreen: @escaping @Sendable () async throws -> String,
                    listMenus: @escaping @Sendable () async -> String,
                    listSkills: @escaping @Sendable () -> String,
                    run: @escaping @Sendable (String, Bool) async throws -> String) {
            self.readScreen = readScreen; self.listMenus = listMenus
            self.listSkills = listSkills; self.run = run
        }
    }

    let handlers: Handlers
    public init(handlers: Handlers = .live) { self.handlers = handlers }

    static let instructions = """
        s1 operates this Mac through its accessibility tree: read_screen to see what's open, \
        run_goal to do something ("open Notes and type hello"). Every step passes s1's safety \
        gate; steps that need the user (deleting, quitting, passwords, payments) are not done — \
        the result says so and the user does them in s1 directly.
        """

    static var tools: [[String: Any]] {
        [
        tool("read_screen", "The frontmost app, open windows and the frontmost window's controls (accessibility tree with refs). Reads only; password fields are never read.",
             [:], readOnly: true),
        tool("list_menus", "The frontmost app's menu bar commands (what the app itself can do), with shortcuts.",
             [:], readOnly: true),
        tool("list_skills", "The user's saved s1 skills (named routines). Run one with run_skill.",
             [:], readOnly: true),
        tool("run_goal", "Do something on this Mac in plain words, e.g. \"open Safari and go to apple.com\". Returns the status, the steps taken and any answer.",
             ["goal": ["type": "string", "description": "What to do, in plain words."],
              "dry_run": ["type": "boolean", "description": "Plan and log without touching the Mac."]],
             required: ["goal"], readOnly: false),
        tool("run_skill", "Run one of the user's saved s1 skills by name.",
             ["name": ["type": "string"]], required: ["name"], readOnly: false),
        ]
    }

    static func tool(_ name: String, _ description: String, _ props: [String: Any],
                     required: [String] = [], readOnly: Bool) -> [String: Any] {
        [
            "name": name, "description": description,
            "inputSchema": ["type": "object", "properties": props, "required": required] as [String: Any],
            "annotations": ["readOnlyHint": readOnly, "destructiveHint": !readOnly, "openWorldHint": !readOnly],
        ]
    }

    /// One message in, at most one message out (notifications get none).
    public func handle(_ line: String) async -> String? {
        guard let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
            return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
        }
        guard let method = msg["method"] as? String else { return nil }   // a response: we send no requests
        guard let id = msg["id"] else { return nil }                        // a notification
        let params = (msg["params"] as? [String: Any]) ?? [:]
        let meta = params["_meta"] as? [String: Any]
        let requested = meta?[MCP.metaVersion] as? String
        if let requested, !Self.supported.contains(requested) {
            return error(id, MCP.unsupportedVersion, "Unsupported protocol version",
                         data: ["supported": Self.supported, "requested": requested])
        }
        // Modern replies say they're complete (no further input needed).
        func ok(_ result: [String: Any]) -> String? {
            var r = result
            if requested != nil { r["resultType"] = "complete" }
            return encode(["jsonrpc": "2.0", "id": id, "result": r])
        }
        let info: [String: Any] = ["name": "s1", "version": S1Info.version]
        switch method {
        case "server/discover":
            return ok(["supportedVersions": Self.supported, "capabilities": ["tools": [String: Any]()],
                       "_meta": [MCP.metaServerInfo: info], "instructions": Self.instructions])
        case "initialize":
            let asked = params["protocolVersion"] as? String
            let version = asked.flatMap { Self.supported.dropFirst().contains($0) ? $0 : nil } ?? MCP.legacyVersion
            return ok(["protocolVersion": version, "capabilities": ["tools": [String: Any]()],
                       "serverInfo": info, "instructions": Self.instructions])
        case "ping":
            return ok([:])
        case "tools/list":
            return ok(["tools": Self.tools])
        case "tools/call":
            guard let name = params["name"] as? String else { return error(id, -32602, "missing tool name") }
            let args = (params["arguments"] as? [String: Any]) ?? [:]
            let (text, isError) = await call(name, args)
            return ok(["content": [["type": "text", "text": text]], "isError": isError])
        default:
            return error(id, -32601, "method not found: \(method)")
        }
    }

    func call(_ name: String, _ args: [String: Any]) async -> (String, Bool) {
        do {
            switch name {
            case "read_screen": return (try await handlers.readScreen(), false)
            case "list_menus": return (await handlers.listMenus(), false)
            case "list_skills": return (handlers.listSkills(), false)
            case "run_goal":
                guard let goal = (args["goal"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !goal.isEmpty else { return ("goal is empty", true) }
                return (try await handlers.run(goal, (args["dry_run"] as? Bool) ?? false), false)
            case "run_skill":
                guard let n = args["name"] as? String, let s = Skills.match(n, in: Skills.load()) else {
                    return ("no skill called “\(args["name"] as? String ?? "")” — list_skills shows them", true)
                }
                return (try await handlers.run(s.name, false), false)
            default:
                return ("no tool called \(name)", true)
            }
        } catch {
            return ("error: \(error.localizedDescription)", true)
        }
    }

    private func error(_ id: Any, _ code: Int, _ message: String, data: [String: Any]? = nil) -> String? {
        var e: [String: Any] = ["code": code, "message": message]
        if let data { e["data"] = data }
        return encode(["jsonrpc": "2.0", "id": id, "error": e])
    }

    private func encode(_ obj: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(obj),
              let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes])
        else { return nil }
        return String(decoding: d, as: UTF8.self)
    }
}

extension MCPServer.Handlers {
    /// The real Mac: s1's perceiver, menus, skills and runner.
    public static let live = MCPServer.Handlers(
        readScreen: {
            let obs = try await SystemPerceiver().observe(wantScreenshot: false)
            return LLMDecisionCodec.observationText(obs)
        },
        listMenus: {
            let menus = await MainActor.run { () -> [MenuCommand] in
                guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier else { return [] }
                return MenuReader.commands(pid: pid)
            }
            let enabled = menus.filter(\.enabled)
            return enabled.isEmpty ? "no menu commands" : enabled.map(\.label).joined(separator: "\n")
        },
        listSkills: {
            let all = Skills.load()
            return all.isEmpty ? "no skills saved" : all.map { s in
                "\(s.name): " + s.steps.joined(separator: " → ")
            }.joined(separator: "\n")
        },
        run: { goal, dryRun in
            // No confirm handler: the calling agent can't approve a gated
            // step on the user's behalf — those end the run "needs you".
            let (report, logger) = try await S1Runner.run(
                goal: goal, policy: Brain.policy(), artifacts: S1Home.path + "/artifacts",
                maxSteps: 25, threshold: 0.6, dryRun: dryRun, allowIrreversible: false,
                killSwitch: NSTemporaryDirectory() + "s1-stop", clearStaleStop: true,
                s2: Brain.reasoner())
            let steps = ((try? RunReader.steps(in: logger.runDir)) ?? []).suffix(12).map(\.digest)
            var out = "status: \(report.status.rawValue)"
            if let a = report.answer { out += "\nanswer: \(a)" }
            if report.status == .needsHuman {
                out += "\nA step needs the user's own approval; ask them to do it in s1 (or by hand)."
            }
            return out + "\nsteps:\n" + steps.joined(separator: "\n")
        })
}
