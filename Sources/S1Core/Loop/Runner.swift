import Foundation
import ApplicationServices

/// libproc isn't in Swift's Darwin module — declare it directly. Links from
/// libsystem_kernel like the standard tooling (ps, lsof) uses.
@_silgen_name("proc_pidpath")
private func procPidPath(_ pid: pid_t, _ buffer: UnsafeMutableRawPointer?,
                         _ buffersize: UInt32) -> Int32

/// Shared run setup for CLI commands: logger + perceiver + actuator + gate + loop.
public enum S1Runner {
    /// Pid file marking a live agent run. Two agents typing at once is the
    /// disaster this prevents: any process can check screen ownership.
    public static let lockPath = NSHomeDirectory() + "/.s1/run.pid"

    /// True while another process holds the run lock. Stale files after a
    /// crash expire via pid-liveness AND identity: a recycled pid owned by
    /// an unrelated process is not an s1 run.
    public static func anotherRunActive() -> Bool {
        guard let txt = try? String(contentsOfFile: lockPath, encoding: .utf8),
              let other = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
              other != ProcessInfo.processInfo.processIdentifier,
              pidLooksLikeS1(other) else { return false }
        return true
    }

    /// The executable path for a pid (lowercased), or nil when libproc
    /// can't read it (foreign process, permission).
    public static func pidExePath(_ pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)   // PROC_PIDPATHINFO_MAXSIZE
        guard procPidPath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        let bytes = buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self).lowercased()
    }

    /// Is this pid a live s1 binary or the S1 app? Liveness alone lies on
    /// pid reuse — check the executable path too.
    public static func pidLooksLikeS1(_ pid: pid_t) -> Bool {
        guard kill(pid, 0) == 0 else { return false }
        guard let path = pidExePath(pid) else { return true }
        // Couldn't read the path (foreign process, permission) — liveness
        // was proven, so assume busy rather than racing a real agent.
        return path.hasSuffix("/s1") || path.contains("/s1.app/") || path.contains("/s1-cli")
    }

    /// Does `path` hold THIS process's pid? Used to distinguish "we already
    /// claimed it" from "a competitor holds it" on re-entrant checks.
    public static func holdsPidFile(_ path: String) -> Bool {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return false }
        return pid == ProcessInfo.processInfo.processIdentifier
    }

    /// Take the run lock, or throw `.busy` if a live s1 process holds it.
    /// Pair every successful call with `releaseRunLock()` (defer).
    public static func acquireRunLock() throws {
        try claimPidFile(lockPath, what: "s1 run")
    }

    /// Atomically claim a pid file with this process's pid — O_EXCL create
    /// closes the check-then-write window where two processes could both
    /// claim it. A live s1 process holding the file throws `.busy`; a
    /// provably-stale file (dead pid, foreign executable, empty) is removed
    /// and retried once. Pair with removing the file at exit.
    public static func claimPidFile(_ path: String, what: String) throws {
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        for _ in 0..<2 {
            let fd = open(path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            if fd >= 0 {
                let pid = String(ProcessInfo.processInfo.processIdentifier)
                _ = pid.withCString { write(fd, $0, strlen($0)) }
                close(fd)
                return
            }
            // Exists already: a live s1 holds it, or a crash left a stale
            // file. Only ever remove a provably-stale lock — a competitor
            // who won the O_EXCL race wrote a live pid, which this check
            // sees and reports as busy.
            if let live = livePidHolder(of: path) {
                throw S1Error.busy("another \(what) is already running (pid \(live)) — wait for it or stop it first")
            }
            // An empty/unreadable file might be a winner mid-write between
            // create and pid-write — give the pid a beat to land, then
            // check liveness once more before calling it stale.
            usleep(50_000)
            if let live = livePidHolder(of: path) {
                throw S1Error.busy("another \(what) is already running (pid \(live)) — wait for it or stop it first")
            }
            try? FileManager.default.removeItem(atPath: path)
        }
        throw S1Error.busy("\(what) lock contention — try again")
    }

    /// The pid a live s1 process wrote to `path`, or nil for missing/stale.
    /// Public so installers can check for a competing listener up front
    /// (a launchd agent that fails to claim would respawn-churn forever).
    public static func livePidHolder(of path: String) -> pid_t? {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid != ProcessInfo.processInfo.processIdentifier,
              pidLooksLikeS1(pid) else { return nil }
        return pid
    }

    /// Removes a pid file only when it holds OUR pid — the pid-checked
    /// counterpart of claimPidFile for graceful shutdown paths.
    public static func releasePidFile(_ path: String) {
        guard let txt = try? String(contentsOfFile: path, encoding: .utf8),
              pid_t(txt.trimmingCharacters(in: .whitespacesAndNewlines))
                == ProcessInfo.processInfo.processIdentifier else { return }
        try? FileManager.default.removeItem(atPath: path)
    }

    /// Race `work` against the kill-switch file — a model HTTP call ignores
    /// the file for the whole request timeout otherwise, so `s1 stop` would
    /// wait minutes. Winner takes; the loser is cancelled (URLSession calls
    /// unwind through Task cancellation).
    public static func racingKillSwitch<T: Sendable>(
        _ path: String?,
        _ work: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        guard let path else { return try await work() }
        return try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await work() }
            group.addTask {
                while true {
                    try await Task.sleep(nanoseconds: 250_000_000)
                    if FileManager.default.fileExists(atPath: path) {
                        throw S1Error.aborted("kill switch")
                    }
                    try Task.checkCancellation()
                }
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    /// Sleep in ≤0.5s slices so a kill-switch file written mid-wait lands
    /// within half a second instead of after the full duration. Returns
    /// false when interrupted (file present or task cancelled).
    public static func sleepInterruptibly(_ seconds: Double,
                                          killSwitchPath: String? = nil) async -> Bool {
        var remaining = seconds
        while remaining > 0 {
            let slice = min(0.5, remaining)
            try? await Task.sleep(nanoseconds: UInt64(slice * 1e9))
            if Task.isCancelled { return false }
            if let k = killSwitchPath, FileManager.default.fileExists(atPath: k) { return false }
            remaining -= slice
        }
        return true
    }

    /// Removes the lock only when WE hold it — a dry-run (which never
    /// acquires) must not delete a live run's lock file.
    public static func releaseRunLock() { releasePidFile(lockPath) }

    /// Non-dry-run gate — without AX trust the tree reads empty and
    /// CGEvent posts silently drop, so a run would "type" into the void
    /// while its log claims success. Throws with the fix instructions.
    public static func requireAccessibility() throws {
        let axPrompt = ["AXTrustedCheckOptionPrompt": false] as CFDictionary
        guard AXIsProcessTrustedWithOptions(axPrompt) else {
            throw S1Error.aborted(
                "Accessibility not granted — enable this app in " +
                "System Settings → Privacy & Security → Accessibility, then retry")
        }
    }

    @discardableResult
    public static func run(goal: String, policy: any Policy, artifacts: String,
                           maxSteps: Int, threshold: Double, dryRun: Bool,
                           allowIrreversible: Bool, killSwitch: String?,
                           s2: (any Reasoner)? = nil,
                           onStep: (@Sendable (StepRecord) -> Void)? = nil) async throws -> (report: RunReport, logger: RunLogger) {
        if !dryRun {
            try requireAccessibility()
            try acquireRunLock()
        }
        defer { if !dryRun { releaseRunLock() } }
        var config = LoopConfig()
        config.maxSteps = maxSteps
        config.confidenceThreshold = threshold
        config.dryRun = dryRun
        config.killSwitchPath = killSwitch

        let root = URL(fileURLWithPath: artifacts)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let actuator: any Actuator = dryRun ? DryRunActuator() : CGEventActuator()

        let logger = try RunLogger(
            goal: goal, root: root,
            config: [
                "s1": S1Info.version,
                "policy": policy.name,
                "actuator": actuator.name,
                "threshold": String(threshold),
                "maxSteps": String(maxSteps),
                "allowIrreversible": String(allowIrreversible),
                "s2": s2?.name ?? "none",
            ], onStep: onStep)
        let perceiver = SystemPerceiver(screenshotSink: { img in
            try await logger.saveScreenshot(img)
        })

        let gate = SafetyGate(allowReversible: true, allowIrreversible: allowIrreversible)
        let loop = AgentLoop(config: config, perceiver: perceiver, actuator: actuator,
                             gate: gate, s2: s2)

        print("run dir: \(logger.runDir.path)")
        let report = try await loop.run(goal: goal, policy: policy, logger: logger)
        print("status: \(report.status.rawValue) | steps: \(report.steps) | escalations: \(report.escalations)")
        return (report, logger)
    }
}
