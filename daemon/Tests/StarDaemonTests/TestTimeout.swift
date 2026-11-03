import XCTest
import Foundation

/// An await that gave up instead of hanging the whole `swift test` run.
struct TestTimeout: Error, CustomStringConvertible {
    let what: String
    let seconds: TimeInterval
    var description: String { "timed out after \(seconds)s waiting for \(what)" }
}

/// Runs `operation` and returns its result, or throws `TestTimeout` if it has not finished after
/// `seconds`.  A wait that never ends (a stream nobody finishes, a continuation nobody resumes)
/// fails the test with a message that names `what`, rather than sitting at 0% CPU until someone
/// kills `xctest`.
///
/// This bounds only waits that can be cancelled.  A blocking read or `waitUntilExit` ignores
/// cancellation, so those are bounded at their source (`DaemonProcess.idleTimeout`, `runBounded`).
func withTimeout<T: Sendable>(
    _ seconds: TimeInterval, what: String, _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw TestTimeout(what: what, seconds: seconds)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw TestTimeout(what: what, seconds: seconds) }
        return first
    }
}

/// Consumes `stream` until `body` returns `true` or the stream finishes, giving up after `seconds`
/// either way.  The deadline holds even when the stream is quiet, which a deadline checked inside a
/// `for await` body does not: that body only runs when an event arrives.  Returns whether `body`
/// said stop.
@discardableResult
func consume<S: AsyncSequence & Sendable>(
    _ stream: S, within seconds: TimeInterval, what: String, until body: @escaping @Sendable (S.Element) -> Bool
) async -> Bool where S.Element: Sendable {
    do {
        return try await withTimeout(seconds, what: what) {
            for try await element in stream where body(element) { return true }
            return false
        }
    } catch {
        return false
    }
}

/// `Process.waitUntilExit()`, but a process still running after `seconds` is terminated and the
/// test fails, instead of the test waiting for it for ever.
func waitUntilExit(_ process: Process, within seconds: TimeInterval = 120, what: String,
                   file: StaticString = #filePath, line: UInt = #line) {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning, Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
    if process.isRunning {
        XCTFail("\(what) still running after \(seconds)s; terminated", file: file, line: line)
        process.terminate()
        let killDeadline = Date().addingTimeInterval(5)
        while process.isRunning, Date() < killDeadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
}
