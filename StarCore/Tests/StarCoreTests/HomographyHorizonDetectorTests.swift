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
/// The split into `prepare` / `detectFromPrepared` exists so the coordinate-descent tuner can retry
/// many parameter sets without redoing the disk I/O and warping, which makes both halves testable:
/// `prepare` against real files, `detectFromPrepared` as pure array work.
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

    // MARK: - detectFromPrepared

    // MARK: - the two passes take different homographies

    /// Pass 1 moves a neighbour's *horizon* — a ground feature — so it must use the earth
    /// homography and must ignore the star one entirely.
    ///
    /// This was one shared parameter until 2026-08-30 and the only caller filled it with star
    /// homographies.  Measured on the aurora sequence's painted references, carrying one to the
    /// next: earth 3.0 px mean absolute error against star's 118.5 px, star as bad as 575 px.
    /// Pass 1 combines by per-column *minimum*, so an error that size does not average out —
    /// the most wrongly-lifted neighbour wins every column.
    func testPassOneUsesTheEarthHomographyAndNotTheStarOne() throws {
        let harnessDir = FileManager.default.temporaryDirectory
          .appendingPathComponent("HHDPassOne-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: harnessDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: harnessDir) }

        // One neighbour whose horizon sits at row 40.
        let maskPath = harnessDir.appendingPathComponent("neighbour.tiff").path
        let mask = try XCTUnwrap(PixelatedImage.fromHorizonColumnY(
                                   width: 64, height: 96,
                                   columnY: [Int?](repeating: 40, count: 64)))
        mask.mat.write(to: maskPath)

        let detector = HomographyHorizonDetector()
        let data = detector.prepare(
          currentWidth: 64, currentHeight: 96,
          neighborHorizonFilenames: [maskPath],
          neighborOriginalFilenames: [],
          neighborEarthHomographies: [translation(dy: 12)],
          neighborStarHomographies: [translation(dy: -30)])

        // 40 + 12 from the earth homography.  Taking the star one would land at 10, and taking
        // neither at 40 — three answers a test that passed the same array twice cannot tell apart.
        let landed = try XCTUnwrap(data.pass1RawY[32])
        XCTAssertEqual(landed, 52, accuracy: 2,
                       "the mask moved by the earth homography, not the star one")
    }

    /// And the converse: Pass 2 aligns *images* on the stars, so it must not be handed the earth
    /// homography.  With no originals to warp there is nothing for it to do, whatever it is given.
    func testPassTwoTakesTheStarHomographyAndProducesNothingWithoutOriginals() {
        let detector = HomographyHorizonDetector()
        let data = detector.prepare(
          currentWidth: 8, currentHeight: 8,
          neighborHorizonFilenames: [],
          neighborOriginalFilenames: [],
          neighborEarthHomographies: [identity],
          neighborStarHomographies: [identity])
        XCTAssertTrue(data.neighborHBlurred.isEmpty)
    }

    /// Building `PreparedData` directly is how the pure half gets tested without any I/O.
    private func prepared(width: Int,
                          height: Int,
                          pass1RawY: [Int?],
                          hBlurred: [[Float]] = [],
                          sampleHalfWidth: Int = 50,
                          mergedHorizonY: [Int?] = [],
                          currentImage: PixelatedImage? = nil)
      -> HomographyHorizonDetector.PreparedData
    {
        HomographyHorizonDetector.PreparedData(currentWidth: width,
                                               currentHeight: height,
                                               pass1RawY: pass1RawY,
                                               neighborHBlurred: hBlurred,
                                               sampleHalfWidth: sampleHalfWidth,
                                               currentMergedHorizonY: mergedHorizonY,
                                               currentImage: currentImage)
    }

    /// The output is a real binary mask at the requested size, in the codebase's white-is-sky
    /// convention, with the horizon where Pass 1 put it.
    func testPassOneAloneProducesAMaskAtTheHorizonItFound() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0        // no image supplied, so keep the snap out of it
        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 40, count: 64))

        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        XCTAssertEqual(mask.image.width, 64)
        XCTAssertEqual(mask.image.height, 96)
        XCTAssertEqual(mask.image.componentsPerPixel, 1)

        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        for x in stride(from: 0, to: 64, by: 8) {
            XCTAssertEqual(horizonY[x], 40, "column \(x)")
        }
    }

    /// An all-nil Pass 1 with no Pass 2 has no horizon to draw; the mask still has to come back rather
    /// than nil, because the caller treats nil as a failure.
    func testAnAllNilPassOneStillProducesAMask() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        let data = prepared(width: 32, height: 32,
                            pass1RawY: [Int?](repeating: nil, count: 32))
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        XCTAssertEqual(mask.image.width, 32)
        XCTAssertEqual(mask.image.height, 32)
    }

    /// Smoothing is a sliding-window mean over defined values, so a single wild column is pulled back
    /// toward its neighbours rather than surviving into the mask.
    func testSmoothingPullsAnOutlierColumnTowardItsNeighbours() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 10

        var raw: [Int?] = Array(repeating: 50, count: 101)
        raw[50] = 0                       // one column claiming the horizon is at the very top
        let mask = try XCTUnwrap(detector.detectFromPrepared(
                                  prepared(width: 101, height: 96, pass1RawY: raw)))
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        let atSpike = try XCTUnwrap(horizonY[50])
        XCTAssertGreaterThan(atSpike, 30, "the spike must be largely smoothed away")
        XCTAssertLessThan(atSpike, 50)
    }

    /// A zero radius disables smoothing entirely — the guard in `smooth`.  Pass 1's own radius is
    /// bypassed, though the final combine always applies a fixed radius of 10.
    func testAZeroSmoothingRadiusLeavesPassOneUntouched() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 0

        let raw: [Int?] = (0..<64).map { 30 + $0 % 4 }
        let mask = try XCTUnwrap(detector.detectFromPrepared(
                                  prepared(width: 64, height: 64, pass1RawY: raw)))
        XCTAssertEqual(mask.image.width, 64)
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        XCTAssertFalse(horizonY.compactMap { $0 }.isEmpty)
    }

    /// The ceiling clamp stops Pass 1's warped masks pushing the horizon below the frame's own merged
    /// baseline, which is what keeps buildings from being reclassified as sky on a moving camera.
    func testTheCeilingClampLimitsHowFarBelowTheMergedBaselineTheHorizonGoes() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 0
        detector.maxDownwardExtension = 5

        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 80, count: 64),      // deep into the ground
                            mergedHorizonY: Array(repeating: 40, count: 64)) // baseline much higher

        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        for x in stride(from: 0, to: 64, by: 8) {
            XCTAssertEqual(horizonY[x], 45,
                           "clamped to the baseline plus maxDownwardExtension, at column \(x)")
        }
    }

    /// Zero disables the clamp, which is the default.
    func testAZeroDownwardExtensionDisablesTheClamp() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 0
        detector.maxDownwardExtension = 0

        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 80, count: 64),
                            mergedHorizonY: Array(repeating: 40, count: 64))
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        XCTAssertEqual(horizonY[32], 80, "with the clamp off the horizon stays where Pass 1 put it")
    }

    /// The clamp is a ceiling, not a target: a horizon already above the baseline is left alone.
    func testTheClampDoesNotPushTheHorizonDownward() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 0
        detector.maxDownwardExtension = 5

        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 20, count: 64),
                            mergedHorizonY: Array(repeating: 60, count: 64))
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        XCTAssertEqual(horizonY[32], 20, "a horizon above the ceiling is untouched")
    }

    /// An empty merged baseline means there is nothing to clamp against, so the clamp is skipped even
    /// when enabled.
    func testTheClampIsSkippedWithoutAMergedBaseline() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 0
        detector.maxDownwardExtension = 5

        let data = prepared(width: 32, height: 96,
                            pass1RawY: Array(repeating: 80, count: 32),
                            mergedHorizonY: [])
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        XCTAssertEqual(horizonY[16], 80)
    }

    /// A merged baseline shorter than the frame clamps the columns it covers and leaves the rest, so a
    /// length mismatch degrades rather than trapping.
    func testAShortMergedBaselineOnlyClampsTheColumnsItCovers() throws {
        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 0
        detector.maxDownwardExtension = 5

        var merged = [Int?](repeating: 40, count: 16)
        merged.append(contentsOf: [Int?](repeating: nil, count: 0))
        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 80, count: 64),
                            mergedHorizonY: merged)
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)
        XCTAssertEqual(horizonY[0], 45, "covered columns are clamped")
        XCTAssertEqual(horizonY[40], 80, "uncovered columns are not")
    }

    /// The Canny snap moves the horizon onto a real intensity edge in the frame.  A synthetic frame
    /// with a hard sky/ground step gives Canny an unambiguous edge to find.
    func testTheCannySnapMovesTheHorizonOntoARealEdge() throws {
        var detector = HomographyHorizonDetector()
        detector.smoothingRadius = 0
        detector.cannySnapRadius = 20
        detector.cannyFirstDetectedProximityRadius = 0

        // a hard step: bright above row 48, dark below
        var rows: [Int: UInt8] = [:]
        for y in 0..<96 { rows[y] = y < 48 ? 240 : 10 }
        let image = FrameHarness.grayImage(width: 64, height: 96, rows: rows)

        // Pass 1 says 40, eight rows above the real edge and inside the snap radius
        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 40, count: 64),
                            currentImage: image)
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        let horizonY = HomographyHorizonDetector.horizonYPerColumn(in: mask)

        let snapped = try XCTUnwrap(horizonY[32])
        XCTAssertEqual(snapped, 48, accuracy: 2,
                       "the horizon must snap to the intensity step at row 48, not stay at 40")
    }

    /// A zero radius skips the snap entirely, which is what every test above relies on.
    func testAZeroSnapRadiusSkipsTheSnap() throws {
        var detector = HomographyHorizonDetector()
        detector.smoothingRadius = 0
        detector.cannySnapRadius = 0

        var rows: [Int: UInt8] = [:]
        for y in 0..<96 { rows[y] = y < 48 ? 240 : 10 }
        let image = FrameHarness.grayImage(width: 64, height: 96, rows: rows)

        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 40, count: 64),
                            currentImage: image)
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        XCTAssertEqual(HomographyHorizonDetector.horizonYPerColumn(in: mask)[32], 40,
                       "with the snap off the horizon stays where the passes put it")
    }

    /// An edge outside the snap band must not attract the horizon — that is what bounds the snap's
    /// damage when the passes are badly wrong.
    func testAnEdgeBeyondTheSnapRadiusIsIgnored() throws {
        var detector = HomographyHorizonDetector()
        detector.smoothingRadius = 0
        detector.cannySnapRadius = 3        // far too small to reach row 48 from row 20
        detector.cannyFirstDetectedProximityRadius = 0

        var rows: [Int: UInt8] = [:]
        for y in 0..<96 { rows[y] = y < 48 ? 240 : 10 }
        let image = FrameHarness.grayImage(width: 64, height: 96, rows: rows)

        let data = prepared(width: 64, height: 96,
                            pass1RawY: Array(repeating: 20, count: 64),
                            currentImage: image)
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        let snapped = try XCTUnwrap(HomographyHorizonDetector.horizonYPerColumn(in: mask)[32])
        XCTAssertLessThan(abs(snapped - 20), 5,
                          "an edge 28 rows away is outside a +/-3 band")
    }

    /// The snap needs an image; asking for it without one is a no-op rather than a crash.
    func testTheSnapIsSkippedWithoutACurrentImage() throws {
        var detector = HomographyHorizonDetector()
        detector.smoothingRadius = 0
        detector.cannySnapRadius = 30

        let data = prepared(width: 32, height: 64,
                            pass1RawY: Array(repeating: 30, count: 32))
        let mask = try XCTUnwrap(detector.detectFromPrepared(data))
        XCTAssertEqual(HomographyHorizonDetector.horizonYPerColumn(in: mask)[16], 30)
    }

    /// A `PreparedData` whose `pass1RawY` is shorter than `currentWidth` would index out of bounds in
    /// the Pass-1 smoothing if it were not sized from the array — this pins that the width and the
    /// array have to agree, which `prepare` guarantees.
    func testPreparedDataFromPrepareAlwaysSizesPassOneToTheWidth() {
        let detector = HomographyHorizonDetector()
        for width in [1, 7, 64, 100] {
            let data = detector.prepare(currentWidth: width,
                                        currentHeight: 32,
                                        neighborHorizonFilenames: [],
                                        neighborOriginalFilenames: [],
                                        neighborEarthHomographies: [],
                                        neighborStarHomographies: [])
            XCTAssertEqual(data.pass1RawY.count, width, "width \(width)")
        }
    }

    // MARK: - end to end through both stages

    /// `detect` is `prepare` followed by `detectFromPrepared`, so it must agree with calling them
    /// separately — the tuner relies on that equivalence to trust its own results.
    func testDetectMatchesTheTwoStagesCalledSeparately() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 96, named: "e2e")
        harness = h
        let maskPath = h.writeScratch(FrameHarness.flatMask(width: 64, height: 96, at: 44),
                                      named: "n.tiff")

        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0

        let combined = try XCTUnwrap(detector.detect(currentWidth: 64,
                                                     currentHeight: 96,
                                                     neighborHorizonFilenames: [maskPath],
                                                     neighborOriginalFilenames: [],
                                                     neighborEarthHomographies: [identity],
                                        neighborStarHomographies: [identity]))
        let staged = try XCTUnwrap(detector.detectFromPrepared(
                                    detector.prepare(currentWidth: 64,
                                                     currentHeight: 96,
                                                     neighborHorizonFilenames: [maskPath],
                                                     neighborOriginalFilenames: [],
                                                     neighborEarthHomographies: [identity],
                                        neighborStarHomographies: [identity])))

        XCTAssertEqual(HomographyHorizonDetector.horizonYPerColumn(in: combined),
                       HomographyHorizonDetector.horizonYPerColumn(in: staged))
    }

    /// The point of the two-stage split: one prepared set, many parameter configurations, and the
    /// parameters have to actually change the answer or the tuner is searching nothing.
    func testOnePreparedSetSupportsDifferentParameterConfigurations() throws {
        var raw: [Int?] = Array(repeating: 50, count: 101)
        raw[50] = 5
        let data = prepared(width: 101, height: 96, pass1RawY: raw)

        var unsmoothed = HomographyHorizonDetector()
        unsmoothed.cannySnapRadius = 0
        unsmoothed.smoothingRadius = 0

        var heavilySmoothed = HomographyHorizonDetector()
        heavilySmoothed.cannySnapRadius = 0
        heavilySmoothed.smoothingRadius = 40

        let a = try XCTUnwrap(unsmoothed.detectFromPrepared(data))
        let b = try XCTUnwrap(heavilySmoothed.detectFromPrepared(data))
        XCTAssertNotEqual(HomographyHorizonDetector.horizonYPerColumn(in: a),
                          HomographyHorizonDetector.horizonYPerColumn(in: b),
                          "the smoothing radius has to change the result")
    }

    /// The tuner's objective has to prefer a mask that matches the reference over one that does not —
    /// the composition of `prepare`, `detectFromPrepared`, `horizonYPerColumn` and `score`.
    func testTheTunerObjectivePrefersTheMaskMatchingTheReference() throws {
        let referenceY: [Int?] = Array(repeating: 44, count: 64)

        var detector = HomographyHorizonDetector()
        detector.cannySnapRadius = 0
        detector.smoothingRadius = 0

        let close = try XCTUnwrap(detector.detectFromPrepared(
                                   prepared(width: 64, height: 96,
                                            pass1RawY: Array(repeating: 44, count: 64))))
        let far = try XCTUnwrap(detector.detectFromPrepared(
                                 prepared(width: 64, height: 96,
                                          pass1RawY: Array(repeating: 70, count: 64))))

        let closeScore = HomographyHorizonDetector.score(
          algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: close),
          referenceY: referenceY)
        let farScore = HomographyHorizonDetector.score(
          algorithmY: HomographyHorizonDetector.horizonYPerColumn(in: far),
          referenceY: referenceY)

        XCTAssertLessThan(closeScore, farScore)
        XCTAssertEqual(closeScore, 0, accuracy: 1)
    }
}
