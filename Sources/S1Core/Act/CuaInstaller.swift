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

    /// The app bundle the official installer drops — signature checks run
    /// against this exact path, not whatever a tampered script claims.
    public static let appPath = "/Applications/CuaDriver.app"
    /// CUA's Apple Developer identity. A payload that can't be
    /// cryptographically tied to this team is not the driver — reject it
    /// even when the installer "succeeded".
    public static let expectedTeamID = "YCK386LBJ7"
    public static let expectedSigner = "Developer ID Application: Cua AI, Inc."

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
        // A hijacked install.sh can drop anything — the only thing that
        // can't be forged is Apple's Developer ID + notarization, so check
        // both before calling this "installed".
        let v = try verify()
        output("verified: \(v.detail) · sha256 \(v.sha256.prefix(16))…")
    }

    /// Cryptographic identity check on the installed bundle:
    /// `codesign` must show CUA's Developer ID + team, and `spctl` must
    /// accept it as notarized. Returns the Mach-O's SHA-256 for the log —
    /// an audit trail, not a pin (pinning would break every legit update).
    /// Throws S1Error on any mismatch — better CGEvent than a fake driver.
    @discardableResult
    public static func verify(
        appPath: String = appPath
    ) throws -> (sha256: String, detail: String) {
        var status = runProc("/usr/bin/codesign", ["-dvv", appPath])
        let sign = status.err
        guard sign.contains("Authority=\(expectedSigner)"),
              sign.contains("TeamIdentifier=\(expectedTeamID)") else {
            throw S1Error.actionFailed(
                "cua-driver signature check failed — expected “\(expectedSigner)” "
                + "team \(expectedTeamID); refusing to use an unverifiable driver")
        }
        status = runProc("/usr/sbin/spctl", ["--assess", "--type", "execute", "-vv", appPath])
        guard status.out.contains("accepted") || status.err.contains("accepted"),
              status.out.contains("Notarized") || status.err.contains("Notarized") else {
            throw S1Error.actionFailed(
                "cua-driver is signed but not notarized — refusing to use it")
        }
        let sha = runProc("/usr/bin/shasum", ["-a", "256", appPath + "/Contents/MacOS/cua-driver"]).out
            .split(separator: " ").first.map(String.init) ?? "?"
        return (sha, "\(expectedSigner) (\(expectedTeamID)), notarized")
    }

    /// CUA's own grant flow: `cua-driver permissions grant` launches the
    /// driver app so TCC dialogs attribute to `com.trycua.driver`, requests
    /// Accessibility + Screen Recording + direct-capture consent, then
    /// verifies live capture. Interactive — call from a user-facing context.
    public static func grantPermissions(output: @Sendable @escaping (String) -> Void = { _ in }) async throws {
        guard let bin = CuaDriver.binary() else { throw S1Error.aborted("cua-driver not installed") }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = ["permissions", "grant"]
        let pipe = Pipe()
        proc.standardOutput = pipe; proc.standardError = pipe
        pipe.fileHandleForReading.readabilityHandler = { h in
            output(String(decoding: h.availableData, as: UTF8.self))
        }
        try proc.run()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            proc.terminationHandler = { p in
                p.terminationStatus == 0 ? c.resume()
                    : c.resume(throwing: S1Error.actionFailed("cua-driver permissions grant failed"))
            }
        }
    }

    /// Small Process wrapper returning trimmed stdout/stderr.
    private static func runProc(_ path: String, _ argv: [String]) -> (out: String, err: String) {
        let p = Process(), out = Pipe(), err = Pipe()
        p.executableURL = URL(fileURLWithPath: path); p.arguments = argv
        p.standardOutput = out; p.standardError = err
        guard (try? p.run()) != nil else { return ("", "") }
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
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
