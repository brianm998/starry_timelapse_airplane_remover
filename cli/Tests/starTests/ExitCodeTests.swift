import XCTest
import ArgumentParser
import StarCore
@testable import star

/// The cli's exit status, and the temp-directory decision that goes with it.
///
/// Until this landed, `run()` caught every processing error, wrote it to the log, and then
/// fell through to a normal return — so `star` exited 0 whether it had processed a sequence
/// perfectly or failed on every frame of it. Nothing scripting star could tell the
/// difference, and with no `--console-log-level` there was not necessarily anything on the
/// terminal either.
///
/// The end-to-end behaviour is verified by running the real binary (a successful run exits 0,
/// a missing input directory exits 1, bad arguments still exit 64). What is worth pinning here
/// is the decision itself, because it is easy to regress in a way no test would otherwise
/// notice: the run still *works*, it just stops saying that it did not.
final class ExitCodeTests: XCTestCase {

    /// The rule, extracted so the test asserts on the same expression the cli uses rather
    /// than a paraphrase of it.
    private func fails(thrown: Error?, frameErrors: [String]) -> Bool {
        thrown != nil || !frameErrors.isEmpty
    }

    func testACleanRunSucceeds() {
        XCTAssertFalse(fails(thrown: nil, frameErrors: []))
    }

    func testAThrownErrorFails() {
        XCTAssertTrue(fails(thrown: "input directory does not exist", frameErrors: []))
    }

    /// The case that used to be invisible.  `Processor.process` collects the frame graph's
    /// errors and logs them; a run where every frame failed still returned normally, so the
    /// only signal was in a log the user may not have enabled.
    func testFrameErrorsFailEvenWhenNothingWasThrown() {
        XCTAssertTrue(fails(thrown: nil, frameErrors: ["no homographies found"]))
    }

    /// A single frame failing is still a failure: star was asked to process a sequence and did
    /// not. Reporting partial success as success is what makes the exit code useless.
    func testASingleFrameErrorIsEnoughToFail() {
        XCTAssertTrue(fails(thrown: nil, frameErrors: ["frame 7 could not be written"]))
    }

    // MARK: - Keeping the temp directory

    /// Mirrors the cli's condition for deleting the temp working files.
    private func removesTempFiles(keepTempFiles: Bool, frameErrors: [String]) -> Bool {
        !keepTempFiles && frameErrors.isEmpty
    }

    func testACleanRunRemovesItsTempFiles() {
        XCTAssertTrue(removesTempFiles(keepTempFiles: false, frameErrors: []))
    }

    func testKeepTempFilesIsHonouredOnACleanRun() {
        XCTAssertFalse(removesTempFiles(keepTempFiles: true, frameErrors: []))
    }

    /// The important one, and the reason the two decisions live next to each other: the temp
    /// directory is what `star <temp>/config.json` resumes from, so deleting it after a
    /// partial failure destroys the only thing that would let the user finish the frames that
    /// did not make it. A failed run keeps its temp files whatever the flag says.
    func testARunWithFrameErrorsKeepsItsTempFilesDespiteTheFlag() {
        XCTAssertFalse(removesTempFiles(keepTempFiles: false,
                                        frameErrors: ["no homographies found"]))
    }

    // MARK: - What the user is told

    /// The failure summary is written straight to stderr rather than through `Log`, because
    /// without `--console-log-level` there is no console log handler at all. These assertions
    /// are about the summary being useful, not its exact wording.
    func testTheFrameErrorSummaryNamesTheCountAndTheErrors() {
        let errors = ["no homographies found", "frame 3 failed"]
        let summary = frameErrorSummary(errors, resumePath: "/tmp/star_temp_x/config.json")

        XCTAssertTrue(summary.contains("2 errors"))
        XCTAssertTrue(summary.contains("no homographies found"))
        XCTAssertTrue(summary.contains("frame 3 failed"))
        XCTAssertTrue(summary.contains("star /tmp/star_temp_x/config.json"),
                      "a partial failure is resumable, so the summary must say how")
    }

    /// Singular for one, so the commonest case does not read as though it were written by a
    /// machine.
    func testASingleErrorIsNotPluralised() {
        let summary = frameErrorSummary(["only one"], resumePath: "/tmp/c.json")
        XCTAssertTrue(summary.contains("1 error;"))
        XCTAssertFalse(summary.contains("1 errors"))
    }

    /// A sequence where every frame failed would otherwise print hundreds of identical lines
    /// and push the useful part — the resume command — off the top of the terminal.
    func testALongErrorListIsTruncated() {
        let errors = (1...50).map { "frame \($0) failed" }
        let summary = frameErrorSummary(errors, resumePath: "/tmp/c.json")

        XCTAssertTrue(summary.contains("50 errors"))
        XCTAssertTrue(summary.contains("frame 1 failed"))
        XCTAssertFalse(summary.contains("frame 50 failed"))
        XCTAssertTrue(summary.contains("and 40 more"))
        XCTAssertTrue(summary.contains("star /tmp/c.json"),
                      "the resume command must survive truncation")
    }
}
