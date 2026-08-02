import XCTest
@testable import StarCore

/// The pre-flight disk check, and the estimate behind it.
///
/// Running out of disk halfway through a long sequence is a bad failure even now that it gets
/// reported: the frames written before it are fine, the ones after are missing, and the user
/// finds out an hour in. Everything needed to see it coming is available before the run starts.
///
/// The estimate is only ever a warning, so the interesting property is not precision — it is
/// that the arithmetic does not do anything absurd on the inputs it will actually meet.
final class DiskSpaceCheckTests: XCTestCase {

    private let gb: UInt64 = 1024 * 1024 * 1024

    // MARK: - The ratio

    /// Pinned against the measurement it came from: a 19-frame 4240×2832 sequence of 45.4MB
    /// produced 51.5MB of output (1.14×) and 135.7MB of temp (2.99×), so 4.13× at peak.
    ///
    /// If this is ever re-derived, it must stay above the output ratio alone — temp and output
    /// coexist during a run, so an estimate that only covered the output would pass a run that
    /// is going to fail.
    func testTheRatioCoversOutputAndTempTogether() {
        XCTAssertGreaterThan(DiskSpaceCheck.peakToInputRatio, 1.14,
                             "the estimate must cover more than the output alone")
        XCTAssertLessThanOrEqual(DiskSpaceCheck.peakToInputRatio, 4.2,
                                 "measured at 4.13×; much above that is a false-alarm machine")
    }

    // MARK: - Estimate arithmetic

    func testAnEstimateIsTheInputTimesTheRatio() {
        let estimate = DiskSpaceCheck.estimate(inputBytes: 10 * gb, availableBytes: 100 * gb)
        XCTAssertEqual(estimate.estimatedPeakBytes,
                       UInt64(Double(10 * gb) * DiskSpaceCheck.peakToInputRatio))
    }

    func testPlentyOfRoomFits() {
        let estimate = DiskSpaceCheck.estimate(inputBytes: 10 * gb, availableBytes: 500 * gb)
        XCTAssertTrue(estimate.fits)
        XCTAssertEqual(estimate.shortfallBytes, 0)
    }

    func testTooLittleRoomDoesNotFitAndReportsTheShortfall() {
        // 10GB of input needs ~40GB; only 15GB free.
        let estimate = DiskSpaceCheck.estimate(inputBytes: 10 * gb, availableBytes: 15 * gb)
        XCTAssertFalse(estimate.fits)
        XCTAssertEqual(estimate.shortfallBytes, estimate.estimatedPeakBytes - 15 * gb)
    }

    /// Exactly enough is enough. An off-by-one here would warn on every run that fits
    /// precisely, which is the case a user who has just freed space is most likely to hit.
    func testExactlyEnoughRoomFits() {
        let inputBytes = 10 * gb
        let needed = UInt64(Double(inputBytes) * DiskSpaceCheck.peakToInputRatio)
        let estimate = DiskSpaceCheck.estimate(inputBytes: inputBytes, availableBytes: needed)
        XCTAssertTrue(estimate.fits)
        XCTAssertEqual(estimate.shortfallBytes, 0)
    }

    /// `shortfallBytes` subtracts unsigned values, so the fits case has to be handled before
    /// the subtraction or it underflows to something enormous.
    func testTheShortfallDoesNotUnderflowWhenItFits() {
        let estimate = DiskSpaceCheck.estimate(inputBytes: 1, availableBytes: 900 * gb)
        XCTAssertEqual(estimate.shortfallBytes, 0)
    }

    /// A 500-frame 42MP sequence is a plausible real job and must not overflow the
    /// multiplication into nonsense.
    func testAVeryLargeSequenceDoesNotOverflow() {
        let inputBytes: UInt64 = 500 * 240 * 1024 * 1024      // ~117GB
        let estimate = DiskSpaceCheck.estimate(inputBytes: inputBytes, availableBytes: 100 * gb)
        XCTAssertGreaterThan(estimate.estimatedPeakBytes, inputBytes)
        XCTAssertFalse(estimate.fits)
    }

    // MARK: - Probing the filesystem

    func testTotalSizeAddsUpTheFilesItIsGiven() throws {
        let dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("disk-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var paths: [String] = []
        for (index, size) in [100, 250, 375].enumerated() {
            let url = dir.appendingPathComponent("f\(index).bin")
            try Data(repeating: 0, count: size).write(to: url)
            paths.append(url.path)
        }

        XCTAssertEqual(DiskSpaceCheck.totalSize(ofFiles: paths), 725)
    }

    /// A file that has gone missing contributes nothing rather than failing the whole check —
    /// the check exists to help, and it must never be the thing that stops a run.
    func testAMissingFileIsSkippedRatherThanFailing() {
        XCTAssertEqual(DiskSpaceCheck.totalSize(ofFiles: ["/nonexistent/a", "/nonexistent/b"]), 0)
    }

    /// The output directory usually does not exist yet when the check runs, so the probe has
    /// to walk up to a directory that does.
    func testFreeSpaceIsFoundForAPathThatDoesNotExistYet() {
        let notYet = FileManager.default.temporaryDirectory
          .appendingPathComponent("not-created-\(UUID().uuidString)")
          .appendingPathComponent("nor-this")
          .path
        let available = DiskSpaceCheck.availableBytes(forPath: notYet)
        XCTAssertNotNil(available)
        XCTAssertGreaterThan(available ?? 0, 0)
    }

    /// Walking up from a path with no existing ancestor must terminate.
    /// `deletingLastPathComponent` on "/" returns "/", so a naive loop spins forever.
    func testProbingAnAbsurdPathTerminates() {
        _ = DiskSpaceCheck.availableBytes(forPath: "/definitely/not/here/at/all")
    }

    /// An empty sequence has nothing to estimate from, and guessing would produce a warning
    /// about a run that writes nothing.
    func testAnEmptyInputListProducesNoEstimate() async {
        let result = await DiskSpaceCheck.check(inputFiles: [], outputPath: "/tmp")
        XCTAssertNil(result)
    }

    /// The real thing end to end against a real volume: the temp directory has some free
    /// space, and a handful of small files must fit in it.
    func testASmallSequenceFitsOnARealVolume() async throws {
        let dir = FileManager.default.temporaryDirectory
          .appendingPathComponent("disk-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("a.bin")
        try Data(repeating: 0, count: 1024).write(to: url)

        let estimate = await DiskSpaceCheck.check(inputFiles: [url.path],
                                                  outputPath: dir.path)
        XCTAssertNotNil(estimate)
        XCTAssertTrue(estimate?.fits ?? false)
    }
}
