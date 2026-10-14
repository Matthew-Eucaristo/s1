import Foundation

extension Process {
    /// Start the process and wait for it to exit. The termination handler
    /// goes in before `run()`: installed after, a process that exits fast
    /// can finish first and the wait never ends.
    func runUntilExit() async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            terminationHandler = { _ in c.resume() }
            do { try run() } catch {
                terminationHandler = nil
                c.resume(throwing: error)
            }
        }
    }
}
