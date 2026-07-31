import XCTest
import Foundation
@testable import StarCore

/// `FrameHorizonProcessor` was the largest uncovered file in the repo — 2661 lines at 0.3% coverage.
/// It owns every horizon decision for a frame: which mask to use, whether a user-painted reference
/// overrides detection, how the painted view coordinates become image pixels, and what gets cached.
///
/// The user-facing path matters most here.  `saveHorizonReferenceMask` is what the horizon painter
/// calls when someone has hand-painted a skyline, and the loaders decide whether that painting is
/// honoured — so a fault in this file means either a user's work is silently ignored or the wrong
/// frame's horizon is applied to it.
///
/// Driven through `FrameHarness`, which supplies a real `FrameAirplaneRemover` with this processor
/// live on it.  Detection itself (`loadOrCreateHorizonMask` and the adaptive search) is deliberately
/// not exercised here: it is minutes of OpenCV per frame and is already covered at the algorithm level
/// by the detector suites.  What is covered is the orchestration around it.
final class FrameHorizonProcessorTests: FrameHarnessTestCase {

    private func processor(_ h: FrameHarness, at index: Int = 0) async -> FrameHorizonProcessor {
        await h.frames[index].horizonProcessor
    }

    // MARK: - fillEdgeNils

    /// The painter only produces values for columns the user actually painted, so the edges come back
    /// nil.  They are extrapolated outward rather than left undefined, because a horizon has to cover
    /// the full frame width for the mask to be usable.
    func testEdgeNilsAreFilledFromTheNearestDefinedValue() {
        let filled = FrameHorizonProcessor.fillEdgeNils([nil, nil, 10, 20, 30, nil, nil])
        XCTAssertEqual(filled, [10, 10, 10, 20, 30, 30, 30])
    }

    /// Interior gaps are deliberately left alone — only the leading and trailing runs are filled.
    func testInteriorGapsAreLeftAlone() {
        let filled = FrameHorizonProcessor.fillEdgeNils([nil, 5, nil, nil, 9, nil])
        XCTAssertEqual(filled, [5, 5, nil, nil, 9, 9])
    }

    func testAnArrayWithNoEdgeNilsIsUnchanged() {
        let input: [Int?] = [1, 2, 3]
        XCTAssertEqual(FrameHorizonProcessor.fillEdgeNils(input), input)
    }

    /// An all-nil array has nothing to extrapolate from, and must come back as-is rather than trapping
    /// on a missing first element.
    func testAnAllNilArrayIsReturnedUnchanged() {
        XCTAssertEqual(FrameHorizonProcessor.fillEdgeNils([nil, nil, nil]), [nil, nil, nil])
        XCTAssertEqual(FrameHorizonProcessor.fillEdgeNils([]), [])
    }

    /// A single defined column fills the whole array, which is what happens when the user paints one
    /// stroke.
    func testASingleDefinedColumnFillsEverything() {
        XCTAssertEqual(FrameHorizonProcessor.fillEdgeNils([nil, nil, 42, nil, nil]),
                       [42, 42, 42, 42, 42])
    }

    // MARK: - tuned parameters

    /// The tuning lives in `horizonReference/tuned_parameters.json`, beside the painted masks, so it
    /// survives a reprocess.  Round-tripping it through the processor is what a second run does.
    func testTunedParametersRoundTripThroughTheProcessor() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "tuned")
        harness = h
        let horizon = await processor(h)

        var params = HorizonTunedParameters()
        params.smoothingRadius = 37
        params.errorSearchRange = 250
        params.errorThresholdFactor = 1.5
        params.tuningMeanAbsoluteError = 4.25
        params.tuningFrameCount = 9

        try await horizon.saveTunedHorizonParameters(params)
        let loaded = await horizon.loadTunedHorizonParameters()

        XCTAssertEqual(loaded.smoothingRadius, 37)
        XCTAssertEqual(loaded.errorSearchRange, 250)
        XCTAssertEqual(loaded.errorThresholdFactor, 1.5)
        XCTAssertEqual(loaded.tuningMeanAbsoluteError, 4.25)
        XCTAssertEqual(loaded.tuningFrameCount, 9)
    }

    /// With nothing saved the defaults come back rather than nil, so a first run has usable values.
    func testAbsentTunedParametersGiveTheDefaults() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "notuned")
        harness = h
        let loaded = await processor(h).loadTunedHorizonParameters()
        XCTAssertEqual(loaded.smoothingRadius, HorizonTunedParameters().smoothingRadius)
        XCTAssertNil(loaded.tuningMeanAbsoluteError)
        XCTAssertEqual(loaded.tuningFrameCount, 0)
    }

    /// The file lands where the reference masks live, which is what makes it survive a reprocess —
    /// everything under `mergedHorizon/` is deleted on one.
    func testTheTunedParametersLandBesideTheReferenceMasks() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "tunedpath")
        harness = h
        try await processor(h).saveTunedHorizonParameters(HorizonTunedParameters())

        let (referenceDir, _) = try XCTUnwrap(h.horizonReferenceDirectory())
        let expected = referenceDir.appendingPathComponent(HorizonTunedParameters.jsonFilename)
        XCTAssertTrue(FileManager.default.fileExists(atPath: expected.path),
                      "expected tuning at \(expected.path)")
    }

    /// The whole sequence shares one tuning file, so every frame's processor sees the same values —
    /// that is the point, since the search is expensive and the answer is per-sequence.
    func testTheTuningIsSharedAcrossFrames() async throws {
        let h = try await FrameHarness.make(frameCount: 3, named: "tunedshared")
        harness = h

        var params = HorizonTunedParameters()
        params.smoothingRadius = 21
        try await processor(h, at: 0).saveTunedHorizonParameters(params)

        for index in 0..<3 {
            let loaded = try await processor(h, at: index).loadTunedHorizonParameters()
            XCTAssertEqual(loaded.smoothingRadius, 21, "frame \(index) did not see the tuning")
        }
    }

    // MARK: - saving a painted reference mask

    /// The core of the horizon painter: a painted per-column Y in view coordinates becomes a binary
    /// mask at full image resolution.
    func testAPaintedHorizonIsSavedAsAFullResolutionMask() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 96, named: "paint")
        harness = h
        let horizon = await processor(h)

        // the painter works in view coordinates, typically smaller than the image
        let viewWidth = 64, viewHeight = 48
        let painted = [Int?](repeating: 24, count: viewWidth)     // halfway down the view

        try await horizon.saveHorizonReferenceMask(paintedYPerColumn: painted,
                                                   viewWidth: viewWidth,
                                                   viewHeight: viewHeight)

        let (referenceDir, _) = try XCTUnwrap(h.horizonReferenceDirectory())
        let saved = referenceDir.appendingPathComponent("reference.tiff")
        let mask = try XCTUnwrap(PixelatedImage(filename: saved.path))
        XCTAssertEqual(mask.width, 128, "the mask must be at image resolution, not view resolution")
        XCTAssertEqual(mask.height, 96)

        // view row 24 of 48 is image row 48 of 96
        let horizonY = CombinedHorizonDetector.extractHorizonY(from: mask)
        let sample = try XCTUnwrap(horizonY[64])
        XCTAssertEqual(sample, 48, "the painted Y must scale into image coordinates")
    }

    /// A static sequence writes the shared `reference.tiff` *and* a per-frame marker, so the gui can
    /// show which frame was actually painted (green) versus which are inheriting it (blue).
    func testAStaticSequenceWritesBothTheGlobalReferenceAndAPerFrameMarker() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 48, named: "static")
        harness = h
        await h.updateConfig { $0.tripodHeadWasMoving = false }

        try await processor(h).saveHorizonReferenceMask(
          paintedYPerColumn: [Int?](repeating: 12, count: 32),
          viewWidth: 32, viewHeight: 24)

        let (referenceDir, frameFileName) = try XCTUnwrap(h.horizonReferenceDirectory())
        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: referenceDir.appendingPathComponent("reference.tiff").path),
                      "a static sequence shares one reference across frames")
        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: referenceDir.appendingPathComponent(frameFileName).path),
                      "and marks which frame was painted")
    }

    /// A moving sequence has a different horizon per frame, so there is no shared reference — only the
    /// per-frame file.  Writing a global one would apply one frame's skyline to the whole sequence.
    func testAMovingSequenceWritesOnlyThePerFrameReference() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 48, named: "moving")
        harness = h
        await h.updateConfig { $0.tripodHeadWasMoving = true }

        try await processor(h).saveHorizonReferenceMask(
          paintedYPerColumn: [Int?](repeating: 12, count: 32),
          viewWidth: 32, viewHeight: 24)

        let (referenceDir, frameFileName) = try XCTUnwrap(h.horizonReferenceDirectory())
        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: referenceDir.appendingPathComponent(frameFileName).path))
        XCTAssertFalse(FileManager.default.fileExists(
                         atPath: referenceDir.appendingPathComponent("reference.tiff").path),
                       "a moving sequence must not write a sequence-wide reference")
    }

    /// The painter leaves gaps where the user did not paint; they are linearly interpolated so the
    /// saved mask has a continuous skyline rather than steps.
    func testGapsBetweenPaintedColumnsAreLinearlyInterpolated() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "gaps")
        harness = h

        // painted at the two ends only, at different heights
        var painted = [Int?](repeating: nil, count: 64)
        painted[0] = 10
        painted[63] = 50

        try await processor(h).saveHorizonReferenceMask(paintedYPerColumn: painted,
                                                        viewWidth: 64, viewHeight: 64)

        let (referenceDir, _) = try XCTUnwrap(h.horizonReferenceDirectory())
        let mask = try XCTUnwrap(PixelatedImage(
                                  filename: referenceDir.appendingPathComponent("reference.tiff").path))
        let horizonY = CombinedHorizonDetector.extractHorizonY(from: mask)

        let start = try XCTUnwrap(horizonY[0])
        let middle = try XCTUnwrap(horizonY[32])
        let end = try XCTUnwrap(horizonY[63])
        XCTAssertEqual(start, 10, accuracy: 1)
        XCTAssertEqual(end, 50, accuracy: 1)
        XCTAssertEqual(middle, 30, accuracy: 2, "the midpoint must be interpolated, not stepped")
    }

    /// A painted array narrower than the image must not read past its end — the column mapping clamps.
    func testAPaintedArrayNarrowerThanTheImageIsClamped() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 96, named: "narrow")
        harness = h
        // deliberately mismatched: claims a 200-wide view but supplies 10 columns
        try await processor(h).saveHorizonReferenceMask(
          paintedYPerColumn: [Int?](repeating: 20, count: 10),
          viewWidth: 200, viewHeight: 96)

        let (referenceDir, _) = try XCTUnwrap(h.horizonReferenceDirectory())
        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: referenceDir.appendingPathComponent("reference.tiff").path),
                      "a mismatched painted array must still produce a mask rather than trapping")
    }

    // MARK: - loading a reference mask back

    /// The round trip the painter depends on: paint, save, reopen the tool, get the same line back.
    func testAPaintedReferenceReloadsAsTheSameViewHorizon() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 96, named: "roundtrip")
        harness = h
        let horizon = await processor(h)

        let viewWidth = 64, viewHeight = 48
        let painted: [Int?] = (0..<viewWidth).map { 20 + $0 / 8 }

        try await horizon.saveHorizonReferenceMask(paintedYPerColumn: painted,
                                                   viewWidth: viewWidth,
                                                   viewHeight: viewHeight)
        let reloadedOptional = try await horizon.loadExistingHorizonReferenceAsViewY(
                                 viewWidth: viewWidth, viewHeight: viewHeight)
        let reloaded = try XCTUnwrap(reloadedOptional)

        XCTAssertEqual(reloaded.count, viewWidth)
        for x in stride(from: 4, to: viewWidth - 4, by: 8) {
            let expected = try XCTUnwrap(painted[x])
            let actual = try XCTUnwrap(reloaded[x], "column \(x) came back undefined")
            XCTAssertEqual(actual, expected, accuracy: 2,
                           "column \(x) did not survive the round trip")
        }
    }

    /// With nothing painted there is nothing to pre-populate the painter with, and nil is how the gui
    /// knows to start from scratch.
    func testNoReferenceGivesNil() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "noref")
        harness = h
        let result = try await processor(h).loadExistingHorizonReferenceAsViewY(viewWidth: 64,
                                                                               viewHeight: 48)
        XCTAssertNil(result)
    }

    /// A frame's own painted reference wins over the sequence-wide one.  That ordering is what lets a
    /// user correct a single frame in an otherwise static sequence.
    func testAPerFrameReferenceBeatsTheGlobalOne() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "priority")
        harness = h

        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 50),
                                 perFrame: false)     // global says 50
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 20),
                                 perFrame: true)      // this frame says 20

        let loaded = try await processor(h).loadExistingHorizonReferenceAsViewY(viewWidth: 64,
                                                                            viewHeight: 64)
        let viewY = try XCTUnwrap(loaded)
        let sample = try XCTUnwrap(viewY[32])
        XCTAssertEqual(sample, 20, accuracy: 1, "the per-frame reference must take priority")
    }

    /// With only a global reference every frame uses it, which is the static-sequence case.
    func testAGlobalReferenceIsUsedWhenThereIsNoPerFrameOne() async throws {
        let h = try await FrameHarness.make(frameCount: 3, width: 64, height: 64, named: "global")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 40),
                                 perFrame: false)

        for index in 0..<3 {
            let loaded = try await processor(h, at: index)
                           .loadExistingHorizonReferenceAsViewY(viewWidth: 64, viewHeight: 64)
            let viewY = try XCTUnwrap(loaded)
            let sample = try XCTUnwrap(viewY[32], "frame \(index) found no horizon")
            XCTAssertEqual(sample, 40, accuracy: 1, "frame \(index)")
        }
    }

    /// The reference is planted for frame 0 only, so frame 1 must not pick it up as its own.
    func testAPerFrameReferenceDoesNotLeakToOtherFrames() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 64, named: "noleak")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 30),
                                 perFrame: true, frameIndex: 0)

        let frameZero = try await processor(h, at: 0)
                          .loadExistingHorizonReferenceAsViewY(viewWidth: 64, viewHeight: 64)
        let frameOne = try await processor(h, at: 1)
                         .loadExistingHorizonReferenceAsViewY(viewWidth: 64, viewHeight: 64)
        XCTAssertNotNil(frameZero)
        XCTAssertNil(frameOne,
                     "frame 1 has no reference of its own and there is no global one")
    }

    // MARK: - loadBestExistingHorizonAsViewY

    /// The documented search order, highest quality first: painted reference, then a cached merged
    /// horizon, then the raw one.  This is what the painter opens with, so the order decides what the
    /// user sees before touching anything.
    func testTheBestExistingHorizonPrefersTheReferenceThenMergedThenRaw() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "best")
        harness = h
        let horizon = await processor(h)

        // only a raw horizon exists
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 50), ofType: .horizon)
        var best = try await horizon.loadBestExistingHorizonAsViewY(viewWidth: 64, viewHeight: 64)
        var viewY = try XCTUnwrap(best)
        XCTAssertEqual(try XCTUnwrap(viewY[32]), 50, accuracy: 1, "falls back to the raw horizon")

        // a merged horizon outranks it
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 35),
                         ofType: .mergedHorizon)
        best = try await horizon.loadBestExistingHorizonAsViewY(viewWidth: 64, viewHeight: 64)
        viewY = try XCTUnwrap(best)
        XCTAssertEqual(try XCTUnwrap(viewY[32]), 35, accuracy: 1, "merged outranks raw")

        // and a painted reference outranks both
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 18),
                                 perFrame: true)
        best = try await horizon.loadBestExistingHorizonAsViewY(viewWidth: 64, viewHeight: 64)
        viewY = try XCTUnwrap(best)
        XCTAssertEqual(try XCTUnwrap(viewY[32]), 18, accuracy: 1,
                       "the user's own painting outranks everything")
    }

    /// Nothing on disk means nothing to show, and nil rather than an empty array is what the gui
    /// checks for.
    func testTheBestExistingHorizonIsNilWithNothingOnDisk() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "bestnone")
        harness = h
        let result = try await processor(h).loadBestExistingHorizonAsViewY(viewWidth: 64,
                                                                          viewHeight: 48)
        XCTAssertNil(result)
    }

    /// The view can be any size; the conversion scales both axes independently, which is what happens
    /// when the window is resized.
    func testTheHorizonScalesIntoWhateverViewSizeIsAsked() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 96, named: "scale")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 128, height: 96, at: 48),
                                 perFrame: true)
        let horizon = await processor(h)

        // half size: the horizon halves with it
        let halfOptional = try await horizon.loadBestExistingHorizonAsViewY(viewWidth: 64,
                                                                        viewHeight: 48)
        let half = try XCTUnwrap(halfOptional)
        XCTAssertEqual(half.count, 64)
        XCTAssertEqual(try XCTUnwrap(half[32]), 24, accuracy: 1)

        // double size: it doubles
        let doubleOptional = try await horizon.loadBestExistingHorizonAsViewY(viewWidth: 256,
                                                                          viewHeight: 192)
        let double = try XCTUnwrap(doubleOptional)
        XCTAssertEqual(double.count, 256)
        XCTAssertEqual(try XCTUnwrap(double[128]), 96, accuracy: 2)
    }

    /// A sloped reference has to keep its slope through the conversion, not be flattened to an average.
    func testASlopedReferenceKeepsItsSlopeInViewCoordinates() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 96, named: "slope")
        harness = h
        try h.plantReferenceMask(FrameHarness.syntheticMask(width: 128, height: 96) { x in
                                     20 + x / 4
                                 }, perFrame: true)

        let sloped = try await processor(h).loadBestExistingHorizonAsViewY(viewWidth: 128,
                                                                       viewHeight: 96)
        let viewY = try XCTUnwrap(sloped)
        let left = try XCTUnwrap(viewY[10])
        let right = try XCTUnwrap(viewY[110])
        XCTAssertGreaterThan(right, left + 15, "the slope must survive the conversion")
    }

    // MARK: - the merged horizon and the final mask cache

    /// A painted reference short-circuits the whole merge — that is what "the user's word is final"
    /// means here, and it is also why painting one is the fastest path through the pipeline.
    func testAReferenceMaskShortCircuitsTheMerge() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "shortcut")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 28),
                                 perFrame: true)

        let mergedOptional = try await processor(h).loadOrCreateMergedHorizonMask()
        let merged = try XCTUnwrap(mergedOptional)
        // topY is the first ground row, so it is the painted row itself
        XCTAssertEqual(merged.horizonTopY, 28)
        XCTAssertEqual(merged.horizonBottomY, 27)
    }

    /// An already-computed merged horizon on disk is loaded rather than recomputed, which is what
    /// makes a resumed run cheap.
    func testAnExistingMergedHorizonIsLoadedRatherThanRecomputed() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "reuse")
        harness = h
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 41),
                         ofType: .mergedHorizon)

        let mergedOptional = try await processor(h).loadOrCreateMergedHorizonMask()
        let merged = try XCTUnwrap(mergedOptional)
        XCTAssertEqual(merged.horizonTopY, 41,
                       "the cached merged horizon on disk must be used as-is")
    }

    /// The final mask is cached in memory for the life of the frame, because at 42MP it is a ~40MB
    /// plane and recomputing it is expensive.  Two calls must give the identical object.
    func testTheFinalHorizonMaskIsCached() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "cache")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 33),
                                 perFrame: true)
        let horizon = await processor(h)

        let firstOptional = try await horizon.loadOrCreateFinalHorizonMask()
        let first = try XCTUnwrap(firstOptional)
        let secondOptional = try await horizon.loadOrCreateFinalHorizonMask()
        let second = try XCTUnwrap(secondOptional)
        XCTAssertTrue(first.image === second.image,
                      "the second call must return the cached mask, not rebuild it")
    }

    /// Releasing the cache is how the memory is reclaimed; the mask has to rebuild from disk
    /// afterwards rather than coming back nil.
    func testReleasingTheCacheRebuildsFromDisk() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "release")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 33),
                                 perFrame: true)
        let horizon = await processor(h)

        let firstOptional = try await horizon.loadOrCreateFinalHorizonMask()
        let first = try XCTUnwrap(firstOptional)
        await horizon.releaseCachedFinalHorizonMask()
        let rebuiltOptional = try await horizon.loadOrCreateFinalHorizonMask()
        let rebuilt = try XCTUnwrap(rebuiltOptional)

        XCTAssertFalse(first.image === rebuilt.image, "the cache must actually have been dropped")
        XCTAssertEqual(rebuilt.horizonTopY, first.horizonTopY,
                       "and the rebuilt mask must be equivalent")
    }

    /// `recomputeMergedHorizon` is what the gui calls after the user edits a reference.  On a frame
    /// that *has* a reference there is nothing to recompute, and it must not throw.
    func testRecomputingWithAReferencePresentIsANoOp() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "recompute")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 30),
                                 perFrame: true)
        let horizon = await processor(h)

        try await horizon.recomputeMergedHorizon()
        let maskOptional = try await horizon.loadOrCreateFinalHorizonMask()
        let mask = try XCTUnwrap(maskOptional)
        XCTAssertEqual(mask.horizonTopY, 30, "the reference is still what gets served")
    }

    /// The conditional variant does nothing at all when no merged horizon has been computed yet, which
    /// is what keeps it cheap to call on every frame after a settings change.
    func testRecomputeIfExistsDoesNothingWithoutAMergedHorizon() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "ifexists")
        harness = h
        let horizon = await processor(h)

        try await horizon.recomputeMergedHorizonIfExists()

        let path = try XCTUnwrap(h.imageAccessor.nameForImage(frameIndex: 0,
                                                              ofType: .mergedHorizon,
                                                              atSize: .original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "nothing existed, so nothing should have been created")
    }

    // MARK: - deleteHorizonImages

    /// Deletion has to clear both types at both sizes, or a reprocess reuses a stale horizon.
    func testDeletingRemovesBothHorizonTypesAtOriginalSize() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64,
                                           writePreviews: true, named: "delete")
        harness = h

        let rawPath = try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 30),
                                       ofType: .horizon)
        let mergedPath = try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 32),
                                          ofType: .mergedHorizon)
        XCTAssertTrue(FileManager.default.fileExists(atPath: rawPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: mergedPath))

        await processor(h).deleteHorizonImages()

        XCTAssertFalse(FileManager.default.fileExists(atPath: rawPath),
                       "the raw horizon must be gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: mergedPath),
                       "the merged horizon must be gone")
    }

    /// Deleting when nothing is there must not throw — it runs on every frame of a reprocess.
    func testDeletingWithNothingPresentIsHarmless() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "deletenone")
        harness = h
        await processor(h).deleteHorizonImages()
    }

    /// Deletion must not touch the user's painted reference.  A reprocess deletes computed horizons;
    /// losing the painting would destroy work the user cannot regenerate.
    func testDeletingLeavesThePaintedReferenceAlone() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "keepref")
        harness = h
        let referencePath = try h.plantReferenceMask(
                                  FrameHarness.flatMask(width: 64, height: 64, at: 30),
                                  perFrame: true)
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 32),
                         ofType: .mergedHorizon)

        await processor(h).deleteHorizonImages()

        XCTAssertTrue(FileManager.default.fileExists(atPath: referencePath),
                      "the painted reference is not regenerable and must survive")
    }

    // MARK: - the horizon accumulator

    /// Static sequences accumulate every frame's detected horizon so the sequence can agree on one.
    /// The processor forwards into it, and with no accumulator registered — the moving-camera case —
    /// forwarding is a no-op rather than a crash.
    func testAccumulatingWithoutAnAccumulatorIsANoOp() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "noaccum")
        harness = h
        let mask = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 32, height: 32, at: 16)))
        await processor(h).accumulateDetectedHorizon(mask)
    }

    /// With one registered, the mask reaches it — and the accumulator's majority vote is what a
    /// static sequence's shared horizon is built from, so the vote itself is worth checking.
    func testARegisteredAccumulatorReceivesTheMaskAndVotes() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "accum")
        harness = h
        let horizon = await processor(h)

        // three frames voting: two say the horizon is at 16, one says 8
        let accumulator = HorizonAccumulator(frameCount: 3)
        await horizon.setHorizonAccumulator(accumulator)

        let atSixteen = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 32, height: 32,
                                                                       at: 16)))
        await horizon.accumulateDetectedHorizon(atSixteen)   // frame 0, via the processor
        await accumulator.accumulate(image: FrameHarness.flatMask(width: 32, height: 32, at: 16),
                                    frameIndex: 1)
        await accumulator.accumulate(image: FrameHarness.flatMask(width: 32, height: 32, at: 8),
                                    frameIndex: 2)

        let votedOptional = await accumulator.finalize { _ in nil }
        let voted = try XCTUnwrap(votedOptional, "three accumulated masks must finalize")
        let horizonY = CombinedHorizonDetector.extractHorizonY(from: voted)
        let sample = try XCTUnwrap(horizonY[16])
        XCTAssertEqual(sample, 16, accuracy: 1,
                       "the majority of 16, 16, 8 is 16 — the outlier must not win")
    }

    /// Accumulating the same frame twice must not let it vote twice; the guard is what makes the call
    /// safe to make from a retried detection.
    func testAccumulatingAFrameTwiceOnlyCountsItOnce() async throws {
        let accumulator = HorizonAccumulator(frameCount: 3)
        // frame 0 votes for 8, twice; frames 1 and 2 vote for 24
        await accumulator.accumulate(image: FrameHarness.flatMask(width: 32, height: 32, at: 8),
                                    frameIndex: 0)
        await accumulator.accumulate(image: FrameHarness.flatMask(width: 32, height: 32, at: 8),
                                    frameIndex: 0)
        await accumulator.accumulate(image: FrameHarness.flatMask(width: 32, height: 32, at: 24),
                                    frameIndex: 1)
        await accumulator.accumulate(image: FrameHarness.flatMask(width: 32, height: 32, at: 24),
                                    frameIndex: 2)

        let votedOptional = await accumulator.finalize { _ in nil }
        let voted = try XCTUnwrap(votedOptional)
        let sample = try XCTUnwrap(CombinedHorizonDetector.extractHorizonY(from: voted)[16])
        XCTAssertEqual(sample, 24, accuracy: 1,
                       "a double-counted frame 0 would have swung the vote to 8")
    }

    /// An out-of-range index is ignored rather than trapping on the `accumulated` array.
    func testAnOutOfRangeFrameIndexIsIgnored() async throws {
        let accumulator = HorizonAccumulator(frameCount: 2)
        let mask = FrameHarness.flatMask(width: 16, height: 16, at: 8)
        await accumulator.accumulate(image: mask, frameIndex: -1)
        await accumulator.accumulate(image: mask, frameIndex: 99)
        let nothing = await accumulator.finalize { _ in nil }
        XCTAssertNil(nothing, "neither out-of-range mask may have been accumulated")
    }

    /// Nothing accumulated and nothing loadable means no shared horizon, which the caller has to see
    /// as nil rather than a blank mask.
    func testFinalizingWithNothingGivesNil() async throws {
        let accumulator = HorizonAccumulator(frameCount: 4)
        let result = await accumulator.finalize { _ in nil }
        XCTAssertNil(result)
    }

    /// Frames that were never accumulated in memory are loaded from disk at finalize time — that is
    /// how a resumed run still gets a full vote.
    func testMissingFramesAreLoadedFromDiskAtFinalize() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "accumdisk")
        harness = h

        // two of three frames only exist on disk
        let pathA = h.writeScratch(FrameHarness.flatMask(width: 32, height: 32, at: 20),
                                   named: "a.tiff")
        let pathB = h.writeScratch(FrameHarness.flatMask(width: 32, height: 32, at: 20),
                                   named: "b.tiff")

        let accumulator = HorizonAccumulator(frameCount: 3)
        await accumulator.accumulate(image: FrameHarness.flatMask(width: 32, height: 32, at: 4),
                                    frameIndex: 0)

        let votedOptional = await accumulator.finalize { index in
            switch index {
            case 1: return pathA
            case 2: return pathB
            default: return nil
            }
        }
        let voted = try XCTUnwrap(votedOptional, "the two on-disk masks must be picked up")

        let sample = try XCTUnwrap(CombinedHorizonDetector.extractHorizonY(from: voted)[16])
        XCTAssertEqual(sample, 20, accuracy: 1,
                       "the two disk-loaded votes for 20 must outvote the in-memory 4")
    }

    // MARK: - identity

    /// The processor knows its own frame index and shares the accessor with the frame, which is how
    /// every path above resolves a filename.
    func testTheProcessorCarriesItsFrameIdentity() async throws {
        let h = try await FrameHarness.make(frameCount: 3, named: "identity")
        harness = h
        for index in 0..<3 {
            let horizon = await processor(h, at: index)
            XCTAssertEqual(horizon.frameIndex, index)
            let path = horizon.imageAccessor.nameForImage(frameIndex: index,
                                                          ofType: .mergedHorizon,
                                                          atSize: .original)
            XCTAssertNotNil(path)
        }
    }
}
