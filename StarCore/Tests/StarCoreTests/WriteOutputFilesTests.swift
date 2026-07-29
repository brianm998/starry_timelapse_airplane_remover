import XCTest
@testable import StarCore

/// `Config.writeOutputFiles` is star's "outlier data only" mode, reached from the cli as
/// `--skip-output-files`. Until that flag was wired up, both callers of
/// `FrameAirplaneRemover` passed a literal `true`, so `writeOutputFiles == false` was dead
/// code for long enough to have rotted: of the three places a frame finishes by writing an
/// image, only two checked it.
///
/// The one that did not was the `.automatic(false)` branch of `finishAuto` — star's
/// default clean method — so the flag would have silently done nothing on a default run,
/// which is the same shape of bug as the flag not being read at all.
///
/// Driving a real frame through `finishAuto` needs an image sequence on disk and a built
/// frame graph, so what these tests pin is the structural property that broke: every exit
/// that writes an image consults the flag first. That is checked against the source, the
/// same way cli/Tests/starTests/ConfigOverridesTests.swift checks the properties it cannot
/// reach by running.
final class WriteOutputFilesTests: XCTestCase {

    // MARK: - the config field itself

    func testRenderingIsTheDefault() {
        XCTAssertTrue(Config().writeOutputFiles,
                      "star renders unless told not to; a false default would mean every "
                      + "run that never heard of this field stopped producing output")
    }

    /// The field has to survive config.json, or `--skip-output-files` would apply to the
    /// run that was given it and then quietly turn itself off on the next resume.
    func testItRoundTripsThroughJson() throws {
        var saved = Config()
        saved.writeOutputFiles = false

        let decoded = try JSONDecoder().decode(Config.self,
                                               from: try JSONEncoder().encode(saved))
        XCTAssertFalse(decoded.writeOutputFiles)
    }

    /// A config.json written before the field existed has to keep rendering rather than
    /// decode into "write nothing".
    func testAConfigThatNeverHeardOfItStillRenders() throws {
        let json = #"{"imageSequenceDirname":"seq","imageSequencePath":"/tmp"}"#
        let decoded = try JSONDecoder().decode(Config.self,
                                               from: Data(json.utf8))
        XCTAssertTrue(decoded.writeOutputFiles)
    }

    // MARK: - every image-writing exit is gated

    private func frameSource() throws -> String {
        // StarCore/Tests/StarCoreTests/ -> StarCore/Sources/StarCore/
        let starCore = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = starCore
            .appendingPathComponent("Sources/StarCore/FrameAirplaneRemover.swift")
        let source = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(source.contains("public func finishAuto"),
                      "did not find FrameAirplaneRemover.swift itself")
        return source
    }

    private let gate = "if !self.writeOutputFiles {"
    private let write = "imageAccessor.save("

    /// Within `source` from `start` onwards, the gate has to come before the first image
    /// write, and both have to be there at all.
    private func assertGatedFromOffset(
      _ start: String.Index,
      in source: String,
      _ what: String
    ) throws {
        let region = source[start...]
        let gateAt = try XCTUnwrap(region.range(of: gate)?.lowerBound,
                                   "\(what) never checks writeOutputFiles, so "
                                   + "--skip-output-files does nothing there")
        let writeAt = try XCTUnwrap(region.range(of: write)?.lowerBound,
                                    "no image write found after \(what); if that code "
                                    + "moved, this test is checking the wrong region")
        XCTAssertLessThan(gateAt, writeAt,
                          "\(what) writes an image before checking writeOutputFiles")
    }

    func testFinishSelectiveIsGated() throws {
        let source = try frameSource()
        let start = try XCTUnwrap(source.range(of: "public func finishSelective")?.upperBound)
        try assertGatedFromOffset(start, in: source, "finishSelective")
    }

    /// `.automatic(true)`: outliers are used, so the remove reasons and the classification
    /// CSV are written and then the render is skipped.
    func testFinishAutoIsGatedOnTheOutlierBranch() throws {
        let source = try frameSource()
        let start = try XCTUnwrap(source.range(of: "public func finishAuto")?.upperBound)
        try assertGatedFromOffset(start, in: source, "finishAuto's useOutliers branch")
    }

    /// `.automatic(false)`, the default clean method, and the one that was missing its
    /// gate. There is no outlier data in this mode, so `--skip-output-files` makes the run
    /// produce nothing — but "nothing" is what was asked for, and writing the image anyway
    /// is not.
    func testFinishAutoIsGatedOnTheDefaultCleanMethodBranch() throws {
        let source = try frameSource()
        let start = try XCTUnwrap(
          source.range(of: "} else if !autoAlreadyDone {")?.upperBound,
          "finishAuto's non-outlier branch has been restructured; find where "
          + ".automatic(false) writes its output image and check the gate is still ahead of it"
        )
        try assertGatedFromOffset(start, in: source, "finishAuto's .automatic(false) branch")
    }
}
