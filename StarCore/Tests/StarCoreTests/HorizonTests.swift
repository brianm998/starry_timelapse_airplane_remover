import XCTest
import StarCppBridge
@testable import StarCore

/// The horizon stack decides which part of a frame is sky, which drives whether a frame is star
/// aligned or earth aligned and which outliers are even considered.  `Horizon.swift`,
/// `HorizonTunedParameters` and the mask extraction on `PixelatedImage` had no coverage.
///
/// Two kinds of test here.  The synthetic ones build an image with a known sky/ground boundary and
/// always run.  The ones at the bottom use the real sequences under `horizon_test_data` /
/// `small_horizon_test_data`, which carry a ground-truth `horizon.tiff` per sequence — those are
/// 4240x2832 16-bit frames at 72MB each, far too large to commit, so they `XCTSkip` when the
/// directories are not present rather than failing.
final class HorizonTests: XCTestCase {

    // MARK: - fixtures

    /// White above the boundary (sky), black below (ground) — the convention the codebase uses.
    private func mask(width: Int, height: Int, horizonAt: (Int) -> Int) -> PixelatedImage {
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for y in 0..<height {
            for x in 0..<width {
                data[y * width + x] = y < horizonAt(x) ? 255 : 0
            }
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8,
                                                       componentsPerPixel: 1),
                             bytesPerRow: width,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        return PixelatedImage(mat: mat)!
    }

    private func flatMask(width: Int, height: Int, at horizonY: Int) -> PixelatedImage {
        mask(width: width, height: height) { _ in horizonY }
    }

    private func intensity(_ image: PixelatedImage, x: Int, y: Int) -> UInt {
        image.intensity(atX: x, andY: y)
    }

    // MARK: - HorizonMask

    /// The mask is always normalised to single-channel 8-bit, because every OpenCV operation
    /// downstream requires it.  A three-channel 16-bit mask handed in has to come back converted.
    func testAHorizonMaskIsNormalisedToSingleChannelEightBit() throws {
        // a 16 bit three channel image standing in for something loaded off disk
        let width = 64, height = 48
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for y in 0..<height {
            for x in 0..<width {
                let v: UInt16 = y < 20 ? 65535 : 0
                for c in 0..<3 { data[(y * width + x) * 3 + c] = v }
            }
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 3),
                             bytesPerRow: width * 3 * 2,
                             data: UnsafeMutableRawPointer(data), takeOwnership: true)

        let horizon = try XCTUnwrap(HorizonMask(PixelatedImage(mat: mat)!))
        XCTAssertEqual(horizon.image.componentsPerPixel, 1)
        XCTAssertEqual(horizon.image.bitsPerComponent, 8)
        XCTAssertEqual(horizon.image.width, width)
        XCTAssertEqual(horizon.image.height, height)
    }

    /// The explicit initializer normalises too, and keeps the bounds it was handed rather than
    /// recomputing them.
    func testTheExplicitInitializerKeepsTheBoundsItWasGiven() {
        let horizon = HorizonMask(image: flatMask(width: 32, height: 32, at: 10),
                                  horizonTopY: 12, horizonBottomY: 8)
        XCTAssertEqual(horizon.horizonTopY, 12)
        XCTAssertEqual(horizon.horizonBottomY, 8)
        XCTAssertEqual(horizon.image.componentsPerPixel, 1)
        XCTAssertEqual(horizon.image.bitsPerComponent, 8)
    }

    /// `bounds` is just the two stored values in a struct, which is what the alignment code passes
    /// around.  Worth pinning because the field names are documented as being the wrong way round —
    /// `horizonTopY` "is the bottom".
    func testBoundsCarriesTheTwoStoredValues() {
        let horizon = HorizonMask(image: flatMask(width: 16, height: 16, at: 8),
                                  horizonTopY: 9, horizonBottomY: 7)
        XCTAssertEqual(horizon.bounds.topY, 9)
        XCTAssertEqual(horizon.bounds.bottomY, 7)
    }

    /// A flat horizon puts both extents at the boundary — the simplest case the extraction has to
    /// get right.
    func testAFlatHorizonHasBothExtentsAtTheBoundary() throws {
        let horizon = try XCTUnwrap(HorizonMask(flatMask(width: 200, height: 120, at: 60)))
        XCTAssertEqual(Double(horizon.horizonTopY), 60, accuracy: 2,
                       "topY was \(horizon.horizonTopY)")
        XCTAssertEqual(Double(horizon.horizonBottomY), 60, accuracy: 2,
                       "bottomY was \(horizon.horizonBottomY)")
    }

    /// A sloped horizon spans a range of rows, and the two extents should bracket it.
    func testASlopedHorizonSpansARangeOfRows() throws {
        // rises from y = 30 on the left to y = 90 on the right
        let sloped = mask(width: 200, height: 120) { x in 30 + (x * 60) / 200 }
        let horizon = try XCTUnwrap(HorizonMask(sloped))

        let low = min(horizon.horizonTopY, horizon.horizonBottomY)
        let high = max(horizon.horizonTopY, horizon.horizonBottomY)
        XCTAssertLessThan(high - low, 120, "the extents should be inside the frame")
        XCTAssertGreaterThan(high - low, 20,
                             "a horizon spanning sixty rows should show a range, got \(low)...\(high)")
    }

    /// A normal horizon reports the two rows straddling the boundary, which is what makes the
    /// documented "these names are swapped" comment concrete: `horizonTopY` is the first ground row
    /// and `horizonBottomY` is the last sky row, so topY is one *greater* than bottomY.
    func testTheTwoExtentsStraddleTheBoundaryWithTopBelowBottom() throws {
        let bounds = try XCTUnwrap(flatMask(width: 64, height: 64, at: 30).horizonBounds())
        XCTAssertEqual(bounds.topY, 30, "topY is the first ground row")
        XCTAssertEqual(bounds.bottomY, 29, "bottomY is the last sky row")
        XCTAssertGreaterThan(bounds.topY, bounds.bottomY,
                             "topY being the larger number is the naming quirk, not a bug")
    }

    /// A mask with no horizon in it reports -1 for whichever edge was not found — and `init?` does
    /// *not* reject that.  It only checks that `horizonBounds()` returned something, not that
    /// anything was found, so a frame with no visible horizon yields a HorizonMask carrying a -1.
    ///
    /// Pinned rather than fixed: -1 is a deliberate sentinel on the C++ side, and whether a caller
    /// wants a nil mask or a sentinel depends on the horizon flow — 2661 lines of
    /// FrameHorizonProcessor, still the largest uncovered file here.  Anything indexing rows with
    /// these needs to check for -1 first.
    func testAMaskWithNoHorizonReportsMinusOneAndIsStillConstructed() throws {
        let allGround = try XCTUnwrap(flatMask(width: 64, height: 64, at: 0).horizonBounds())
        XCTAssertEqual(allGround.topY, 0)
        XCTAssertEqual(allGround.bottomY, -1, "no sky was found, so bottomY is the sentinel")

        let allSky = try XCTUnwrap(flatMask(width: 64, height: 64, at: 64).horizonBounds())
        XCTAssertEqual(allSky.topY, -1, "no ground was found, so topY is the sentinel")
        XCTAssertEqual(allSky.bottomY, 63)

        // and neither is rejected by the failable initializer
        XCTAssertNotNil(HorizonMask(flatMask(width: 64, height: 64, at: 0)))
        XCTAssertNotNil(HorizonMask(flatMask(width: 64, height: 64, at: 64)))
    }

    // MARK: - sky and ground extraction

    /// These two are not the complementary pair their names suggest, and the difference matters
    /// before using either.
    ///
    /// `skyOnly` thresholds at 127, runs connected components, and keeps the components touching the
    /// *top* row — so it returns white where the sky is.
    ///
    /// `groundOnly` does the same from the *bottom* row, and then returns
    /// `bitwise_not(groundMask)` — white everywhere the ground is *not*.  Despite the name it is not
    /// a ground mask; it is a horizon mask with any dark region not connected to the bottom removed,
    /// which is exactly how both of its callers use it (`(try? ...) ?? original`, then treated as a
    /// horizon mask).  So on a clean two-region mask the two functions return roughly the *same*
    /// thing rather than opposites.
    func testSkyOnlyKeepsTheSkyConnectedToTheTop() throws {
        let source = flatMask(width: 80, height: 60, at: 30)
        let sky = try source.skyOnly()

        XCTAssertEqual(sky.width, 80)
        XCTAssertEqual(sky.height, 60)
        XCTAssertGreaterThan(intensity(sky, x: 40, y: 5), 0, "the top of the frame is sky")
        XCTAssertEqual(intensity(sky, x: 40, y: 55), 0, "the bottom is not")
    }

    /// A bright patch down in the ground is not connected to the top, so `skyOnly` drops it — that
    /// is the whole point of the connected-component step.
    func testSkyOnlyDropsABrightPatchStrandedInTheGround() throws {
        let source = mask(width: 80, height: 60) { _ in 30 }
        // paint a lit island at the bottom, disconnected from the sky
        let withIsland = try XCTUnwrap(PixelatedImage(mat: source.mat.clone()))
        guard case .eightBit(let buffer) = withIsland.imageData else {
            return XCTFail("expected 8 bit data")
        }
        let writable = UnsafeMutablePointer(mutating: buffer.baseAddress!)
        for y in 50..<55 { for x in 10..<20 { writable[y * 80 + x] = 255 } }

        let sky = try withIsland.skyOnly()
        XCTAssertGreaterThan(intensity(sky, x: 40, y: 5), 0, "the real sky survives")
        XCTAssertEqual(intensity(sky, x: 15, y: 52), 0,
                       "an island not connected to the top is not sky")
    }

    /// `groundOnly` returns the inverse of the ground, so it is white where `skyOnly` is white.
    func testGroundOnlyReturnsTheInverseOfTheGroundNotTheGround() throws {
        let source = flatMask(width: 80, height: 60, at: 30)
        let ground = try source.groundOnly()

        XCTAssertGreaterThan(intensity(ground, x: 40, y: 5), 0,
                             "despite the name, this is white above the horizon")
        XCTAssertEqual(intensity(ground, x: 40, y: 55), 0, "and black over the ground")
    }

    /// Stated as the relationship, since it is the surprising part: on a clean mask the two agree
    /// rather than partitioning the frame.
    func testTheTwoFunctionsAgreeRatherThanPartitioningTheFrame() throws {
        let source = flatMask(width: 80, height: 60, at: 30)
        let sky = try source.skyOnly()
        let ground = try source.groundOnly()

        var agree = 0, sampled = 0
        for y in 0..<60 {
            for x in 0..<80 {
                sampled += 1
                if (intensity(sky, x: x, y: y) > 0) == (intensity(ground, x: x, y: y) > 0) {
                    agree += 1
                }
            }
        }
        XCTAssertGreaterThan(Double(agree) / Double(sampled), 0.95,
                             "only \(agree) of \(sampled) pixels agreed — if these are now "
                             + "complements, groundOnly's polarity was changed")
    }

    /// A 16 bit mask — what a reference horizon loaded straight off a tiff is — has to work.  Both
    /// functions used to threshold without converting depth and then hand a 16 bit Mat to
    /// cv::connectedComponentsWithStats, which requires CV_8UC1 and throws otherwise, so they
    /// returned nil.
    func testBothFunctionsHandleASixteenBitMask() throws {
        let width = 80, height = 60
        let count = width * height * 3
        let data = UnsafeMutablePointer<UInt16>.allocate(capacity: count)
        for y in 0..<height {
            for x in 0..<width {
                let v: UInt16 = y < 30 ? 65535 : 0
                for c in 0..<3 { data[(y * width + x) * 3 + c] = v }
            }
        }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 16,
                                                       componentsPerPixel: 3),
                             bytesPerRow: width * 3 * 2,
                             data: UnsafeMutableRawPointer(data), takeOwnership: true)
        let sixteenBit = PixelatedImage(mat: mat)!

        let sky = try sixteenBit.skyOnly()
        XCTAssertGreaterThan(intensity(sky, x: 40, y: 5), 0,
                             "a 16 bit mask should still find its sky")
        XCTAssertEqual(intensity(sky, x: 40, y: 55), 0)

        let ground = try sixteenBit.groundOnly()
        XCTAssertEqual(ground.width, width)
        XCTAssertEqual(ground.height, height)
    }

    /// Growing and shrinking the dark regions is how the mask is nudged to cover a little more or
    /// less ground.  They move the boundary in opposite directions and keep the frame size.
    func testGrowingAndShrinkingDarkRegionsMoveTheBoundaryOppositeWays() throws {
        let source = flatMask(width: 80, height: 60, at: 30)

        let grown = try source.growDarkRegions(by: 5)
        let shrunk = try source.shrinkDarkRegions(by: 5)

        XCTAssertEqual(grown.width, 80); XCTAssertEqual(grown.height, 60)
        XCTAssertEqual(shrunk.width, 80); XCTAssertEqual(shrunk.height, 60)

        func skyPixelCount(_ image: PixelatedImage) -> Int {
            var count = 0
            for y in 0..<60 { for x in 0..<80 where intensity(image, x: x, y: y) > 0 { count += 1 } }
            return count
        }

        let base = skyPixelCount(source)
        XCTAssertLessThan(skyPixelCount(grown), base,
                          "growing the dark region should leave less sky")
        XCTAssertGreaterThan(skyPixelCount(shrunk), base,
                             "shrinking it should leave more sky")
    }

    func testGrowingByZeroLeavesTheMaskAlone() throws {
        let source = flatMask(width: 40, height: 30, at: 15)
        let grown = try source.growDarkRegions(by: 0)
        for y in 0..<30 {
            for x in 0..<40 {
                XCTAssertEqual(intensity(grown, x: x, y: y), intensity(source, x: x, y: y),
                               "pixel [\(x), \(y)] moved")
            }
        }
    }

    // MARK: - HorizonBounds statistics

    /// The stats summarise a sequence's per-frame horizons, and the reference-horizon smoothing uses
    /// the median to decide which frames disagree with their neighbours.
    func testStatsOverASteadySequence() throws {
        let bounds = (0..<9).map { _ in HorizonBounds(topY: 100, bottomY: 90) }
        let stats = try XCTUnwrap(bounds.calculateStats())

        XCTAssertEqual(stats.avgTopY, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.avgBottomY, 90, accuracy: 1e-9)
        XCTAssertEqual(stats.medianTopY, 100, accuracy: 1e-9)
        XCTAssertEqual(stats.medianBottomY, 90, accuracy: 1e-9)
        XCTAssertEqual(stats.highestTopY, 100)
        XCTAssertEqual(stats.lowestBottomY, 90)
        XCTAssertEqual(stats.outlierCount, 0, "a steady sequence has no outliers")
    }

    func testStatsOfAnEmptySequenceIsNil() {
        XCTAssertNil([HorizonBounds]().calculateStats())
    }

    /// The median is what makes the smoothing robust, so it has to be the real median — including
    /// the two-element average on an even count.
    func testTheMedianIsTheMiddleValueAndAveragesOnAnEvenCount() throws {
        let odd = [10, 20, 90].map { HorizonBounds(topY: $0, bottomY: $0) }
        XCTAssertEqual(try XCTUnwrap(odd.calculateStats()).medianTopY, 20, accuracy: 1e-9)

        let even = [10, 20, 30, 100].map { HorizonBounds(topY: $0, bottomY: $0) }
        XCTAssertEqual(try XCTUnwrap(even.calculateStats()).medianTopY, 25, accuracy: 1e-9,
                       "an even count averages the middle two")
    }

    /// The average is dragged by a wild frame while the median is not — which is exactly why the
    /// smoothing uses the median.
    func testOneWildFrameMovesTheAverageButNotTheMedian() throws {
        var values = Array(repeating: 100, count: 10)
        values.append(5000)
        let bounds = values.map { HorizonBounds(topY: $0, bottomY: $0) }
        let stats = try XCTUnwrap(bounds.calculateStats())

        XCTAssertEqual(stats.medianTopY, 100, accuracy: 1e-9, "the median should hold")
        XCTAssertGreaterThan(stats.avgTopY, 400, "the average should be dragged upward")
    }

    /// Outliers are counted with the 1.5 IQR rule, and a wild frame has to be noticed — that count
    /// is what tells the caller the sequence's horizons disagree.
    func testAWildFrameIsCountedAsAnOutlier() throws {
        var values = Array(repeating: 100, count: 10)
        values.append(5000)
        let stats = try XCTUnwrap(values.map { HorizonBounds(topY: $0, bottomY: $0) }
                                        .calculateStats())
        XCTAssertGreaterThan(stats.outlierCount, 0, "the wild frame should have been flagged")
    }

    /// Fewer than four samples cannot have quartiles, so the rule declines rather than inventing
    /// outliers from a tiny sequence.
    func testAShortSequenceReportsNoOutliers() throws {
        for count in 1...3 {
            let bounds = (0..<count).map { HorizonBounds(topY: $0 * 1000, bottomY: 0) }
            XCTAssertEqual(try XCTUnwrap(bounds.calculateStats()).outlierCount, 0,
                           "\(count) samples should not produce outliers")
        }
    }

    /// `highestTopY` and `lowestBottomY` are the extremes across the sequence, and the naming is
    /// confusing enough to be worth pinning: they are a plain max and min.
    func testTheExtremesAreTheMaxTopAndMinBottom() throws {
        let bounds = [HorizonBounds(topY: 100, bottomY: 90),
                      HorizonBounds(topY: 300, bottomY: 40),
                      HorizonBounds(topY: 200, bottomY: 70)]
        let stats = try XCTUnwrap(bounds.calculateStats())
        XCTAssertEqual(stats.highestTopY, 300)
        XCTAssertEqual(stats.lowestBottomY, 40)
    }

    // MARK: - HorizonTunedParameters

    /// The tuned parameters are written next to a sequence and read back on a later run, so the
    /// round trip is a compatibility surface.
    func testTunedParametersRoundTripThroughADirectory() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuned-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        var params = HorizonTunedParameters()
        params.smoothingRadius = 77
        params.errorSearchRange = 123
        params.cannyMinThreshold = 12.5
        params.cannyMaxThreshold = 199.5
        params.maxDownwardExtension = 9
        params.tuningMeanAbsoluteError = 3.25
        params.tuningFrameCount = 42

        try params.save(toDirectory: dir)
        let loaded = try XCTUnwrap(HorizonTunedParameters.load(fromDirectory: dir))

        XCTAssertEqual(loaded.smoothingRadius, 77)
        XCTAssertEqual(loaded.errorSearchRange, 123)
        XCTAssertEqual(loaded.cannyMinThreshold, 12.5)
        XCTAssertEqual(loaded.cannyMaxThreshold, 199.5)
        XCTAssertEqual(loaded.maxDownwardExtension, 9)
        XCTAssertEqual(loaded.tuningMeanAbsoluteError, 3.25)
        XCTAssertEqual(loaded.tuningFrameCount, 42)
    }

    func testLoadingTunedParametersFromAnEmptyDirectoryIsNil() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuned-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertNil(HorizonTunedParameters.load(fromDirectory: dir))
    }

    func testTheTunedParametersFilenameIsStable() {
        XCTAssertEqual(HorizonTunedParameters.jsonFilename, "tuned_parameters.json")
    }

    /// The canny thresholds have to be the right way round, or the edge detector finds nothing.
    func testTheDefaultCannyThresholdsAreOrdered() {
        let params = HorizonTunedParameters()
        XCTAssertLessThan(params.cannyMinThreshold, params.cannyMaxThreshold)
        XCTAssertGreaterThan(params.cannyMinThreshold, 0)
    }

    func testTheDefaultsAreSaneAndNonNegative() {
        let params = HorizonTunedParameters()
        XCTAssertGreaterThan(params.smoothingRadius, 0)
        XCTAssertGreaterThan(params.errorSearchRange, 0)
        XCTAssertGreaterThan(params.errorBlurRadius, 0)
        XCTAssertGreaterThan(params.errorThresholdFactor, 0)
        XCTAssertGreaterThan(params.errorSampleHalfWidth, 0)
        XCTAssertGreaterThan(params.errorOutlierSigma, 0)
        XCTAssertGreaterThanOrEqual(params.maxDownwardExtension, 0)
        XCTAssertGreaterThanOrEqual(params.cannySnapRadius, 0)
        XCTAssertEqual(params.tuningFrameCount, 0, "an untuned set has no frames behind it")
        XCTAssertNil(params.tuningMeanAbsoluteError)
    }

    /// A parameter file written by an older version will be missing keys added since, and has to
    /// decode with defaults rather than failing — otherwise a tuned sequence stops loading.
    func testAnOlderParameterFileDecodesWithDefaultsForMissingKeys() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tuned-old-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // only one key, as an old file might have
        let json = #"{"smoothingRadius": 33}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent(HorizonTunedParameters.jsonFilename))

        let loaded = try XCTUnwrap(HorizonTunedParameters.load(fromDirectory: dir),
                                  "an old parameter file should still load")
        XCTAssertEqual(loaded.smoothingRadius, 33)
        XCTAssertEqual(loaded.cannyMinThreshold, HorizonTunedParameters().cannyMinThreshold,
                       "a missing key should fall back to the default")
    }

    // MARK: - the real sequences

    /// The sequences under these directories carry a ground-truth `horizon.tiff` per stationary
    /// sequence, which is what `horizon_test_bench` scores against.  They are not in the repo — the
    /// frames are 4240x2832 16-bit at 72MB each — so these skip when absent.
    private func realSequenceDirectory() -> URL? {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()    // StarCoreTests
            .deletingLastPathComponent()    // Tests
            .deletingLastPathComponent()    // StarCore
            .deletingLastPathComponent()    // repo root

        for name in ["small_horizon_test_data", "horizon_test_data"] {
            let stationary = root.appendingPathComponent(name).appendingPathComponent("stationary")
            guard let entries = try? FileManager.default.contentsOfDirectory(
                    at: stationary, includingPropertiesForKeys: nil) else { continue }
            for sequence in entries {
                let mask = sequence.appendingPathComponent("horizon.tiff")
                if FileManager.default.fileExists(atPath: mask.path) { return sequence }
            }
        }
        return nil
    }

    private func requireRealSequence() throws -> URL {
        guard let dir = realSequenceDirectory() else {
            throw XCTSkip("no horizon test sequence found — these live in "
                          + "small_horizon_test_data/ or horizon_test_data/, which are not in the "
                          + "repo because the frames are 72MB each")
        }
        return dir
    }

    /// The ground-truth mask has to be something `HorizonMask` accepts and can find extents in.  If
    /// this fails on a real reference mask, the extraction is wrong rather than the fixture.
    func testARealReferenceMaskYieldsUsableExtents() throws {
        let sequence = try requireRealSequence()
        let maskPath = sequence.appendingPathComponent("horizon.tiff").path
        let reference = try XCTUnwrap(PixelatedImage(filename: maskPath),
                                     "could not load \(maskPath)")

        let horizon = try XCTUnwrap(HorizonMask(reference),
                                    "HorizonMask found no extents in a real reference mask")

        XCTAssertEqual(horizon.image.componentsPerPixel, 1)
        XCTAssertEqual(horizon.image.bitsPerComponent, 8)
        XCTAssertGreaterThan(horizon.horizonTopY, 0)
        XCTAssertLessThan(horizon.horizonTopY, reference.height)
        XCTAssertGreaterThan(horizon.horizonBottomY, 0)
        XCTAssertLessThan(horizon.horizonBottomY, reference.height)
    }

    /// The same relationship checked against imagery with a real, irregular horizon in it: the two
    /// functions largely agree rather than partitioning the frame, and both find some of each.
    func testARealReferenceMaskSplitsIntoSkyAndGround() throws {
        let sequence = try requireRealSequence()
        let reference = try XCTUnwrap(
          PixelatedImage(filename: sequence.appendingPathComponent("horizon.tiff").path))

        let sky = try reference.skyOnly()
        let ground = try reference.groundOnly()

        XCTAssertEqual(sky.width, reference.width)
        XCTAssertEqual(ground.height, reference.height)

        // sample a grid rather than every pixel — this is a 12 megapixel image
        var agree = 0, sampled = 0, skyCount = 0, litCount = 0
        for y in stride(from: 0, to: reference.height, by: 16) {
            for x in stride(from: 0, to: reference.width, by: 16) {
                let inSky = intensity(sky, x: x, y: y) > 0
                let notGround = intensity(ground, x: x, y: y) > 0
                sampled += 1
                if inSky == notGround { agree += 1 }
                if inSky { skyCount += 1 }
                if notGround { litCount += 1 }
            }
        }
        XCTAssertGreaterThan(sampled, 1000)
        XCTAssertGreaterThan(Double(agree) / Double(sampled), 0.9,
                             "only \(agree) of \(sampled) agreed on a real mask")
        XCTAssertGreaterThan(skyCount, 0, "a real frame should have some sky")
        XCTAssertLessThan(skyCount, sampled, "and some ground")
        XCTAssertGreaterThan(litCount, 0)
    }

    /// The reference mask is binary — the convention is white sky, black ground — so a real one
    /// should have almost no intermediate values once normalised.
    func testARealReferenceMaskIsEffectivelyBinary() throws {
        let sequence = try requireRealSequence()
        let reference = try XCTUnwrap(
          PixelatedImage(filename: sequence.appendingPathComponent("horizon.tiff").path))
        let normalised = try XCTUnwrap(reference.asHorizonMask)

        var midtones = 0, sampled = 0
        for y in stride(from: 0, to: normalised.height, by: 16) {
            for x in stride(from: 0, to: normalised.width, by: 16) {
                let value = intensity(normalised, x: x, y: y)
                sampled += 1
                if value > 16 && value < 239 { midtones += 1 }
            }
        }
        XCTAssertGreaterThan(sampled, 100)
        XCTAssertLessThan(Double(midtones) / Double(sampled), 0.05,
                          "\(midtones) of \(sampled) sampled pixels were midtones — the reference "
                          + "mask is not binary")
    }

    /// Every frame in a stationary sequence shares the one reference mask, so the mask has to match
    /// the frames' dimensions or the alignment code would index outside it.
    func testTheReferenceMaskMatchesItsFramesDimensions() throws {
        let sequence = try requireRealSequence()
        let reference = try XCTUnwrap(
          PixelatedImage(filename: sequence.appendingPathComponent("horizon.tiff").path))

        let frames = try FileManager.default.contentsOfDirectory(atPath: sequence.path)
            .filter { $0.hasSuffix(".tiff") || $0.hasSuffix(".tif") }
            .filter { !$0.hasPrefix("horizon") }
            .sorted()
        guard let first = frames.first else {
            throw XCTSkip("the sequence at \(sequence.path) has no frames beside its mask")
        }

        let frame = try XCTUnwrap(
          PixelatedImage(filename: sequence.appendingPathComponent(first).path))
        XCTAssertEqual(frame.width, reference.width,
                       "\(first) is \(frame.width) wide, the mask is \(reference.width)")
        XCTAssertEqual(frame.height, reference.height)
    }
}
