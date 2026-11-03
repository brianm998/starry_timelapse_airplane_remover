import XCTest
import Foundation

/// A `swift test` run must not be able to hang on a wait that never ends (ticket #209).  Each test
/// here runs the wait that used to be unbounded and checks it gives up, quickly, with a message.
final class DaemonTestTimeoutTests: XCTestCase {

    func test_a_never_completing_wait_fails_within_its_bound() async throws {
        // 1. A daemon that says nothing and stays up: the call must give up at the idle timeout.
        let silent = try DaemonProcess(binaryPath: "/bin/sleep", scratchDir: "", arguments: ["600"], idleTimeout: 1)
        defer { silent.terminate() }
        let start = Date()
        let result = await silent.rawCall(id: 1, method: "Daemon.Hello", payload: Data())
        guard case .error(let message, _) = result else { return XCTFail("a silent daemon answered: \(result)") }
        XCTAssertTrue(message.contains("timed out"), "the failure says why: \(message)")
        XCTAssertTrue(message.contains("Daemon.Hello"), "and what it was waiting for: \(message)")
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
        XCTAssertTrue(silent.hasTerminated, "the stuck daemon is killed, not left behind")

        // 2. A daemon that exits at once: the read sees end of file, it does not wait for ever.
        let gone = try DaemonProcess(binaryPath: "/usr/bin/true", scratchDir: "", arguments: [], idleTimeout: 20)
        let goneStart = Date()
        let goneResult = await gone.rawCall(id: 1, method: "Daemon.Hello", payload: Data())
        guard case .error(let goneMessage, _) = goneResult else { return XCTFail("a dead daemon answered") }
        XCTAssertFalse(goneMessage.contains("timed out"), "end of file, not the timeout: \(goneMessage)")
        XCTAssertLessThan(Date().timeIntervalSince(goneStart), 10)

        // 3. A stream that is never finished.
        let (stream, _) = AsyncStream<Int>.makeStream()
        let streamStart = Date()
        let saw = await consume(stream, within: 1, what: "an AsyncStream nobody finishes") { _ in true }
        XCTAssertFalse(saw)
        XCTAssertLessThan(Date().timeIntervalSince(streamStart), 10)

        // 4. withTimeout itself names what it was waiting for.
        do {
            _ = try await withTimeout(1, what: "a continuation nobody resumes") {
                try await Task.sleep(nanoseconds: 600_000_000_000)
                return 0
            }
            XCTFail("withTimeout returned")
        } catch let timeout as TestTimeout {
            XCTAssertEqual(timeout.what, "a continuation nobody resumes")
        }
    }
}
