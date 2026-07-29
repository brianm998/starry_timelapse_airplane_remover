import XCTest
import StarCore
@testable import star

/// Tests for `-L`/`--last-frame`, which stops a run after a given frame index.
///
/// The flag was declared for a year without being wired to anything: it parsed, and then
/// nothing read it, so `star -L 9 seq/` processed the whole sequence and said nothing.
/// It is wired now that `FrameGraphBuilder` honors a partial range at every stage rather
/// than at the horizon and keypoint stages only.
///
/// It is deliberately *not* a `ConfigOverrides` field. Every override is written back into
/// the saved config, and an `@Option` has no `--no-` form, so a frame limit that reached
/// the config would cap every later resume with no way to clear it from the command line.
/// It travels as an argument to the single `processor.process(...)` call instead — which
/// is also what makes it apply to both input paths, since there is only one such call.
/// `ConfigOverridesTests.testTheLastFrameFlagIsNotAConfigOverride` guards the other half.
final class LastFrameTests: XCTestCase {

    // MARK: - parsing

    func testTheFlagParsesInBothItsForms() throws {
        XCTAssertEqual(try StarCli.parse(["-L", "9", "/some/seq"]).lastFrameIndex, 9)
        XCTAssertEqual(try StarCli.parse(["--last-frame", "9", "/some/seq"]).lastFrameIndex, 9)
        XCTAssertEqual(try StarCli.parse(["--last-frame=9", "/some/seq"]).lastFrameIndex, 9)
    }

    /// nil, not 0: absent has to mean "the whole sequence", and 0 means "just frame 0".
    func testAbsentIsNilRatherThanZero() throws {
        XCTAssertNil(try StarCli.parse(["/some/seq"]).lastFrameIndex)
    }

    /// 0 is a real value — process the first frame and nothing else.
    func testZeroIsALimitLikeAnyOther() throws {
        XCTAssertEqual(try StarCli.parse(["--last-frame=0", "/some/seq"]).lastFrameIndex, 0)
    }

    /// A negative limit selects no frames at all.  `FrameGraphBuilder` reports that and
    /// exits cleanly, but only after loading the whole sequence, so `validate()` rejects
    /// it up front as the usage error it is.
    func testANegativeLimitIsAUsageError() throws {
        XCTAssertThrowsError(try StarCli.parse(["--last-frame=-3", "/some/seq"])) { error in
            XCTAssertTrue("\(error)".contains("--last-frame"),
                          "the message should name the flag, got: \(error)")
        }
        XCTAssertThrowsError(try StarCli.parse(["--last-frame=-1", "/some/seq"]))
    }

    /// A limit past the end of the sequence is a clamp rather than an error — the run
    /// simply processes everything.  Nothing here knows the sequence length, so the
    /// clamping is `FrameGraphRange`'s (see `FrameGraphRangeTests`); what this pins is
    /// that the cli does not reject it first.
    func testALimitPastTheEndParsesFine() throws {
        XCTAssertEqual(try StarCli.parse(["--last-frame=999999", "/some/seq"]).lastFrameIndex,
                       999999)
    }

    // MARK: - where it is applied

    // `run()` needs a real image sequence on disk and then processes it, so which call
    // receives the flag is checked as the syntactic property it is — the same approach
    // `ConfigOverridesTests` takes for `--log-op-memory`.

    private func starCliSource() throws -> String {
        // cli/Tests/starTests/LastFrameTests.swift -> cli/Sources/star/StarCli.swift
        let cliDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: cliDir.appendingPathComponent("Sources/star/StarCli.swift"),
                               encoding: .utf8)
        XCTAssertTrue(source.contains("struct StarCli"), "did not find StarCli.swift itself")
        return source
    }

    private func offset(of needle: String, in source: String) throws -> Int {
        var found: [Int] = []
        var searchFrom = source.startIndex
        while let range = source.range(of: needle, range: searchFrom..<source.endIndex) {
            found.append(source.distance(from: source.startIndex, to: range.lowerBound))
            searchFrom = range.upperBound
        }
        XCTAssertEqual(found.count, 1, "expected exactly one '\(needle)' in StarCli.swift")
        return try XCTUnwrap(found.first)
    }

    /// The wiring itself: the one `process` call carries the flag.  Without this the flag
    /// goes back to parsing and doing nothing, which is the bug it had.
    func testTheFlagReachesTheProcessorAfterBothInputPaths() throws {
        let source = try starCliSource()

        let applied = try offset(of: "processor.process(endIndex: lastFrameIndex)", in: source)
        let sequenceBranch = try offset(of: "here we are processing a new image sequence",
                                       in: source)
        XCTAssertGreaterThan(applied, sequenceBranch,
                             "the process call has to sit after both input paths, so that a "
                             + "saved config resume gets the frame limit too")
    }

    /// And that the processor takes it, rather than the argument label happening to
    /// compile against something else.
    func testTheProcessorForwardsItToTheFrameGraph() throws {
        let cliDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(contentsOf: cliDir.appendingPathComponent("Sources/star/Processor.swift"),
                               encoding: .utf8)
        XCTAssertTrue(source.contains("func process(endIndex: Int? = nil)"),
                      "Processor.process no longer takes an endIndex")
        XCTAssertTrue(source.contains("endIndex: endIndex"),
                      "Processor.process does not pass its endIndex on to the frame graph, "
                      + "so the flag would parse and be dropped")
    }
}
