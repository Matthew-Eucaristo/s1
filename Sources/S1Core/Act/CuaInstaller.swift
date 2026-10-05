import Foundation

/// Installs Cua Driver using CUA's own recommended installer —
/// `/bin/bash -c "$(curl -fsSL https://cua.ai/driver/install.sh)"`.
/// The vendor script puts CuaDriver.app in /Applications and symlinks
/// `cua-driver` into ~/.local/bin, and its `com.trycua.driver` signing
/// identity keeps Accessibility grants valid across upgrades. We run it
/// verbatim instead of re-implementing the download so the flow always
/// tracks whatever CUA currently recommends.
///
/// https://cua.ai/docs/driver — MIT
public enum CuaInstaller {
    /// The vendor-recommended one-liner, run verbatim. Also printed by
    /// `s1 setup` and the onboarding wizard so the user can inspect or
    /// run it manually instead.
    public static let officialCommand =
        "/bin/bash -c \"$(curl -fsSL https://cua.ai/driver/install.sh)\""

    /// Whether a usable driver is already on disk.
    public static var installed: Bool { CuaDriver.binary() != nil }

    /// Where the user can read about the driver — shown next to the
    /// install action so the choice is informed, not blind.
    public static let docsURL = "https://cua.ai/docs/libraries/cua-driver"

    /// Run the official installer, streaming combined stdout/stderr line
    /// by line. Throws `S1Error` when the script exits non-zero or the
    /// binary still isn't resolvable afterwards (install actually
    /// failed — a silent "installed" would be a lie).
    /// Bounded at 5 minutes; the download is ~10 MB so a hang means a
    /// dead network, not a slow one.
    public static func install(
        output: @Sendable @escaping (String) -> Void = { _ in }) async throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/bash")
        proc.arguments = ["-c", "set -o pipefail; " + officialCommand]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let buf = LockedBuffer()
        pipe.fileHandleForReading.readabilityHandler = { h in
            let chunk = String(decoding: h.availableData, as: UTF8.self)
            for line in buf.append(chunk) { output(line) }
        }
        try proc.run()
        // Bound the wait: the script downloads an app bundle — a dead
        // network would otherwise hang the wizard forever.
        let killer = DispatchWorkItem { if proc.isRunning { proc.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300, execute: killer)
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            proc.terminationHandler = { _ in c.resume() }
        }
        killer.cancel()
        pipe.fileHandleForReading.readabilityHandler = nil
        for line in buf.flush() { output(line) }
        guard proc.terminationReason == .exit, proc.terminationStatus == 0 else {
            throw S1Error.actionFailed(
                "cua-driver install failed (exit \(proc.terminationStatus))"
                + (buf.lastLine.map { " — \($0)" } ?? ""))
        }
        // Verify, don't trust: the binary must resolve before we say
        // "installed". CUA's script links it into ~/.local/bin.
        guard CuaDriver.binary() != nil else {
            throw S1Error.actionFailed(
                "installer ran but cua-driver still isn't on PATH — see \(docsURL)")
        }
    }
}

/// Partial-line buffer for streamed process output — fragments arrive
/// mid-line, so complete lines go to `output` only at each \n.
final class LockedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = ""
    private var last: String?

    /// Feed a chunk; returns the complete lines it closed.
    func append(_ s: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        pending += s
        var lines = pending.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        pending = pending.hasSuffix("\n") || lines.isEmpty ? "" : lines.removeLast()
        let done = lines.filter { !$0.isEmpty }
        if let l = done.last { last = l }
        return done
    }

    /// Whatever's left when the process exits (no trailing newline).
    func flush() -> [String] {
        lock.lock(); defer { lock.unlock() }
        let r = pending.isEmpty ? [] : [pending]
        if let l = r.last { last = l }
        pending = ""
        return r
    }

    var lastLine: String? { lock.lock(); defer { lock.unlock() }; return last }
}
