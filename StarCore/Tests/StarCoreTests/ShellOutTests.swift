import XCTest
@testable import StarCore

final class ShellOutTests: XCTestCase {

    /// A child that writes far more than a pipe holds, to stdout and stderr both, used to hang: it
    /// blocked on the full pipe and never exited while the parent waited for it to. The timeout is
    /// a backstop, not the check.
    func testALargeAmountOfOutputOnBothPipesDoesNotDeadlock() throws {
        let script = "yes x | head -c 400000; yes y | head -c 400000 >&2"
        let done = expectation(description: "finished")
        nonisolated(unsafe) var output = ""
        nonisolated(unsafe) var failure: Error?
        DispatchQueue.global().async {
            do { output = try shellOut(to: "/bin/sh", arguments: ["-c", script]) } catch { failure = error }
            done.fulfill()
        }
        wait(for: [done], timeout: 20)
        XCTAssertNil(failure)
        XCTAssertEqual(output.utf8.count, 400_000)
        XCTAssertTrue(output.hasPrefix("x\nx\n"))
    }

    func testStderrIsReportedWithTheExitCode() {
        XCTAssertThrowsError(try shellOut(to: "/bin/sh", arguments: ["-c", "echo out; echo problem >&2; exit 3"])) { error in
            guard let failure = error as? ShellOutError else { return XCTFail("\(error)") }
            XCTAssertEqual(failure.exitCode, 3)
            XCTAssertTrue(failure.output.contains("out"))
            XCTAssertTrue(failure.errorOutput.contains("problem"))
        }
    }

    func testPlainOutputStillComesBack() throws {
        XCTAssertEqual(try shellOut(to: "/bin/echo", arguments: ["hello"]), "hello\n")
    }
}
