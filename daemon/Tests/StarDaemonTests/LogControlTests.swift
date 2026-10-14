import XCTest
import logging
@testable import stard

/// `Daemon.SetLogLevel`: what a request changes, and that one that cannot be done changes nothing.
final class LogControlTests: XCTestCase {

    /// Records what the control asked the process's log to do, in place of doing it.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _console: [Log.Level] = []
        private var _files: [String] = []
        var failFile = false

        var console: [Log.Level] { lock.withLock { _console } }
        var files: [String] { lock.withLock { _files } }
        func recordConsole(_ level: Log.Level) { lock.withLock { _console.append(level) } }
        func recordFile(enabled: Bool, level: Log.Level, directory: URL?) throws -> String? {
            if failFile { throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "no room"]) }
            lock.withLock { _files.append(enabled ? "on:\(level.rawValue)" : "off") }
            return enabled ? "/logs/stard-test.txt" : nil
        }
    }

    private func control(_ recorder: Recorder, level: Log.Level = .info) -> LogControl {
        LogControl(level: level,
                   writeConsole: { recorder.recordConsole($0) },
                   writeFile: { try recorder.recordFile(enabled: $0, level: $1, directory: $2) })
    }

    func testTheLevelIsChangedAndReported() async throws {
        let recorder = Recorder()
        let log = control(recorder)
        let state = try await log.apply(level: "debug", fileEnabled: nil, fileLevel: "")
        XCTAssertEqual(state.level, .debug)
        XCTAssertEqual(recorder.console, [.debug])
        XCTAssertEqual(state.response.level, "debug")
        XCTAssertFalse(state.response.fileEnabled)
        XCTAssertEqual(state.response.fileLogPath, "")
    }

    func testLevelsAreReadWithoutRegardToCase() async throws {
        let log = control(Recorder())
        let state = try await log.apply(level: " WARN ", fileEnabled: nil, fileLevel: "")
        XCTAssertEqual(state.level, .warn)
    }

    func testAnEmptyLevelKeepsTheLevelAndSaysNothingToTheLog() async throws {
        let recorder = Recorder()
        let log = control(recorder, level: .warn)
        let state = try await log.apply(level: "", fileEnabled: nil, fileLevel: "")
        XCTAssertEqual(state.level, .warn)
        XCTAssertEqual(recorder.console, [], "the same level is not written again")
        XCTAssertEqual(recorder.files, [])
    }

    func testTheFileIsStartedAtItsLevelAndStopped() async throws {
        let recorder = Recorder()
        let log = control(recorder)
        var state = try await log.apply(level: "", fileEnabled: true, fileLevel: "debug")
        XCTAssertTrue(state.fileEnabled)
        XCTAssertEqual(state.fileLevel, .debug)
        XCTAssertEqual(state.response.fileLogPath, "/logs/stard-test.txt")

        state = try await log.apply(level: "", fileEnabled: false, fileLevel: "")
        XCTAssertFalse(state.fileEnabled)
        XCTAssertEqual(state.response.fileLogPath, "")
        XCTAssertEqual(state.fileLevel, .debug, "the level it was last written at is remembered for the next time")
        XCTAssertEqual(recorder.files, ["on:debug", "off"])
    }

    func testChangingTheFilesLevelWhileItIsOnRestartsIt() async throws {
        let recorder = Recorder()
        let log = control(recorder)
        _ = try await log.apply(level: "", fileEnabled: true, fileLevel: "info")
        _ = try await log.apply(level: "", fileEnabled: nil, fileLevel: "warn")
        XCTAssertEqual(recorder.files, ["on:info", "on:warn"])
    }

    func testChangingTheFilesLevelWhileItIsOffOnlyRemembersIt() async throws {
        let recorder = Recorder()
        let log = control(recorder)
        let state = try await log.apply(level: "", fileEnabled: nil, fileLevel: "error")
        XCTAssertEqual(state.fileLevel, .error)
        XCTAssertEqual(recorder.files, [])
    }

    func testAnUnknownLevelChangesNothing() async throws {
        let recorder = Recorder()
        let log = control(recorder)
        do {
            // the first is fine, the second is not: neither may take effect
            _ = try await log.apply(level: "debug", fileEnabled: true, fileLevel: "loud")
            XCTFail("an unknown level was accepted")
        } catch let failure as LogControl.Failure {
            XCTAssertEqual(failure, .unknownLevel("loud"))
            XCTAssertTrue(failure.description.contains("loud"))
        }
        let state = await log.state
        XCTAssertEqual(state.level, .info)
        XCTAssertFalse(state.fileEnabled)
        XCTAssertEqual(recorder.console, [])
        XCTAssertEqual(recorder.files, [])
    }

    func testAFileThatCannotBeOpenedLeavesTheLevelAlone() async throws {
        let recorder = Recorder()
        recorder.failFile = true
        let log = control(recorder)
        do {
            _ = try await log.apply(level: "debug", fileEnabled: true, fileLevel: "info")
            XCTFail("the file failure was swallowed")
        } catch {
            XCTAssertTrue("\(error)".contains("no room") || (error as NSError).domain == "test")
        }
        let state = await log.state
        XCTAssertEqual(state.level, .info, "the console is changed only once the file has been")
        XCTAssertFalse(state.fileEnabled)
        XCTAssertEqual(recorder.console, [])
    }

    func testTheLevelTheDaemonStartedAtIsAdopted() async throws {
        let recorder = Recorder()
        let log = control(recorder)
        await log.adopt(level: .error, logsDirectory: URL(fileURLWithPath: "/tmp/logs"))
        let state = await log.state
        XCTAssertEqual(state.level, .error)
        XCTAssertEqual(recorder.console, [], "the handler is already there at that level")
    }
}
