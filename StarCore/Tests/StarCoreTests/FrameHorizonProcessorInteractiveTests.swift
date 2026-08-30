import XCTest
import Foundation
@testable import StarCore

/// The interactive half of `FrameHorizonProcessor`: what the horizon painter calls while the user is
/// dragging, the filmstrip overlay that colour-codes each frame's horizon provenance, and the two pure
/// array helpers the reference-smoothing path is built from.
///
/// Kept separate from `FrameHorizonProcessorTests` because these run real detection over an image and
/// are correspondingly slower — the frames here are deliberately tiny.
final class FrameHorizonProcessorInteractiveTests: FrameHarnessTestCase {

    private func processor(_ h: FrameHarness, at index: Int = 0) async -> FrameHorizonProcessor {
        await h.frames[index].horizonProcessor
    }

    /// A byte mask in the layout `despikeHorizonY` works on: 255 sky above the per-column boundary,
    /// 0 ground at and below it.
    private func maskBytes(width: Int, height: Int, horizonAt: (Int) -> Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                bytes[y * width + x] = y < horizonAt(x) ? 255 : 0
            }
        }
        return bytes
    }

    /// The first row of ground in each column, read back out of a byte mask.
    private func horizonY(_ bytes: [UInt8], width: Int, height: Int) -> [Int] {
        (0..<width).map { x in
            for y in 0..<height where bytes[y * width + x] == 0 { return y }
            return height
        }
    }

    // MARK: - despikeHorizonY

    /// A clean horizon has nothing to correct, and nil is how the caller knows to keep the original
    /// mask rather than re-render it.
    func testACleanHorizonNeedsNoDespiking() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "despikeclean")
        harness = h
        let bytes = maskBytes(width: 64, height: 64) { _ in 32 }

        let result = await processor(h).despikeHorizonY(bytes, width: 64, height: 64,
                                                        windowHalf: 5, maxDeviation: 4,
                                                        maxSpikeWidth: 3)
        XCTAssertNil(result, "an already-smooth horizon must report no change")
    }

    /// The case this exists for: a narrow column where the horizon jumps far above its neighbours —
    /// a tree or a noise artefact — is pulled back onto the line.
    func testANarrowSpikeIsInterpolatedAway() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "despike")
        harness = h
        // flat at 40, except two columns that jump 25 rows up
        let bytes = maskBytes(width: 64, height: 64) { x in (x == 30 || x == 31) ? 15 : 40 }

        let correctedOptional = await processor(h).despikeHorizonY(
                                  bytes, width: 64, height: 64,
                                  windowHalf: 8, maxDeviation: 5, maxSpikeWidth: 4)
        let corrected = try XCTUnwrap(correctedOptional,
                                      "a 25-row spike over 2 columns must be corrected")

        let ys = horizonY(corrected, width: 64, height: 64)
        XCTAssertEqual(ys[30], 40, accuracy: 3, "the spike column must come back to the line")
        XCTAssertEqual(ys[31], 40, accuracy: 3)
        XCTAssertEqual(ys[10], 40, "an untouched column must stay where it was")
    }

    /// A wide deviation is a real feature — a mountain, a building — and must survive.  This is the
    /// distinction `maxSpikeWidth` draws, and getting it wrong would flatten real terrain.
    func testAWideDeviationIsKeptAsRealTerrain() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "despikewide")
        harness = h
        // a 30-column plateau, far wider than maxSpikeWidth
        let bytes = maskBytes(width: 64, height: 64) { x in (20..<50).contains(x) ? 15 : 40 }

        let result = await processor(h).despikeHorizonY(bytes, width: 64, height: 64,
                                                        windowHalf: 5, maxDeviation: 5,
                                                        maxSpikeWidth: 4)
        if let corrected = result {
            let ys = horizonY(corrected, width: 64, height: 64)
            XCTAssertLessThan(ys[35], 25,
                              "the middle of a 30-column plateau is terrain and must not be flattened")
        }
        // nil is equally acceptable here: it means nothing was judged a spike at all
    }

    /// Deviations inside the tolerance are left alone, so a naturally uneven skyline is not smoothed
    /// into a straight line.
    func testDeviationsWithinToleranceAreLeftAlone() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "despiketol")
        harness = h
        // gentle +/-2 wobble, well inside a maxDeviation of 8
        let bytes = maskBytes(width: 64, height: 64) { x in 40 + (x % 4 == 0 ? -2 : 1) }

        let result = await processor(h).despikeHorizonY(bytes, width: 64, height: 64,
                                                        windowHalf: 5, maxDeviation: 8,
                                                        maxSpikeWidth: 3)
        XCTAssertNil(result, "a wobble inside the tolerance is not a spike")
    }

    /// An isolated bright pixel below the horizon — a star bleeding through, or dead pixel — must not
    /// be mistaken for the horizon, which is what `minGroundRun` guards.
    func testAnIsolatedGroundPixelDoesNotMoveTheHorizon() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "despikerun")
        harness = h
        var bytes = maskBytes(width: 64, height: 64) { _ in 40 }
        // a single dark pixel high up in one column
        bytes[10 * 64 + 25] = 0

        let result = await processor(h).despikeHorizonY(bytes, width: 64, height: 64,
                                                        windowHalf: 8, maxDeviation: 5,
                                                        maxSpikeWidth: 4, minGroundRun: 3)
        // whatever it decides, the corrected column must not claim the horizon is at row 10
        if let corrected = result {
            let ys = horizonY(corrected, width: 64, height: 64)
            XCTAssertGreaterThan(ys[25], 20,
                                 "a one-pixel run must not be treated as the start of ground")
        }
    }

    // MARK: - interpolatedExpectedYPerColumn

    /// A painted reference reduced to its line — what both expected-horizon helpers take, and
    /// what `referenceHorizonCurves` reads off a reference mask.
    private func stats(frameIndex: Int, horizonYPerColumn: [Int?]) -> ReferenceHorizonCurve {
        ReferenceHorizonCurve(frameIndex: frameIndex, horizonYPerColumn: horizonYPerColumn)
    }

    /// The point of this helper: a frame between two painted references gets a per-column horizon
    /// interpolated between them, weighted by how far along it sits.
    func testAFrameBetweenTwoReferencesInterpolatesBetweenThem() async throws {
        let h = try await FrameHarness.make(frameCount: 5, width: 32, height: 32, named: "interp")
        harness = h
        // frame 2 sits exactly halfway between references at 0 and 4
        let horizon = await processor(h, at: 2)

        let resultOptional = await horizon.interpolatedExpectedYPerColumn(
          from: [stats(frameIndex: 0, horizonYPerColumn: Array(repeating: 10, count: 8)),
                 stats(frameIndex: 4, horizonYPerColumn: Array(repeating: 50, count: 8))],
          width: 8)
        let result = try XCTUnwrap(resultOptional)

        for x in 0..<8 {
            XCTAssertEqual(try XCTUnwrap(result[x]), 30, "column \(x) must be the midpoint")
        }
    }

    /// The weighting follows the frame distance, not a plain average — a frame close to one reference
    /// should look mostly like it.
    func testTheInterpolationIsWeightedByFrameDistance() async throws {
        let h = try await FrameHarness.make(frameCount: 12, width: 32, height: 32, named: "interpw")
        harness = h
        // frame 1 of a 0...10 span: one tenth of the way across
        let resultOptional = await processor(h, at: 1).interpolatedExpectedYPerColumn(
            from: [stats(frameIndex: 0, horizonYPerColumn: Array(repeating: 0, count: 4)),
                   stats(frameIndex: 10, horizonYPerColumn: Array(repeating: 100, count: 4))],
            width: 4)
        let result = try XCTUnwrap(resultOptional)
        XCTAssertEqual(try XCTUnwrap(result[0]), 10,
                       "one tenth of the way between 0 and 100 is 10")
    }

    /// With references only on one side there is nothing to interpolate between, so the nearest one is
    /// used wholesale — which is what happens at the ends of a sequence.
    func testWithReferencesOnOneSideOnlyTheNearestIsUsed() async throws {
        let h = try await FrameHarness.make(frameCount: 6, width: 32, height: 32, named: "interpone")
        harness = h
        // frame 5 with references only before it
        let resultOptional = await processor(h, at: 5).interpolatedExpectedYPerColumn(
            from: [stats(frameIndex: 1, horizonYPerColumn: Array(repeating: 20, count: 4)),
                   stats(frameIndex: 3, horizonYPerColumn: Array(repeating: 44, count: 4))],
            width: 4)
        let result = try XCTUnwrap(resultOptional)
        XCTAssertEqual(try XCTUnwrap(result[0]), 44,
                       "frame 3 is nearer than frame 1, so its horizon is used as-is")
    }

    /// A column defined on only one side falls back to that side rather than becoming nil, so partial
    /// paintings still contribute.
    func testAColumnDefinedOnOnlyOneSideFallsBackToIt() async throws {
        let h = try await FrameHarness.make(frameCount: 5, width: 32, height: 32, named: "interpgap")
        harness = h
        let resultOptional = await processor(h, at: 2).interpolatedExpectedYPerColumn(
            from: [stats(frameIndex: 0, horizonYPerColumn: [10, nil, 10, nil]),
                   stats(frameIndex: 4, horizonYPerColumn: [50, 50, nil, nil])],
            width: 4)
        let result = try XCTUnwrap(resultOptional)
        XCTAssertEqual(try XCTUnwrap(result[0]), 30, "both sides defined: interpolated")
        XCTAssertEqual(try XCTUnwrap(result[1]), 50, "only the later side: used directly")
        XCTAssertEqual(try XCTUnwrap(result[2]), 10, "only the earlier side: used directly")
        XCTAssertNil(result[3], "neither side: stays undefined")
    }

    /// No references at all means no prior, and nil is what switches the smoothing off.
    func testNoReferencesGiveNoPrior() async throws {
        let h = try await FrameHarness.make(frameCount: 3, width: 32, height: 32, named: "interpnone")
        harness = h
        let result = await processor(h).interpolatedExpectedYPerColumn(from: [], width: 8)
        XCTAssertNil(result)
    }

    /// A reference narrower than the frame must not be indexed past its end.
    func testANarrowerReferenceIsNotIndexedPastItsEnd() async throws {
        let h = try await FrameHarness.make(frameCount: 5, width: 32, height: 32, named: "interpnarrow")
        harness = h
        let resultOptional = await processor(h, at: 2).interpolatedExpectedYPerColumn(
            from: [stats(frameIndex: 0, horizonYPerColumn: Array(repeating: 10, count: 3)),
                   stats(frameIndex: 4, horizonYPerColumn: Array(repeating: 50, count: 3))],
            width: 16)
        let result = try XCTUnwrap(resultOptional)
        XCTAssertEqual(result.count, 16, "the result is the requested width")
        XCTAssertEqual(try XCTUnwrap(result[0]), 30)
        XCTAssertNil(result[8], "columns past the references' width stay undefined")
    }

    // MARK: - the filmstrip overlay

    /// The overlay's `kind` is what colours each filmstrip thumbnail, so the user can see at a glance
    /// which frames they painted and which inherited.  Four sources, in priority order.
    func testTheOverlayKindReportsWhereTheHorizonCameFrom() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "overlay")
        harness = h
        let horizon = await processor(h)

        // nothing at all
        let none = try await horizon.loadHorizonThumbnailOverlay(thumbnailWidth: 32,
                                                                thumbnailHeight: 32)
        XCTAssertNil(none, "no horizon anywhere means no overlay")

        // a raw horizon only: "initial"
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 40), ofType: .horizon)
        var overlayOptional = try await horizon.loadHorizonThumbnailOverlay(thumbnailWidth: 32,
                                                                            thumbnailHeight: 32)
        var overlay = try XCTUnwrap(overlayOptional)
        XCTAssertEqual(overlay.kind, .initial)

        // a merged horizon outranks it
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 36),
                         ofType: .mergedHorizon)
        overlayOptional = try await horizon.loadHorizonThumbnailOverlay(thumbnailWidth: 32,
                                                                       thumbnailHeight: 32)
        overlay = try XCTUnwrap(overlayOptional)
        XCTAssertEqual(overlay.kind, .merged)

        // this frame's own painted reference outranks everything, and is the one shown differently
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 20),
                                 perFrame: true)
        overlayOptional = try await horizon.loadHorizonThumbnailOverlay(thumbnailWidth: 32,
                                                                        thumbnailHeight: 32)
        overlay = try XCTUnwrap(overlayOptional)
        XCTAssertEqual(overlay.kind, .reference,
                       "the frame the user actually painted must be distinguishable")
    }

    /// A frame inheriting a sequence-wide reference is *not* the painted frame, so it reports `merged`
    /// rather than `reference` — that is the blue-versus-green distinction in the filmstrip.
    func testAFrameInheritingAGlobalReferenceIsNotMarkedAsPainted() async throws {
        let h = try await FrameHarness.make(frameCount: 2, width: 64, height: 64, named: "inherit")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 30),
                                 perFrame: false)

        let overlayOptional = try await processor(h, at: 1).loadHorizonThumbnailOverlay(thumbnailWidth: 32,
                                                               thumbnailHeight: 32)
        let overlay = try XCTUnwrap(overlayOptional)
        XCTAssertEqual(overlay.kind, .merged,
                       "inheriting a global reference is not the same as having painted this frame")
    }

    /// The Y values are scaled into thumbnail space and clamped inside it, since they index a drawing
    /// buffer of exactly that height.
    func testTheOverlayScalesAndClampsIntoThumbnailSpace() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "overlayscale")
        harness = h
        try h.plantImage(FrameHarness.flatMask(width: 128, height: 128, at: 64), ofType: .horizon)

        let overlayOptional = try await processor(h).loadHorizonThumbnailOverlay(thumbnailWidth: 32, thumbnailHeight: 32)
        let overlay = try XCTUnwrap(overlayOptional)
        XCTAssertEqual(overlay.yPerColumn.count, 32)
        XCTAssertEqual(overlay.height, 32)
        for (x, y) in overlay.yPerColumn.enumerated() {
            XCTAssertEqual(y, 16, accuracy: 1, "column \(x): half of 128 is half of 32")
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThan(y, 32, "a Y past the buffer would be an out-of-bounds draw")
        }
    }

    /// An all-sky mask has no horizon in any column; the overlay falls back to the middle rather than
    /// leaving the buffer undefined.
    func testAnAllSkyMaskGivesAMidHeightOverlay() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "overlaysky")
        harness = h
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 64), ofType: .horizon)

        let overlayOptional = try await processor(h).loadHorizonThumbnailOverlay(thumbnailWidth: 16, thumbnailHeight: 16)
        let overlay = try XCTUnwrap(overlayOptional)
        XCTAssertEqual(overlay.yPerColumn, [Int](repeating: 8, count: 16),
                       "undefined columns default to mid height")
    }

    // MARK: - the live object-selection preview

    /// What the painter calls on every drag: given the painted band, find the skyline inside it.  The
    /// result has to cover the full frame width even though the band does not.
    func testTheLivePreviewFindsAHorizonInsideThePaintedBand() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 96, height: 72,
                                           horizonRow: 36, named: "live")
        harness = h

        let viewWidth = 48, viewHeight = 36
        // a band straddling the true horizon (view row 18 of 36 is image row 36 of 72)
        let top = [Int?](repeating: 10, count: viewWidth)
        let bottom = [Int?](repeating: 26, count: viewWidth)

        let result = try await processor(h).computeLiveObjectSelection(topBoundaryY: top,
                                                                      bottomBoundaryY: bottom,
                                                                      viewWidth: viewWidth,
                                                                      viewHeight: viewHeight)
        XCTAssertEqual(result.count, viewWidth,
                       "the result is per view column, covering the whole width")
        let defined = result.compactMap { $0 }
        XCTAssertFalse(defined.isEmpty, "the preview must find something inside the band")
        for y in defined {
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThan(y, viewHeight, "a Y outside the view would be drawn off screen")
        }
    }

    /// Unpainted columns come back nil, as the doc states — the live preview only reports what the
    /// user has actually painted over, and interpolates *between* painted columns but not beyond them.
    ///
    /// This is an asymmetry between the two interactive entry points worth knowing about:
    /// `computeCombinedHorizonInBand` documents and performs nearest-neighbour edge extrapolation "so
    /// the horizon always covers the full frame width", and `horizonMaskToViewY` runs `fillEdgeNils`
    /// too, but this one deliberately does not.  A caller that assumes a full-width result from all
    /// three would find holes at the edges from this one only.
    func testUnpaintedColumnsStayNilInTheLivePreview() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 96, height: 72,
                                           horizonRow: 36, named: "liveedge")
        harness = h

        let viewWidth = 48, viewHeight = 36
        // only the middle third is painted
        var top = [Int?](repeating: nil, count: viewWidth)
        var bottom = [Int?](repeating: nil, count: viewWidth)
        for x in 16..<32 { top[x] = 10; bottom[x] = 26 }

        let result = try await processor(h).computeLiveObjectSelection(topBoundaryY: top,
                                                                      bottomBoundaryY: bottom,
                                                                      viewWidth: viewWidth,
                                                                      viewHeight: viewHeight)
        XCTAssertEqual(result.count, viewWidth, "the array is still full width")
        XCTAssertNil(result[0], "the unpainted leading edge is not extrapolated here")
        XCTAssertNil(result[viewWidth - 1], "nor the trailing edge")
        XCTAssertFalse(result[16..<32].allSatisfy { $0 == nil },
                       "but the painted span must have produced something")
    }

    /// `fillEdgeNils` is what the other two paths apply to close those holes, so the difference is one
    /// call rather than a different algorithm.
    func testFillEdgeNilsWouldCloseThoseHoles() {
        var partial = [Int?](repeating: nil, count: 48)
        for x in 16..<32 { partial[x] = 20 }
        let filled = FrameHorizonProcessor.fillEdgeNils(partial)
        XCTAssertEqual(filled[0], 20)
        XCTAssertEqual(filled[47], 20)
    }

    /// A band that is nowhere painted has nothing to work from; the call must return rather than trap.
    func testAnEmptyBandIsHandled() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 48,
                                           horizonRow: 24, named: "liveempty")
        harness = h
        let result = try await processor(h).computeLiveObjectSelection(
                       topBoundaryY: [Int?](repeating: nil, count: 32),
                       bottomBoundaryY: [Int?](repeating: nil, count: 32),
                       viewWidth: 32, viewHeight: 24)
        XCTAssertEqual(result.count, 32)
    }

    /// Locked regions are the refinement brush: a column the user has confirmed as sky must not come
    /// back classified as ground above that point.
    func testAConfirmedSkyFloorIsHonoured() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 96, height: 72,
                                           horizonRow: 36, named: "livelock")
        harness = h

        let viewWidth = 48, viewHeight = 36
        let top = [Int?](repeating: 6, count: viewWidth)
        let bottom = [Int?](repeating: 30, count: viewWidth)
        // the user has confirmed everything above view row 20 is sky
        let skyFloor = [Int?](repeating: 20, count: viewWidth)

        let result = try await processor(h).computeLiveObjectSelection(
                       topBoundaryY: top, bottomBoundaryY: bottom,
                       viewWidth: viewWidth, viewHeight: viewHeight,
                       knownSkyFloorY: skyFloor,
                       knownGroundCeilingY: bottom)
        XCTAssertEqual(result.count, viewWidth)
        for (x, y) in result.enumerated() {
            guard let y else { continue }
            XCTAssertGreaterThanOrEqual(y, 20 - 1,
                                        "column \(x) was confirmed sky down to row 20")
        }
    }

    // MARK: - expectedHorizonYPerColumn

    /// Row-major translation, matching what the alignment stage stores.
    private func translation(_ dx: Double, _ dy: Double) -> [Double] {
        [1, 0, dx, 0, 1, dy, 0, 0, 1]
    }

    /// Give every frame in `range` the earth record a real run would have: the ground moves by
    /// `(dx, dy)` per frame, so each frame's record carries the homography bringing each immediate
    /// neighbour into it — forwards `(dx, dy)`, backwards the negative.
    private func writeEarthSteps(
      _ h: FrameHarness, over range: ClosedRange<Int>, dx: Double, dy: Double
    ) async throws {
        let manager = h.configManager
        let database = await MainActor.run { manager.homographyDatabase }
        for frame in range {
            var warps: [AlignmentWarpInfoCodable] = []
            if frame > range.lowerBound {
                warps.append(AlignmentWarpInfoCodable(homography: translation(dx, dy),
                                                      deviation: 1,
                                                      alignmentState: .homographySuccess,
                                                      frameIndex: frame - 1))
            }
            if frame < range.upperBound {
                warps.append(AlignmentWarpInfoCodable(homography: translation(-dx, -dy),
                                                      deviation: 1,
                                                      alignmentState: .homographySuccess,
                                                      frameIndex: frame + 1))
            }
            guard !warps.isEmpty else { continue }
            try await database.write(
              frameIndex: frame, type: .earth,
              results: HomographyResultsCodable(for: frame, with: warps))
        }
        await earthHomographyChain.invalidate()
    }

    /// A ridge: a V of horizon Y values with its lowest point (the summit) at `peak`.
    private func ridge(peakColumn: Int, width: Int) -> [Int?] {
        (0..<width).map { Optional(4 + 2 * abs($0 - peakColumn)) }
    }

    /// With no homographies stored there is nothing to carry a reference with, so the answer is the
    /// interpolation — which is what a sequence gets on its first run, before alignment.
    func testWithoutHomographiesTheExpectedHorizonIsTheInterpolation() async throws {
        let h = try await FrameHarness.make(frameCount: 5, width: 32, height: 32, named: "expnone")
        harness = h
        await earthHomographyChain.invalidate()
        let expected = await processor(h, at: 2).expectedHorizonYPerColumn(
          from: [stats(frameIndex: 0, horizonYPerColumn: Array(repeating: 10, count: 8)),
                 stats(frameIndex: 4, horizonYPerColumn: Array(repeating: 50, count: 8))],
          width: 8)
        let result = try XCTUnwrap(expected)
        XCTAssertFalse(result.carriedByHomography)
        XCTAssertEqual(result.yPerColumn.compactMap { $0 }, Array(repeating: 30, count: 8))
    }

    /// The case the whole thing exists for.  A ridge sits still in the world while the camera pans
    /// across it, so it is painted at column 4 on frame 0 and at column 12 on frame 4 — the same
    /// mountain, eight columns further along.  Interpolating those two paintings column by column
    /// averages the near side of one ridge with the far side of the other and produces a summit that
    /// is nowhere; carrying each of them by the stored homographies puts both summits at column 8,
    /// where the mountain actually is on frame 2.
    func testAPanCarriesTheReferenceSidewaysRatherThanInterpolatingItsY() async throws {
        let h = try await FrameHarness.make(frameCount: 5, width: 32, height: 32, named: "exppan")
        harness = h
        try await writeEarthSteps(h, over: 0...4, dx: 2, dy: 0)   // ground moves +2 columns per frame

        let horizon = await processor(h, at: 2)
        let references = [stats(frameIndex: 0, horizonYPerColumn: ridge(peakColumn: 4, width: 16)),
                          stats(frameIndex: 4, horizonYPerColumn: ridge(peakColumn: 12, width: 16))]

        let expected = await horizon.expectedHorizonYPerColumn(from: references, width: 16)
        let result = try XCTUnwrap(expected)
        XCTAssertTrue(result.carriedByHomography)

        XCTAssertEqual(try XCTUnwrap(result.yPerColumn[8]), 4,
                       "both references carry their summit to column 8")
        XCTAssertEqual(try XCTUnwrap(result.yPerColumn[6]), 8,
                       "and the flanks come with it")
        XCTAssertEqual(try XCTUnwrap(result.yPerColumn[10]), 8)

        let interpolatedOptional = await horizon.interpolatedExpectedYPerColumn(from: references,
                                                                               width: 16)
        let interpolated = try XCTUnwrap(interpolatedOptional)
        XCTAssertEqual(try XCTUnwrap(interpolated[8]), 12,
                       "interpolating puts nothing at all at the summit — this is what was shipping")
    }

    /// A pan leaves part of the target frame outside anything either reference saw.  Those columns
    /// must still come back with a value — a nil there is a column the merged mask cannot classify —
    /// and the fallback is the interpolation, then the nearest defined column.
    func testColumnsThePanLeavesUncoveredFallBackRatherThanGoingNil() async throws {
        let h = try await FrameHarness.make(frameCount: 3, width: 32, height: 32, named: "expedge")
        harness = h
        try await writeEarthSteps(h, over: 0...2, dx: 6, dy: 0)

        let expected = await processor(h, at: 1).expectedHorizonYPerColumn(
          from: [stats(frameIndex: 0, horizonYPerColumn: Array(repeating: 10, count: 16)),
                 stats(frameIndex: 2, horizonYPerColumn: Array(repeating: 10, count: 16))],
          width: 16)
        let result = try XCTUnwrap(expected)
        XCTAssertTrue(result.carriedByHomography)
        XCTAssertEqual(result.yPerColumn.count, 16)
        XCTAssertFalse(result.yPerColumn.contains(where: { $0 == nil }),
                       "every column must end up with a value")
    }

    /// A vertical-only move is the one case the old interpolation already handled, so the carried
    /// answer must agree with it — otherwise this change is a regression dressed as an improvement.
    func testAVerticalOnlyMoveAgreesWithTheOldInterpolation() async throws {
        let h = try await FrameHarness.make(frameCount: 5, width: 32, height: 32, named: "expvert")
        harness = h
        try await writeEarthSteps(h, over: 0...4, dx: 0, dy: 5)

        let horizon = await processor(h, at: 2)
        let stats = [stats(frameIndex: 0, horizonYPerColumn: Array(repeating: 10, count: 8)),
                     stats(frameIndex: 4, horizonYPerColumn: Array(repeating: 30, count: 8))]
        let carriedOptional = await horizon.expectedHorizonYPerColumn(from: stats, width: 8)
        let carried = try XCTUnwrap(carriedOptional)
        let interpolatedOptional = await horizon.interpolatedExpectedYPerColumn(from: stats, width: 8)
        let interpolated = try XCTUnwrap(interpolatedOptional)
        XCTAssertTrue(carried.carriedByHomography)
        XCTAssertEqual(carried.yPerColumn.compactMap { $0 }, interpolated.compactMap { $0 })
    }

    // MARK: - referenceSmoothedHorizonMask

    /// A binary horizon mask: sky (255) above the per-column boundary, ground (0) at and below.
    private func maskImage(width: Int, height: Int, horizonY: [Int]) throws -> HorizonMask {
        let image = try XCTUnwrap(PixelatedImage.fromHorizonColumnY(
                                    width: width, height: height,
                                    columnY: horizonY.map { Optional($0) }))
        return try XCTUnwrap(HorizonMask(image))
    }

    /// The failure this filter was blind to.  A detection that has locked onto the wrong edge is
    /// wrong by roughly the same amount in every column, so its deviations from the reference are
    /// tightly clustered — and a test centred on the *mean* deviation therefore finds no outliers at
    /// all and replaces nothing.  On the aurora sequence that left frame 119's horizon 215 px above a
    /// reference painted two frames earlier, with this filter reporting success.
    func testAUniformlyWrongDetectionIsReplacedByTheReference() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "smoothbias")
        harness = h
        let detected = try maskImage(width: 64, height: 200, horizonY: Array(repeating: 40, count: 64))
        let expected: [Int?] = Array(repeating: 120, count: 64)

        let smoothedOptional = await processor(h).referenceSmoothedHorizonMask(
                                 detected: detected, expectedYPerColumn: expected)
        let smoothed = try XCTUnwrap(smoothedOptional)
        let ys = HorizonScoring.extractHorizonYPerColumn(from: smoothed.image)
        for x in 0..<64 {
            XCTAssertEqual(try XCTUnwrap(ys[x]), 120,
                           "column \(x) was 80px off the reference and should have been replaced")
        }
    }

    /// It stays a filter, not a clamp: a detection that agrees with the references to within the
    /// tolerance keeps its own line, so real terrain detail the references bracket loosely survives.
    func testADetectionWithinToleranceIsLeftAlone() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "smoothkeep")
        harness = h
        let detectedY = (0..<64).map { 100 + ($0 % 5) }   // wanders by 4px
        let detected = try maskImage(width: 64, height: 200, horizonY: detectedY)
        let expected: [Int?] = Array(repeating: 100, count: 64)

        let smoothedOptional = await processor(h).referenceSmoothedHorizonMask(
                                 detected: detected, expectedYPerColumn: expected)
        let smoothed = try XCTUnwrap(smoothedOptional)
        let ys = HorizonScoring.extractHorizonYPerColumn(from: smoothed.image)
        XCTAssertEqual(ys.compactMap { $0 }, detectedY, "nothing was outside the tolerance")
    }

    /// One bad column among good ones is what the filter was always able to catch, and still must.
    func testASingleOutlierColumnIsReplaced() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 32, height: 32, named: "smoothspike")
        harness = h
        var detectedY = Array(repeating: 100, count: 64)
        detectedY[20] = 30
        let detected = try maskImage(width: 64, height: 200, horizonY: detectedY)
        let expected: [Int?] = Array(repeating: 100, count: 64)

        let smoothedOptional = await processor(h).referenceSmoothedHorizonMask(
                                 detected: detected, expectedYPerColumn: expected)
        let smoothed = try XCTUnwrap(smoothedOptional)
        let ys = HorizonScoring.extractHorizonYPerColumn(from: smoothed.image)
        XCTAssertEqual(try XCTUnwrap(ys[20]), 100, "the outlier took the reference's value")
        XCTAssertEqual(try XCTUnwrap(ys[21]), 100)
    }

    /// Band mode is the alternative entry the painter uses before any refinement; it must produce a
    /// result of the same shape.
    func testBandModeProducesAFullWidthResult() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 96, height: 72,
                                           horizonRow: 36, named: "liveband")
        harness = h
        let result = try await processor(h).computeLiveObjectSelection(
                       topBoundaryY: [Int?](repeating: 10, count: 48),
                       bottomBoundaryY: [Int?](repeating: 26, count: 48),
                       viewWidth: 48, viewHeight: 36,
                       bandMode: true)
        XCTAssertEqual(result.count, 48)
    }
}
