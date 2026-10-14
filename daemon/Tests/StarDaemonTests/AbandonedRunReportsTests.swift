import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// What a client is told about a daemon that was killed: once, after Hello, as a critical warning, with a config to restart from only when
/// that config is still there.
final class AbandonedRunReportsTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AbandonedRunReportsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func marker(resume: String?) -> RunMarker {
        var m = RunMarker(id: UUID().uuidString, client: "stard", pid: 4242, startedAt: Date().addingTimeInterval(-600))
        m.sequenceName = "night_sky"
        m.frameCount = 100
        m.framesCompleted = 40
        m.resumeConfigPath = resume
        return m
    }

    func testTheReportsAreHandedOverOnceAndForgotten() async {
        let reports = AbandonedRunReports()
        await reports.store([marker(resume: nil), marker(resume: nil)])
        let first = await reports.take()
        let second = await reports.take()
        XCTAssertEqual(first.count, 2)
        XCTAssertTrue(second.isEmpty, "a second Hello (it is idempotent) must not report the same crash again")
    }

    func testAKilledRunIsACriticalWarning() {
        let report = AbandonedRunReports.report(for: marker(resume: nil))
        XCTAssertEqual(report.warning.kind, .previousRunDied)
        XCTAssertEqual(report.warning.severity, .critical)
        XCTAssertFalse(report.warning.describesAPassingCondition, "it stays true, so its banner must not expire")
    }

    func testARunWhoseConfigIsStillThereCanBeRestarted() throws {
        let config = scratch.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: config)
        let report = AbandonedRunReports.report(for: marker(resume: config.path))
        XCTAssertEqual(report.restartableConfigPath, config.path)
    }

    /// The marker outlives the run, and the output directory may have been moved or deleted since: offering a restart over a file that has gone fails
    /// after the click.
    func testARunWhoseConfigHasGoneCannotBeRestarted() {
        XCTAssertNil(AbandonedRunReports.report(for: marker(resume: scratch.appendingPathComponent("gone.json").path)).restartableConfigPath)
        XCTAssertNil(AbandonedRunReports.report(for: marker(resume: nil)).restartableConfigPath)
    }

    /// The new fields are what the client reads them as: its own test (`WarningFieldsTest`) pins the same bytes.
    func testTheWarningCarriesTheRestartPathAndWhetherItPasses() throws {
        var w = Star_V1_Warning()
        w.kind = "previousRunDied"
        w.restartableConfigPath = "/x/config.json"
        w.passingCondition = true
        let back = try Star_V1_Warning(serializedBytes: try w.serializedData())
        XCTAssertEqual(back.restartableConfigPath, "/x/config.json")
        XCTAssertTrue(back.passingCondition)
        XCTAssertEqual(Array(try w.serializedData().suffix(2)), [0x38, 0x01], "field 7 (passing_condition) is a varint: tag 0x38, value 1")
    }

    func testThePassingConditionsAreTheMachineStateOnes() {
        func warning(_ kind: StarWarning.Kind) -> StarWarning { StarWarning(kind: kind, severity: .warning, message: "m", suggestion: nil, time: Date()) }
        for kind in [StarWarning.Kind.memoryPressure, .lowSystemMemory, .footprintOverBudget] {
            XCTAssertTrue(warning(kind).describesAPassingCondition, "\(kind)")
        }
        for kind in [StarWarning.Kind.outputWriteFailed, .lowDiskSpace, .previousRunDied, .memoryGatingDisabled] {
            XCTAssertFalse(warning(kind).describesAPassingCondition, "\(kind)")
        }
    }
}
