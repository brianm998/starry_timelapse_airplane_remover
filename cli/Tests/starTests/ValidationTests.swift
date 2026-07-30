import XCTest
import ArgumentParser
import StarCore
import logging
@testable import star

/// `StarCli.validate()` is the only place a bad flag value is turned into a usage error rather
/// than being quietly clamped further downstream.  Both of its checks exist because the value
/// would otherwise *look* like it worked: a negative `--last-frame` selects nothing after
/// loading the whole sequence, and a `--keypoint-divisor` below 1 is clamped back to full
/// resolution so the flag appears to do nothing.
///
/// `LastFrameTests` covers the last-frame half.  The divisor half, and the enum-valued options
/// generally, had no coverage.
final class ValidationTests: XCTestCase {

    /// `parse` runs `validate()`, so a rejected value throws here.
    private func parseFails(_ arguments: [String],
                            file: StaticString = #filePath,
                            line: UInt = #line)
    {
        XCTAssertThrowsError(try StarCli.parse(arguments),
                             "expected \(arguments) to be rejected",
                             file: file, line: line)
    }

    // MARK: - keypoint divisor

    func testADivisorBelowOneIsAUsageError() {
        parseFails(["--keypoint-divisor", "0.5", "/some/seq"])
        parseFails(["--keypoint-divisor", "0", "/some/seq"])
        parseFails(["--keypoint-divisor", "-2", "/some/seq"])
        parseFails(["--keypoint-divisor", "0.999", "/some/seq"])
    }

    /// 1 is full resolution and is explicitly allowed — it is how you turn the feature off
    /// without removing the flag from a script.
    func testADivisorOfExactlyOneIsAccepted() throws {
        XCTAssertEqual(try StarCli.parse(["--keypoint-divisor", "1", "/some/seq"]).keypointDivisor, 1)
    }

    func testTheUsefulDivisorsAreAccepted() throws {
        for divisor in ["1.5", "2", "3", "4", "8"] {
            let parsed = try StarCli.parse(["--keypoint-divisor", divisor, "/some/seq"])
            XCTAssertEqual(parsed.keypointDivisor, Double(divisor)!)
        }
    }

    func testAnAbsentDivisorIsNilRatherThanOne() throws {
        XCTAssertNil(try StarCli.parse(["/some/seq"]).keypointDivisor,
                     "nil is what leaves a saved config's value alone")
    }

    func testANonNumericDivisorIsAUsageError() {
        parseFails(["--keypoint-divisor", "half", "/some/seq"])
    }

    /// The error text has to say what to do instead, since the obvious guess (0.5 for half
    /// size) is exactly the value that is wrong.
    func testTheDivisorErrorExplainsWhichWayRoundItGoes() {
        do {
            _ = try StarCli.parse(["--keypoint-divisor", "0.5", "/some/seq"])
            XCTFail("0.5 should have been rejected")
        } catch {
            let message = StarCli.message(for: error)
            XCTAssertTrue(message.contains("2"),
                          "the message should point at 2 for half size: \(message)")
            XCTAssertTrue(message.lowercased().contains("divis"),
                          "the message should name the divisor: \(message)")
        }
    }

    // MARK: - last frame, alongside the divisor

    func testBothValidationsApplyToOneCommandLine() {
        parseFails(["--last-frame", "-1", "--keypoint-divisor", "2", "/some/seq"])
        parseFails(["--last-frame", "5", "--keypoint-divisor", "0.5", "/some/seq"])
    }

    func testAValidPairPassesBothChecks() throws {
        let cli = try StarCli.parse(["--last-frame", "5", "--keypoint-divisor", "2", "/some/seq"])
        XCTAssertEqual(cli.lastFrameIndex, 5)
        XCTAssertEqual(cli.keypointDivisor, 2)
    }

    // MARK: - enum valued options

    /// `CleanMethod` is `ExpressibleByArgument`, and it is the flag most likely to be typed by
    /// hand.  An unparsed value has to be a usage error rather than falling back to a default.
    func testEveryCleanMethodSpellingParses() throws {
        XCTAssertEqual(try StarCli.parse(["-c", "selective", "/some/seq"]).cleanMethod, .selective)
        XCTAssertEqual(try StarCli.parse(["--clean-method", "selective", "/some/seq"]).cleanMethod,
                       .selective)
    }

    func testAnUnknownCleanMethodIsAUsageError() {
        parseFails(["-c", "banana", "/some/seq"])
    }

    func testEveryDetectionTypeParses() throws {
        let expected: [(String, DetectionType)] = [
          ("mild", .mild), ("strong", .strong), ("stronger", .stronger),
          ("excessive", .excessive), ("custom", .custom),
        ]
        for (spelling, value) in expected {
            XCTAssertEqual(try StarCli.parse(["-d", spelling, "/some/seq"]).detectionType, value,
                           "--detection-type \(spelling) did not parse")
        }
    }

    func testAnUnknownDetectionTypeIsAUsageError() {
        parseFails(["-d", "extreme", "/some/seq"])
    }

    /// Every `Log.Level` case has to be usable as a console level, or `-l` would reject a level
    /// the logger itself understands.
    func testEveryLogLevelParsesAsAConsoleLevel() throws {
        for level in Log.Level.allCases {
            let cli = try StarCli.parse(["-l", level.rawValue, "/some/seq"])
            XCTAssertEqual(cli.terminalLogLevel, level, "-l \(level.rawValue) did not parse")
        }
    }

    func testAnUnknownLogLevelIsAUsageError() {
        parseFails(["-l", "chatty", "/some/seq"])
    }

    // MARK: - the numeric options that have a meaningful zero

    /// These three all treat 0 as a real request rather than "unset", which is why they are
    /// `Int?` here and read through `has…` on the wire.  Parsing has to keep 0 distinct from
    /// absent, or the request would be lost before it reached the config.
    func testZeroIsDistinctFromAbsentForTheMemoryKnobs() throws {
        let zeroed = try StarCli.parse(["--merge-streaming-threshold-mb", "0",
                                        "--max-keypoint-ops", "0",
                                        "--horizon-reservation-floor-mb", "0",
                                        "/some/seq"])
        XCTAssertEqual(zeroed.mergeStreamingThresholdMB, 0)
        XCTAssertEqual(zeroed.maxKeypointOps, 0)
        XCTAssertEqual(zeroed.horizonReservationFloorMB, 0)

        let absent = try StarCli.parse(["/some/seq"])
        XCTAssertNil(absent.mergeStreamingThresholdMB)
        XCTAssertNil(absent.maxKeypointOps)
        XCTAssertNil(absent.horizonReservationFloorMB)
    }

    func testTheMemoryKnobsAcceptOrdinaryValues() throws {
        let cli = try StarCli.parse(["--merge-streaming-threshold-mb", "2048",
                                     "--max-keypoint-ops", "3",
                                     "--horizon-reservation-floor-mb", "900",
                                     "/some/seq"])
        XCTAssertEqual(cli.mergeStreamingThresholdMB, 2048)
        XCTAssertEqual(cli.maxKeypointOps, 3)
        XCTAssertEqual(cli.horizonReservationFloorMB, 900)
    }

    func testIgnoreLowerPixelsKeepsAnExplicitZero() throws {
        XCTAssertEqual(try StarCli.parse(["-i", "0", "/some/seq"]).ignoreLowerPixels, 0)
        XCTAssertNil(try StarCli.parse(["/some/seq"]).ignoreLowerPixels)
    }

    // MARK: - the boolean flags

    /// The plain flags are `Bool = false`, so they can only ever be off or on — never "unset".
    /// `ConfigOverrides` is what turns a false into a nil, and it is covered separately; what
    /// matters here is that the flag itself is seen.
    func testThePlainFlagsDefaultOffAndTurnOn() throws {
        let none = try StarCli.parse(["/some/seq"])
        XCTAssertFalse(none.noHorizon)
        XCTAssertFalse(none.keepTempFiles)
        XCTAssertFalse(none.movingCamera)
        XCTAssertFalse(none.shouldWriteOutlierGroupFiles)
        XCTAssertFalse(none.shouldWriteOutlierClassificationValues)
        XCTAssertFalse(none.logOpMemory)

        let all = try StarCli.parse(["--no-horizon", "--keep-temp-files", "--moving-camera",
                                     "-w", "-W", "--log-op-memory", "/some/seq"])
        XCTAssertTrue(all.noHorizon)
        XCTAssertTrue(all.keepTempFiles)
        XCTAssertTrue(all.movingCamera)
        XCTAssertTrue(all.shouldWriteOutlierGroupFiles)
        XCTAssertTrue(all.shouldWriteOutlierClassificationValues)
        XCTAssertTrue(all.logOpMemory)
    }

    /// `-s` is the one flag with three states, because a resume has to be able to turn
    /// rendering back on as well as off.
    func testSkipOutputFilesHasAnOffFormAsWellAsAnOnOne() throws {
        XCTAssertNil(try StarCli.parse(["/some/seq"]).skipOutputFiles)
        XCTAssertEqual(try StarCli.parse(["-s", "/some/seq"]).skipOutputFiles, true)
        XCTAssertEqual(try StarCli.parse(["--skip-output-files", "/some/seq"]).skipOutputFiles, true)
        XCTAssertEqual(try StarCli.parse(["--no-skip-output-files", "/some/seq"]).skipOutputFiles,
                       false)
    }

    // MARK: - positional arguments

    func testTheSequenceDirnameIsTheFirstPositional() throws {
        XCTAssertEqual(try StarCli.parse(["/some/seq"]).imageSequenceDirname, "/some/seq")
    }

    func testTheOutputDirnameIsTheSecondPositionalAndIsOptional() throws {
        XCTAssertNil(try StarCli.parse(["/some/seq"]).finalOutputDirname)

        let both = try StarCli.parse(["/some/seq", "/some/output"])
        XCTAssertEqual(both.imageSequenceDirname, "/some/seq")
        XCTAssertEqual(both.finalOutputDirname, "/some/output")
    }

    /// `--version` has to work on its own, with no sequence to process.
    func testVersionParsesWithNoPositionalArguments() throws {
        let cli = try StarCli.parse(["--version"])
        XCTAssertTrue(cli.version)
        XCTAssertNil(cli.imageSequenceDirname)
    }

    func testAnUnknownFlagIsAUsageError() {
        parseFails(["--not-a-real-flag", "/some/seq"])
    }
}
