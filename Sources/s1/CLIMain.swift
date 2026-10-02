import Foundation

/// Portable CLI logic. The executable target (`Sources/s1cli/main.swift`) is
/// a three-line wrapper around `CLIMain.run`, which keeps the whole CLI
/// testable off-macOS.
///
///     s1-cli preflight [--request]
///     s1-cli dry-run [--steps N] [--run-dir DIR] [--allow-destructive] [--policy NAME]
///     s1-cli run --policy dummy --steps N [--run-dir DIR] [--allow-destructive]
public enum CLIMain {
    public static let usage = """
    usage:
      s1-cli preflight [--request]
      s1-cli dry-run [--steps N] [--run-dir DIR] [--allow-destructive] [--policy NAME]
      s1-cli run --policy dummy --steps N [--run-dir DIR] [--allow-destructive]
    """

    public struct Options: Equatable {
        public var command: String = ""
        public var steps: Int = 5
        public var runDir: String = "run"
        public var allowDestructive: Bool = false
        public var policy: String = "dummy"
        public var request: Bool = false
    }

    /// Parses arguments; returns `nil` for anything invalid (caller prints
    /// usage). Hand-rolled on purpose: three subcommands do not justify a
    /// dependency.
    public static func parse(_ arguments: [String]) -> Options? {
        guard let command = arguments.first,
              ["preflight", "dry-run", "run"].contains(command) else {
            return nil
        }
        var options = Options()
        options.command = command

        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            func nextValue() -> String? {
                guard index + 1 < arguments.count else { return nil }
                index += 1
                return arguments[index]
            }
            switch argument {
            case "--steps":
                guard let raw = nextValue(), let value = Int(raw), value > 0 else { return nil }
                options.steps = value
            case "--run-dir":
                guard let value = nextValue(), !value.isEmpty else { return nil }
                options.runDir = value
            case "--policy":
                guard let value = nextValue(), !value.isEmpty else { return nil }
                options.policy = value
            case "--allow-destructive":
                options.allowDestructive = true
            case "--request":
                options.request = true
            default:
                return nil
            }
            index += 1
        }
        return options
    }

    /// Entry point. `perceiver` / `backend` exist so tests (and future
    /// embedders) can inject fakes; both default to the platform wiring.
    public static func run(arguments: [String],
                           perceiver: Perceiver? = nil,
                           backend: ActionBackend? = nil,
                           out: (String) -> Void = { print($0) }) -> Int32 {
        if arguments.isEmpty {
            out(usage)
            return 2
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            out(usage)
            return 0
        }
        guard let options = parse(arguments) else {
            out(usage)
            return 2
        }
        switch options.command {
        case "preflight":
            return runPreflight(options, out: out)
        case "dry-run", "run":
            return runLoopCommand(options, perceiver: perceiver, backend: backend, out: out)
        default:
            out(usage)
            return 2
        }
    }

    static func runPreflight(_ options: Options, out: (String) -> Void) -> Int32 {
        #if os(macOS)
        let checks = MacPreflight.runChecks(request: options.request)
        #else
        let checks = Preflight.nonMacOSChecks(platformName: Preflight.platformName)
        #endif
        out(Preflight.format(checks))
        #if os(macOS)
        if options.request {
            out("requests sent — grant the permissions in System Settings, restart the terminal, then re-run preflight.")
        }
        #endif
        return Preflight.exitCode(checks)
    }

    static func runLoopCommand(_ options: Options,
                               perceiver: Perceiver?,
                               backend: ActionBackend?,
                               out: (String) -> Void) -> Int32 {
        let policy: Policy
        do {
            policy = try loadPolicy(named: options.policy)
        } catch {
            out("error: \(error)")
            return 2
        }

        let dryRun = options.command == "dry-run"
        let actuator = Actuator(dryRun: dryRun,
                                allowDestructive: options.allowDestructive,
                                backend: backend ?? Platform.defaultBackend())
        let activePerceiver = perceiver ?? Platform.defaultPerceiver()

        out("s1 \(dryRun ? "DRY-RUN" : "LIVE") — policy=\(options.policy) steps=\(options.steps) run_dir=\(options.runDir)")

        let records: [StepRecord]
        do {
            records = try Loop.run(policy: policy,
                                   steps: options.steps,
                                   runDir: options.runDir,
                                   actuator: actuator,
                                   perceiver: activePerceiver)
        } catch {
            out("error: failed to write run log: \(error)")
            return 1
        }

        for record in records {
            let gate = record.gate.allowed ? "allow" : "REJECT"
            let confidence = record.confidence.map { "\($0)" } ?? "-"
            let kind = record.action.kind.padding(toLength: 12, withPad: " ", startingAt: 0)
            out("  [\(record.step)] \(kind) gate=\(gate) risk=\(record.gate.risk.rawValue) result=\(record.result.status.rawValue) conf=\(confidence)")
        }
        let allowed = records.filter { $0.gate.allowed }.count
        out("summary: \(records.count) steps, \(allowed) allowed, \(records.count - allowed) rejected")
        if dryRun {
            out("dry-run: no real actions were executed")
        }
        out("log: \(options.runDir)/steps.jsonl")
        return 0
    }
}
