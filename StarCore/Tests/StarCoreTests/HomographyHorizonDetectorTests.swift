import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// `HomographyHorizonDetector` refines a frame's horizon from its neighbours in two passes: warp each
/// neighbour's horizon mask into this frame and take the per-column topmost result (Pass 1), then
/// warp each neighbour's *original* image, diff it against this frame, and find where the alignment
/// error jumps from sky to ground (Pass 2).  The two are combined per column, clamped, and optionally
/// snapped to a Canny edge.
///
/// The disk I/O and warping live in `prepare`, which is tested here against real files.
final class HomographyHorizonDetectorTests: FrameHarnessTestCase {

    /// Row-major 3x3 identity — a neighbour that needs no warping.
    private let identity: [Double] = [1, 0, 0,
                                      0, 1, 0,
                                      0, 0, 1]

    /// Row-major 3x3 pure vertical translation, positive `dy` moving content down.
    private func translation(dy: Double, dx: Double = 0) -> [Double] {
        [1, 0, dx,
         0, 1, dy,
         0, 0, 1]
    }

    // MARK: - apply

    /// `apply` is the documented route for a tuned `tuned_parameters.json` to reach the detector, so
    /// every field it claims to copy has to actually be copied — a missed one silently keeps the
    /// built-in default and the tuning is partly ignored.
    func testApplyCopiesEveryParameter() {
        var params = HorizonTunedParameters()
        params.smoothingRadius = 11
        params.errorSearchRange = 222
        params.errorBlurRadius = 3
        params.errorThresholdFactor = 4.5
        params.errorSampleHalfWidth = 77
        params.errorOutlierSigma = 1.25
        params.maxDownwardExtension = 42
        params.cannySnapRadius = 17
        params.cannyMinThreshold = 60
        params.cannyMaxThreshold = 190
        params.cannyFirstDetectedProximityRadius = 8

        var detector = HomographyHorizonDetector()
        detector.apply(params)

        XCTAssertEqual(detector.smoothingRadius, 11)
        XCTAssertEqual(detector.errorSearchRange, 222)
        XCTAssertEqual(detector.errorBlurRadius, 3)
        XCTAssertEqual(detector.errorThresholdFactor, 4.5)
        XCTAssertEqual(detector.errorSampleHalfWidth, 77)
        XCTAssertEqual(detector.errorOutlierSigma, 1.25)
        XCTAssertEqual(detector.maxDownwardExtension, 42)
        XCTAssertEqual(detector.cannySnapRadius, 17)
        XCTAssertEqual(detector.cannyMinThreshold, 60)
        XCTAssertEqual(detector.cannyMaxThreshold, 190)
        XCTAssertEqual(detector.cannyFirstDetectedProximityRadius, 8)
    }

    /// **The two default sets disagree on `cannySnapRadius`: the detector says 30, the persisted
    /// parameters say 0.**  Applying a default `HorizonTunedParameters` therefore turns the Canny snap
    /// *off*, and `tuneDetector` writes back only 5 of the 11 fields, so a saved file carries this
    /// zero for the other six regardless of what the tuner found.
    ///
    /// Latent rather than live: `apply` currently has no callers anywhere in the repo, so the
    /// persisted tuning never actually reaches the detector — which is its own gap, since
    /// `HorizonTunedParameters`' documentation says the JSON is "loaded and applied before running the
    /// detector".  Pinned so that whoever wires it up sees the snap default flip first.
    func testTheTwoDefaultSetsDisagreeOnTheCannySnapRadius() {
        let detectorDefault = HomographyHorizonDetector()
        let paramsDefault = HorizonTunedParameters()

        XCTAssertEqual(detectorDefault.cannySnapRadius, 30)
        XCTAssertEqual(paramsDefault.cannySnapRadius, 0)

        var applied = HomographyHorizonDetector()
        applied.apply(paramsDefault)
        XCTAssertEqual(applied.cannySnapRadius, 0,
                       "applying defaults disables a step that was on by default")

        // every other field does agree, which is what makes this one look accidental
        XCTAssertEqual(detectorDefault.smoothingRadius, paramsDefault.smoothingRadius)
        XCTAssertEqual(detectorDefault.errorSearchRange, paramsDefault.errorSearchRange)
        XCTAssertEqual(detectorDefault.errorBlurRadius, paramsDefault.errorBlurRadius)
        XCTAssertEqual(detectorDefault.errorThresholdFactor, paramsDefault.errorThresholdFactor)
        XCTAssertEqual(detectorDefault.errorSampleHalfWidth, paramsDefault.errorSampleHalfWidth)
        XCTAssertEqual(detectorDefault.errorOutlierSigma, paramsDefault.errorOutlierSigma)
        XCTAssertEqual(detectorDefault.maxDownwardExtension, paramsDefault.maxDownwardExtension)
        XCTAssertEqual(detectorDefault.cannyMinThreshold, paramsDefault.cannyMinThreshold)
        XCTAssertEqual(detectorDefault.cannyMaxThreshold, paramsDefault.cannyMaxThreshold)
        XCTAssertEqual(detectorDefault.cannyFirstDetectedProximityRadius,
                       paramsDefault.cannyFirstDetectedProximityRadius)
    }

    /// A round trip through the JSON must survive, since that is how the tuning is persisted between
    /// runs.
    func testTunedParametersSurviveApplyAfterARoundTrip() throws {
        var original = HorizonTunedParameters()
        original.smoothingRadius = 33
        original.errorThresholdFactor = 1.75
        original.cannySnapRadius = 25

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(HorizonTunedParameters.self, from: data)

        var detector = HomographyHorizonDetector()
        detector.apply(decoded)
        XCTAssertEqual(detector.smoothingRadius, 33)
        XCTAssertEqual(detector.errorThresholdFactor, 1.75)
        XCTAssertEqual(detector.cannySnapRadius, 25)
    }

    // MARK: - score

    /// Mean absolute Y error against a reference — this is the objective the tuner minimises, so an
    /// error in it silently mis-tunes every sequence that has reference masks.
    func testTheScoreIsTheMeanAbsoluteError() {
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [10, 20, 30],
                                                       referenceY: [10, 20, 30]),
                       0, accuracy: 1e-12)
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [12, 18, 30],
                                                       referenceY: [10, 20, 30]),
                       (2 + 2 + 0) / 3.0, accuracy: 1e-12)
    }

    /// Absolute, so overshooting and undershooting cost the same.
    func testTheErrorIsAbsolute() {
        let over = HomographyHorizonDetector.score(algorithmY: [30], referenceY: [20])
        let under = HomographyHorizonDetector.score(algorithmY: [10], referenceY: [20])
        XCTAssertEqual(over, under, accuracy: 1e-12)
        XCTAssertEqual(over, 10, accuracy: 1e-12)
    }

    /// Only columns defined on both sides count, so a detector that finds fewer columns is not
    /// punished for the ones it skipped — worth knowing, since it means coverage is not part of this
    /// objective at all.
    func testOnlyColumnsDefinedOnBothSidesContribute() {
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [10, nil, nil, 40],
                                                       referenceY: [10, 20, 30, 44]),
                       (0 + 4) / 2.0, accuracy: 1e-12)
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [10, 20],
                                                       referenceY: [nil, 25]),
                       5, accuracy: 1e-12)
    }

    /// A single perfectly-matched column beats a fully-covered but slightly-off result, which is the
    /// consequence of the above and is why the tuner needs its guards elsewhere.
    func testASingleMatchingColumnScoresBetterThanBroadNearMisses() {
        let sparse = HomographyHorizonDetector.score(algorithmY: [30, nil, nil, nil],
                                                     referenceY: [30, 30, 30, 30])
        let broad = HomographyHorizonDetector.score(algorithmY: [31, 31, 31, 31],
                                                    referenceY: [30, 30, 30, 30])
        XCTAssertLessThan(sparse, broad)
        XCTAssertEqual(sparse, 0, accuracy: 1e-12)
    }

    /// Nothing comparable is infinitely bad, so any real candidate beats it in the tuner's `<`.
    func testNothingComparableScoresInfinity() {
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [], referenceY: []), .infinity)
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [nil, nil],
                                                       referenceY: [10, 20]), .infinity)
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [10, 20],
                                                       referenceY: [nil, nil]), .infinity)
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [10], referenceY: []), .infinity)
    }

    /// Mismatched lengths compare only the overlap rather than trapping, which matters because a mask
    /// and a reference can come from differently-scaled images.
    func testMismatchedLengthsCompareOnlyTheOverlap() {
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [10, 10, 10, 10, 10],
                                                       referenceY: [12, 12]),
                       2, accuracy: 1e-12)
        XCTAssertEqual(HomographyHorizonDetector.score(algorithmY: [10],
                                                       referenceY: [12, 99, 99]),
                       2, accuracy: 1e-12)
    }

    // MARK: - horizonYPerColumn

    /// Delegates to the shared extraction, so the same conventions hold — including that an all-ground
    /// column reads as 0 rather than nil.
    func testHorizonYPerColumnMatchesTheSharedExtraction() throws {
        let mask = try XCTUnwrap(HorizonMask(FrameHarness.syntheticMask(width: 40, height: 60) { x in
            20 + x / 4
        }))
        let viaDetector = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        let viaScoring = HorizonScoring.extractHorizonYPerColumn(from: mask.image)
        XCTAssertEqual(viaDetector, viaScoring)
        XCTAssertEqual(viaDetector[0], 20)
        XCTAssertEqual(viaDetector[39], 20 + 39 / 4)
    }

    // MARK: - prepare

    /// With no neighbour masks at all, Pass 1 has nothing to aggregate and every column is nil — the
    /// array still has to be the frame's width so the later per-column loops line up.
    func testPrepareWithNoNeighboursGivesAnAllNilPassOne() {
        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 64,
                                        currentHeight: 48,
                                        neighborHorizonFilenames: [],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [],
                                        neighborStarHomographies: [])
        XCTAssertEqual(prepared.currentWidth, 64)
        XCTAssertEqual(prepared.currentHeight, 48)
        XCTAssertEqual(prepared.pass1RawY.count, 64)
        XCTAssertTrue(prepared.pass1RawY.allSatisfy { $0 == nil })
        XCTAssertTrue(prepared.neighborHBlurred.isEmpty)
        XCTAssertNil(prepared.currentImage)
    }

    /// A single neighbour warped by the identity comes through unchanged, which is the baseline that
    /// makes the aggregation tests below meaningful.
    func testPrepareWarpsASingleNeighbourMaskThroughTheIdentity() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 48, named: "prep1")
        harness = h
        let maskPath = h.writeScratch(FrameHarness.flatMask(width: 64, height: 48, at: 24),
                                      named: "n0.tiff")

        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 64,
                                        currentHeight: 48,
                                        neighborHorizonFilenames: [maskPath],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [identity],
                                        neighborStarHomographies: [identity])

        XCTAssertEqual(prepared.pass1RawY.count, 64)
        let defined = prepared.pass1RawY.compactMap { $0 }
        XCTAssertEqual(defined.count, 64, "the identity warp must not lose any column")
        for y in defined {
            XCTAssertEqual(y, 24, accuracy: 1, "the horizon must come back where it went in")
        }
    }

    /// Pass 1 aggregates by per-column **minimum**, not median — deliberately, so a single neighbour
    /// that spotted a mountain peak propagates it rather than being outvoted.
    func testPassOneTakesThePerColumnMinimumAcrossNeighbours() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 96, named: "min")
        harness = h
        // three neighbours: two agree at 60, one sees ground much higher at 30
        let low1 = h.writeScratch(FrameHarness.flatMask(width: 64, height: 96, at: 60), named: "a.tiff")
        let low2 = h.writeScratch(FrameHarness.flatMask(width: 64, height: 96, at: 60), named: "b.tiff")
        let high = h.writeScratch(FrameHarness.flatMask(width: 64, height: 96, at: 30), named: "c.tiff")

        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 64,
                                        currentHeight: 96,
                                        neighborHorizonFilenames: [low1, low2, high],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [identity, identity, identity],
                                        neighborStarHomographies: [identity, identity, identity])

        let defined = prepared.pass1RawY.compactMap { $0 }
        XCTAssertFalse(defined.isEmpty)
        for y in defined {
            XCTAssertEqual(y, 30, accuracy: 1,
                           "the minority high horizon must win — a median would give 60")
        }
    }

    /// The homography is what puts a neighbour's mask into this frame's coordinates, so a translation
    /// has to actually move the horizon.
    func testAVerticalTranslationMovesTheWarpedHorizon() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 96, named: "warp")
        harness = h
        let maskPath = h.writeScratch(FrameHarness.flatMask(width: 64, height: 96, at: 40),
                                      named: "n.tiff")

        let detector = HomographyHorizonDetector()
        let shifted = detector.prepare(currentWidth: 64,
                                       currentHeight: 96,
                                       neighborHorizonFilenames: [maskPath],
                                       neighborOriginalFilenames: [],
                                       neighborEarthHomographies: [translation(dy: 12)],
                                        neighborStarHomographies: [translation(dy: 12)])

        let defined = shifted.pass1RawY.compactMap { $0 }
        XCTAssertFalse(defined.isEmpty, "the warp must not empty the mask")
        let mean = Double(defined.reduce(0, +)) / Double(defined.count)
        XCTAssertEqual(mean, 52, accuracy: 2,
                       "a +12 row translation must move a horizon at 40 to about 52")
    }

    /// A neighbour whose file is missing is skipped rather than aborting the pass — one unreadable
    /// mask must not cost the frame its whole Pass 1.
    func testAnUnreadableNeighbourIsSkipped() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "missing")
        harness = h
        let good = h.writeScratch(FrameHarness.flatMask(width: 32, height: 32, at: 16),
                                  named: "good.tiff")

        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(
          currentWidth: 32,
          currentHeight: 32,
          neighborHorizonFilenames: ["/nonexistent/path/nope.tiff", good],
          neighborOriginalFilenames: [],
          neighborEarthHomographies: [identity, identity],
                                        neighborStarHomographies: [identity, identity])

        XCTAssertFalse(prepared.pass1RawY.compactMap { $0 }.isEmpty,
                       "the readable neighbour must still contribute")
    }

    /// Every neighbour unreadable is the same as no neighbours: all nil, not a crash.
    func testAllNeighboursUnreadableGivesAllNil() {
        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 16,
                                        currentHeight: 16,
                                        neighborHorizonFilenames: ["/nope/a.tiff", "/nope/b.tiff"],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [identity, identity],
                                        neighborStarHomographies: [identity, identity])
        XCTAssertEqual(prepared.pass1RawY.count, 16)
        XCTAssertTrue(prepared.pass1RawY.allSatisfy { $0 == nil })
    }

    /// Filenames and homographies are zipped, so a short homography list silently drops the extra
    /// masks.  Pinned because a caller that miscounts loses neighbours without any error.
    func testFilenamesAndHomographiesAreZipped() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 64, named: "zip")
        harness = h
        let high = h.writeScratch(FrameHarness.flatMask(width: 32, height: 64, at: 10),
                                  named: "high.tiff")
        let low = h.writeScratch(FrameHarness.flatMask(width: 32, height: 64, at: 50),
                                 named: "low.tiff")

        let detector = HomographyHorizonDetector()
        // two masks but one homography: only the first is used
        let prepared = detector.prepare(currentWidth: 32,
                                        currentHeight: 64,
                                        neighborHorizonFilenames: [low, high],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [identity],
                                        neighborStarHomographies: [identity])
        let defined = prepared.pass1RawY.compactMap { $0 }
        XCTAssertFalse(defined.isEmpty)
        let mean = Double(defined.reduce(0, +)) / Double(defined.count)
        XCTAssertEqual(mean, 50, accuracy: 2,
                       "the second mask is dropped, so the high horizon never contributes")
    }

    /// Pass 2 only runs when the caller supplies the current image — without it there is nothing to
    /// diff the warped neighbours against.
    func testPassTwoIsSkippedWithoutTheCurrentImage() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 48, named: "nopass2")
        harness = h
        let filenames = await h.imageSequence.filenames

        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 64,
                                        currentHeight: 48,
                                        neighborHorizonFilenames: [],
                                        neighborOriginalFilenames: [filenames[1]],
                                        neighborEarthHomographies: [identity],
                                        neighborStarHomographies: [identity])
        XCTAssertTrue(prepared.neighborHBlurred.isEmpty,
                      "no current image means no error arrays to build")
    }

    /// With a current image and a neighbour original, Pass 2 builds one blurred error array per
    /// neighbour, sized height x width.
    func testPassTwoBuildsOneErrorArrayPerNeighbour() async throws {
        let h = try await FrameHarness.make(frameCount: 3, width: 64, height: 48, named: "pass2")
        harness = h
        let filenames = await h.imageSequence.filenames
        let current = try await h.imageSequence.getImage(withName: filenames[0]).image()

        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 64,
                                        currentHeight: 48,
                                        neighborHorizonFilenames: [],
                                        neighborOriginalFilenames: [filenames[1], filenames[2]],
                                        neighborEarthHomographies: [identity, identity],
                                        neighborStarHomographies: [identity, identity],
                                        currentImage: current)

        XCTAssertEqual(prepared.neighborHBlurred.count, 2)
        for array in prepared.neighborHBlurred {
            XCTAssertEqual(array.count, 48 * 64,
                           "the error array is one Float per pixel, row major")
            XCTAssertFalse(array.contains { $0.isNaN }, "the prefix-sum mean must never be NaN")
            XCTAssertTrue(array.allSatisfy { $0 >= 0 }, "an absolute difference cannot be negative")
        }
    }

    /// Diffing a frame against itself is all zeros, which is the sanity check that the error array
    /// really is an absolute difference and not something else.
    func testDiffingAFrameAgainstItselfGivesZeroError() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 48, height: 32, named: "selfdiff")
        harness = h
        let filenames = await h.imageSequence.filenames
        let current = try await h.imageSequence.getImage(withName: filenames[0]).image()

        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 48,
                                        currentHeight: 32,
                                        neighborHorizonFilenames: [],
                                        neighborOriginalFilenames: [filenames[0]],
                                        neighborEarthHomographies: [identity],
                                        neighborStarHomographies: [identity],
                                        currentImage: current)

        let array = try XCTUnwrap(prepared.neighborHBlurred.first)
        XCTAssertEqual(array.max() ?? -1, 0, accuracy: 1e-6,
                       "a frame differs from itself nowhere")
    }

    /// The sampling half-width is captured at `prepare` time and stored, because the tuner varies
    /// other parameters against a fixed prepared set — a mismatch would have the scan read a window it
    /// was not blurred for.
    func testTheSampleHalfWidthIsCapturedAtPrepareTime() {
        var detector = HomographyHorizonDetector()
        detector.errorSampleHalfWidth = 13
        let prepared = detector.prepare(currentWidth: 16,
                                        currentHeight: 16,
                                        neighborHorizonFilenames: [],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [],
                                        neighborStarHomographies: [])
        XCTAssertEqual(prepared.sampleHalfWidth, 13)

        // changing it afterwards must not retroactively change the prepared data
        detector.errorSampleHalfWidth = 99
        XCTAssertEqual(prepared.sampleHalfWidth, 13)
    }

    func testTheMergedHorizonAndCurrentImageAreCarriedThrough() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "carry")
        harness = h
        let filenames = await h.imageSequence.filenames
        let current = try await h.imageSequence.getImage(withName: filenames[0]).image()
        let merged: [Int?] = Array(repeating: 20, count: 32)

        let detector = HomographyHorizonDetector()
        let prepared = detector.prepare(currentWidth: 32,
                                        currentHeight: 32,
                                        neighborHorizonFilenames: [],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [],
                                        neighborStarHomographies: [],
                                        currentImage: current,
                                        currentMergedHorizonY: merged)
        XCTAssertEqual(prepared.currentMergedHorizonY, merged)
        XCTAssertNotNil(prepared.currentImage)
        XCTAssertEqual(prepared.currentImage?.width, 32)
    }
}
