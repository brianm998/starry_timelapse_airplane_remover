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

/// The value of `task`, or `TestTimeout` after `seconds`, in which case `task` is cancelled too.
/// `withTimeout { await task.value }` would not do: awaiting another task's value is not
/// cancellable, so the timed-out child would hold the task group (and the test) open.
func boundedValue<T: Sendable>(of task: Task<T, Never>, seconds: TimeInterval = 60, what: String) async throws -> T {
    try await withTimeout(seconds, what: what) {
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}

func boundedValue<T: Sendable>(of task: Task<T, Error>, seconds: TimeInterval = 60, what: String) async throws -> T {
    try await withTimeout(seconds, what: what) {
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }
}

/// `source`, except that it finishes after `seconds` even if `source` never does (and says so with
/// a failure naming `what`).  For the `for await event in stream` loops that check a deadline in
/// their body: that body only runs when an event arrives, so on a quiet stream the deadline never
/// gets looked at and the loop waits for ever.
func boundedStream<E: Sendable>(
    _ source: AsyncStream<E>, seconds: TimeInterval, what: String,
    onTimeout: @escaping @Sendable (TestTimeout) -> Void = { XCTFail("\($0)") }
) -> AsyncStream<E> {
    AsyncStream { continuation in
        let pump = Task {
            for await element in source { continuation.yield(element) }
            continuation.finish()
        }
        let timer = Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))) != nil else { return }
            onTimeout(TestTimeout(what: what, seconds: seconds))
            pump.cancel()
            continuation.finish()
        }
        continuation.onTermination = { _ in pump.cancel(); timer.cancel() }
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

/// Just enough of a lock to share a value with a `@Sendable` closure.
final class Locked<Value>: @unchecked Sendable {
    private var value: Value
    private let lock = NSLock()
    init(_ value: Value) { self.value = value }
    func withLock<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
}
