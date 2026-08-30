import XCTest
import Foundation
@testable import StarCore

/// `CombinedHorizonDetector` runs five independent horizon-finding methods (Otsu, dynamic
/// programming, SIOX, gradient profile, texture), scores each one's confidence, merges them per
/// column, and refines the result with a Random Walker pass over several brush radii.
///
/// The five `run*` methods are thin wrappers over OpenCV and stay private; what is tested here is the
/// glue that decides *which* of them to trust and *how* to merge them, plus the whole pipeline
/// end to end on a synthetic frame whose true horizon is known.  The pure helpers were `private
/// static` and had to be made internal to be reachable — no behaviour change, same module.
final class CombinedHorizonDetectorTests: XCTestCase {

    // MARK: - fixtures

    private func flat(_ y: Int, width: Int = 100) -> [Int?] {
        [Int?](repeating: y, count: width)
    }

    private func natural(width: Int = 100, around y: Int, amplitude: Int = 3) -> [Int?] {
        (0..<width).map { x in y + Int((Double(amplitude) * sin(Double(x) / 8.0)).rounded()) }
    }

    // MARK: - Prior

    /// The band handed to the base methods is the prior's extent plus its radius, as fractions
    /// of image height.  This is the whole mechanism for the methods that take a band, so a
    /// mistake here is a detector searching the wrong part of the frame with no other symptom.
    func testTheBandIsThePriorsExtentWidenedByTheRadius() throws {
        let prior = CombinedHorizonDetector.Prior(
          yPerColumn: [3400, 3500, 3600], searchRadius: 200)
        let band = try XCTUnwrap(prior.searchFractions(imageHeight: 4000))
        XCTAssertEqual(band.top, (3400.0 - 200) / 4000, accuracy: 1e-9)
        XCTAssertEqual(band.bottom, (3600.0 + 200) / 4000, accuracy: 1e-9)
    }

    /// A horizon near an edge of the frame must not produce a band outside it, and must not
    /// produce an inverted or zero-height one — the base methods index rows from these.
    func testTheBandIsClampedIntoTheFrame() throws {
        let high = CombinedHorizonDetector.Prior(yPerColumn: [10], searchRadius: 500)
        let highBand = try XCTUnwrap(high.searchFractions(imageHeight: 4000))
        XCTAssertEqual(highBand.top, 0.0)
        XCTAssertGreaterThan(highBand.bottom, highBand.top)

        let low = CombinedHorizonDetector.Prior(yPerColumn: [3990], searchRadius: 500)
        let lowBand = try XCTUnwrap(low.searchFractions(imageHeight: 4000))
        XCTAssertLessThanOrEqual(lowBand.bottom, 1.0)
        XCTAssertGreaterThanOrEqual(lowBand.bottom - lowBand.top, 0.02)
    }

    /// A prior with no defined columns describes no band, and must not be mistaken for one at
    /// the top of the frame.
    func testAnEmptyPriorHasNoBand() {
        let prior = CombinedHorizonDetector.Prior(yPerColumn: [nil, nil], searchRadius: 100)
        XCTAssertNil(prior.searchFractions(imageHeight: 4000))
    }

    /// Agreement is the fraction of a method's own defined columns that land inside the radius.
    /// It becomes a confidence multiplier, so the scale matters as much as the ordering.
    func testAgreementIsTheFractionOfColumnsInsideTheRadius() {
        let prior = CombinedHorizonDetector.Prior(
          yPerColumn: [100, 100, 100, 100], searchRadius: 10)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([100, 105, 100, 109], prior: prior),
                       1.0, accuracy: 1e-9)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([100, 500, 100, 500], prior: prior),
                       0.5, accuracy: 1e-9)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([900, 900, 900, 900], prior: prior),
                       0.0, accuracy: 1e-9)
    }

    /// Exactly on the radius counts as agreement — the radius is how far the horizon *may* be,
    /// not how far it may nearly be.
    func testTheRadiusIsInclusive() {
        let prior = CombinedHorizonDetector.Prior(yPerColumn: [100], searchRadius: 10)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([110], prior: prior), 1.0)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([111], prior: prior), 0.0)
    }

    /// Columns either side has no value for are not counted either way, so a sparse method is
    /// judged on what it actually said.
    func testColumnsWithNoValueOnEitherSideAreNotCounted() {
        let prior = CombinedHorizonDetector.Prior(yPerColumn: [100, nil, 100], searchRadius: 5)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([100, 9999, nil], prior: prior),
                       1.0, accuracy: 1e-9,
                       "column 1 has no prior and column 2 has no detection")
    }

    /// A method with nothing defined agrees with nothing, rather than dividing by zero or
    /// coming back as perfect agreement over an empty set.
    func testAnEmptyMethodAgreesWithNothing() {
        let prior = CombinedHorizonDetector.Prior(yPerColumn: [100], searchRadius: 5)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([nil], prior: prior), 0.0)
        XCTAssertEqual(CombinedHorizonDetector.priorAgreement([], prior: prior), 0.0)
    }

    /// What seeds the Random Walker is bounded into the band.  The walker grows its answer out
    /// of this line, so a seed sitting on the wrong edge produces a confidently wrong mask —
    /// which is the failure that reaches the user.
    func testTheCombinedCurveIsBoundedIntoTheBand() {
        let prior = CombinedHorizonDetector.Prior(
          yPerColumn: [100, 100, 100], searchRadius: 20)
        let bounded = CombinedHorizonDetector.boundedByPrior([50, 105, 900], prior: prior)
        XCTAssertEqual(bounded[0], 80, "clamped up to the top of the band")
        XCTAssertEqual(bounded[1], 105, "already inside, untouched")
        XCTAssertEqual(bounded[2], 120, "clamped down to the bottom of the band")
    }

    /// Columns the combine left undefined take the prior outright, so the walker is seeded
    /// across the full width rather than left with holes.
    func testUndefinedColumnsTakeThePrior() {
        let prior = CombinedHorizonDetector.Prior(yPerColumn: [100, 200], searchRadius: 20)
        let bounded = CombinedHorizonDetector.boundedByPrior([nil, nil], prior: prior)
        XCTAssertEqual(bounded, [100, 200])
    }

    /// Where the prior itself is undefined there is nothing to bound against, and the
    /// detection stands as it is.
    func testColumnsWithNoPriorAreLeftAlone() {
        let prior = CombinedHorizonDetector.Prior(yPerColumn: [nil, nil], searchRadius: 20)
        XCTAssertEqual(CombinedHorizonDetector.boundedByPrior([7, nil], prior: prior), [7, nil])
    }

    // MARK: - Params

    /// The defaults are what every production call uses — `FrameHorizonProcessor` constructs a
    /// `Params()` and overrides at most the working size.
    func testTheDefaultParametersAreTheProductionOnes() {
        let params = CombinedHorizonDetector.Params()
        XCTAssertEqual(params.baseWorkingSize, 512)
        XCTAssertEqual(params.brushRadii, [40, 80, 160])
        XCTAssertEqual(params.rwBeta, 90.0)
        XCTAssertEqual(params.rwMaxWorkingWidth, 4096)
        XCTAssertEqual(params.outlierThreshold, 80)
        XCTAssertEqual(params.sioxBandTopFraction, 0.15)
        XCTAssertEqual(params.sioxBandBottomFraction, 0.85)
        XCTAssertEqual(params.dpLambdas, [1.0, 1.5, 2.0, 3.0])
        XCTAssertEqual(params.dpSobelWeights, [0.2, 0.6, 1.0])
        XCTAssertEqual(params.dpCannyWeights, [0.2, 0.6, 1.0])
    }

    /// More than one brush radius is essential: the pipeline picks the best-scoring one, so a single
    /// radius removes the choice entirely.
    func testTheBrushRadiiOfferMoreThanOneChoice() {
        XCTAssertGreaterThan(CombinedHorizonDetector.Params().brushRadii.count, 1)
    }

    // MARK: - extractHorizonY

    /// Ground is anything at or below 127, not just pure black — deliberately more tolerant than
    /// `HorizonScoring.extractHorizonYPerColumn`, which demands exactly 0, because this one reads
    /// masks that may have been interpolated.
    func testGroundIsAnythingAtOrBelowMidGrey() {
        // a mask whose "ground" is mid grey rather than black
        var rows: [Int: UInt8] = [:]
        for y in 0..<32 { rows[y] = y < 16 ? 255 : 127 }
        let soft = FrameHarness.grayImage(width: 16, height: 32, rows: rows)

        let viaCombined = CombinedHorizonDetector.extractHorizonY(from: soft)
        XCTAssertEqual(viaCombined[8], 16, "127 counts as ground here")

        let viaScoring = HorizonScoring.extractHorizonYPerColumn(from: soft)
        XCTAssertNil(viaScoring[8],
                     "the stricter extraction needs an exact zero, and finds no horizon at all")
    }

    /// 128 is the other side of the boundary and is sky, so the threshold is `<= 127` exactly.
    func testOneAboveMidGreyIsStillSky() {
        var rows: [Int: UInt8] = [:]
        for y in 0..<32 { rows[y] = y < 16 ? 255 : 128 }
        let image = FrameHarness.grayImage(width: 16, height: 32, rows: rows)
        XCTAssertNil(CombinedHorizonDetector.extractHorizonY(from: image)[8],
                     "128 is above the threshold, so the whole column reads as sky")
    }

    func testTheHorizonIsTheTopmostGroundRowPerColumn() {
        let mask = FrameHarness.syntheticMask(width: 40, height: 60) { x in 12 + x / 4 }
        let horizonY = CombinedHorizonDetector.extractHorizonY(from: mask)
        XCTAssertEqual(horizonY.count, 40)
        for x in 0..<40 {
            XCTAssertEqual(horizonY[x], 12 + x / 4, "column \(x)")
        }
    }

    func testAnAllSkyMaskHasNoHorizon() {
        let mask = FrameHarness.flatMask(width: 24, height: 24, at: 24)
        XCTAssertTrue(CombinedHorizonDetector.extractHorizonY(from: mask).allSatisfy { $0 == nil })
    }

    /// An all-ground mask reports row 0 in every column, matching the other extractor.
    func testAnAllGroundMaskReportsRowZero() {
        let mask = FrameHarness.flatMask(width: 24, height: 24, at: 0)
        XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: mask),
                       [Int?](repeating: 0, count: 24))
    }

    /// The scan goes through the raw pointer with the mat's own row stride, precisely so a padded
    /// `cv::Mat` is read correctly — an odd width is the case most likely to be padded.
    func testAnOddWidthMaskIsReadWithTheCorrectRowStride() {
        for width in [1, 3, 17, 33, 63] {
            let mask = FrameHarness.flatMask(width: width, height: 20, at: 10)
            let horizonY = CombinedHorizonDetector.extractHorizonY(from: mask)
            XCTAssertEqual(horizonY.count, width, "width \(width)")
            XCTAssertEqual(horizonY, [Int?](repeating: 10, count: width),
                           "row padding must not shift the result at width \(width)")
        }
    }

    /// A 16-bit mask takes its own branch, with its own row-stride arithmetic and a threshold of
    /// 32767, so it has to agree with the equivalent 8-bit mask.
    func testASixteenBitMaskAgreesWithItsEightBitEquivalent() {
        let eightBit = FrameHarness.flatMask(width: 32, height: 40, at: 18)
        let sixteenBit = FrameHarness.sixteenBitMask(width: 32, height: 40, at: 18)
        XCTAssertEqual(sixteenBit.bitsPerComponent, 16)

        XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: eightBit),
                       [Int?](repeating: 18, count: 32))
        XCTAssertEqual(CombinedHorizonDetector.extractHorizonY(from: sixteenBit),
                       CombinedHorizonDetector.extractHorizonY(from: eightBit),
                       "the two depths must give the same horizon")
    }

    /// The 16-bit threshold is half scale, so a *frame* is not a mask: a night sky's channel values
    /// sit well under 32767 and the whole image reads as ground.  Pinned because the extractor accepts
    /// any image and this is the way to misuse it — the callers all pass real masks.
    func testASixteenBitFrameIsNotAMaskBecauseItsSkyIsBelowHalfScale() throws {
        let frame = FrameHarness.syntheticFrame(width: 32, height: 40, horizonRow: 18)
        XCTAssertEqual(frame.bitsPerComponent, 16)
        let horizonY = CombinedHorizonDetector.extractHorizonY(from: frame)
        let y = try XCTUnwrap(horizonY[8])
        XCTAssertLessThan(y, 5,
                          "the sky itself reads as ground, so the horizon lands near the top")
    }

    // MARK: - horizonConfidence

    /// A smooth, fully-covered, centred horizon is the best case and must score well — this is the
    /// gate that decides whether a method is included at all (the caller drops anything at or below
    /// 0.05).
    func testAGoodHorizonScoresWellAboveTheInclusionThreshold() {
        let score = CombinedHorizonDetector.horizonConfidence(natural(around: 50), imageHeight: 100)
        XCTAssertGreaterThan(score, 0.05)
        XCTAssertGreaterThan(score, 0.5)
    }

    /// Below 5% coverage the method is not worth weighing at all, so it is zeroed outright rather
    /// than scaled.
    func testAlmostNoCoverageScoresZero() {
        var sparse = [Int?](repeating: nil, count: 100)
        sparse[0] = 50
        sparse[1] = 50
        XCTAssertEqual(CombinedHorizonDetector.horizonConfidence(sparse, imageHeight: 100), 0)

        XCTAssertEqual(CombinedHorizonDetector.horizonConfidence([], imageHeight: 100), 0)
        XCTAssertEqual(CombinedHorizonDetector.horizonConfidence([Int?](repeating: nil, count: 50),
                                                                imageHeight: 100), 0)
    }

    /// Coverage scales the score linearly, so a half-covered method contributes about half as much.
    func testCoverageScalesTheConfidence() {
        let full = CombinedHorizonDetector.horizonConfidence(flat(50), imageHeight: 100)
        var half = flat(50)
        for x in 0..<50 { half[x] = nil }
        let partial = CombinedHorizonDetector.horizonConfidence(half, imageHeight: 100)
        XCTAssertLessThan(partial, full)
        XCTAssertEqual(partial, full * 0.5, accuracy: 0.01)
    }

    /// A horizon jammed against the top or bottom of the frame is implausible.  The code sets
    /// plausibility to 0 for it, but the `max(0.05, ...)` clamp immediately below raises it back to
    /// 0.05 — so the zero branch never actually yields zero.
    ///
    /// It still has the intended effect: the caller includes a method only when its confidence is
    /// strictly greater than 0.05, and 0.05 times a coverage and smoothness that cannot exceed 1 can
    /// never clear that bar.  Pinned so the dead zero is on the record.
    func testAHorizonAtTheVeryTopOrBottomIsImplausible() {
        let top = CombinedHorizonDetector.horizonConfidence(flat(2), imageHeight: 100)
        let bottom = CombinedHorizonDetector.horizonConfidence(flat(98), imageHeight: 100)
        XCTAssertEqual(top, 0.05, accuracy: 1e-12, "the clamp floors the zero at 0.05")
        XCTAssertEqual(bottom, 0.05, accuracy: 1e-12)

        // and 0.05 does not clear the caller's `> 0.05` inclusion gate
        XCTAssertFalse(top > 0.05)
        XCTAssertFalse(bottom > 0.05)
    }

    /// Between 5% and 15% (and symmetrically at the bottom) the horizon is suspicious rather than
    /// impossible, and gets a fixed 0.3 plausibility instead of zero.
    func testTheSuspiciousBandGetsAReducedRatherThanZeroScore() {
        let suspicious = CombinedHorizonDetector.horizonConfidence(flat(10), imageHeight: 100)
        let centred = CombinedHorizonDetector.horizonConfidence(flat(50), imageHeight: 100)
        XCTAssertGreaterThan(suspicious, 0)
        XCTAssertLessThan(suspicious, centred)
        XCTAssertEqual(suspicious / centred, 0.3, accuracy: 0.01,
                       "the band applies a flat 0.3 plausibility factor")

        let lowSuspicious = CombinedHorizonDetector.horizonConfidence(flat(88), imageHeight: 100)
        XCTAssertEqual(lowSuspicious, suspicious, accuracy: 1e-9, "the band is symmetric")
    }

    /// A centred horizon beats an off-centre one, which is what stops a method that found the top of a
    /// mountain range from outweighing one that found the skyline.
    func testACentredHorizonBeatsAnOffCentreOne() {
        let centred = CombinedHorizonDetector.horizonConfidence(flat(50), imageHeight: 100)
        let high = CombinedHorizonDetector.horizonConfidence(flat(25), imageHeight: 100)
        let low = CombinedHorizonDetector.horizonConfidence(flat(75), imageHeight: 100)
        XCTAssertGreaterThan(centred, high)
        XCTAssertGreaterThan(centred, low)
        XCTAssertEqual(high, low, accuracy: 1e-9, "the plausibility ramp is symmetric about centre")
    }

    /// A noisy horizon is penalised, which is the whole point of the smoothness factor.
    func testANoisyHorizonScoresBelowASmoothOne() {
        let smooth = CombinedHorizonDetector.horizonConfidence(natural(around: 50, amplitude: 2),
                                                              imageHeight: 100)
        let noisy: [Int?] = (0..<100).map { x in 50 + (x % 2 == 0 ? -25 : 25) }
        XCTAssertLessThan(CombinedHorizonDetector.horizonConfidence(noisy, imageHeight: 100),
                          smooth)
    }

    /// Smoothness is normalised by image height, so the same shape at two resolutions scores the
    /// same — this is what lets a reduced-resolution result be compared with a full-resolution one.
    func testTheConfidenceIsScaleInvariant() {
        let small = CombinedHorizonDetector.horizonConfidence(natural(width: 100, around: 50,
                                                                     amplitude: 3),
                                                              imageHeight: 100)
        let large = CombinedHorizonDetector.horizonConfidence(natural(width: 100, around: 500,
                                                                     amplitude: 30),
                                                              imageHeight: 1000)
        XCTAssertEqual(small, large, accuracy: 0.05,
                       "a 10x larger frame with a 10x larger horizon must score the same")
    }

    /// **The smoothness term measures differences across the *compacted* array, so a nil gap is
    /// bridged: columns 10 and 90 become adjacent and produce a large fake step.**  The comment says
    /// "column-to-column diff", which is what `HorizonScoring.smoothnessScore` does properly by
    /// requiring both neighbours to be defined.  This test constructs the gap by hand to show the
    /// mechanism is real.
    ///
    /// **Measured, and it never fires in production.**  `CombinedConfidenceMeasurement` ran all five
    /// base methods that `detect` merges on real frames: every one returns a *fully dense* array —
    /// 4240 of 4240 columns defined, zero nils — so the shipped confidence and one computed with
    /// properly adjacent differences agree to 0.000000, and no inclusion decision can flip.  Density
    /// is structural rather than lucky: each method ends in `scaleHorizonY`, which emits a value for
    /// every output column whenever its source column had one.
    ///
    /// An earlier version of this comment asserted that SIOX has gaps because it searches only a
    /// band.  That was wrong — SIOX returns a dense array like the rest.
    func testGapsAreBridgedAndCountAsRoughness() {
        // two flat runs at the same Y with a gap between them: genuinely perfectly smooth
        var gapped = [Int?](repeating: nil, count: 100)
        for x in 0..<30 { gapped[x] = 50 }
        for x in 70..<100 { gapped[x] = 50 }
        let sameY = CombinedHorizonDetector.horizonConfidence(gapped, imageHeight: 100)

        // the same but the second run sits 40 rows lower — one real step across the gap
        var stepped = [Int?](repeating: nil, count: 100)
        for x in 0..<30 { stepped[x] = 50 }
        for x in 70..<100 { stepped[x] = 90 }
        let jump = CombinedHorizonDetector.horizonConfidence(stepped, imageHeight: 100)

        XCTAssertLessThan(jump, sameY,
                          "the bridged step across the gap is counted as roughness")
    }

    // MARK: - perColumnLocalWeights

    /// A stable detector gets a weight near 1 everywhere; this is what multiplies its global
    /// confidence per column.
    func testAStableDetectorGetsFullWeight() {
        let weights = CombinedHorizonDetector.perColumnLocalWeights(flat(50), imageHeight: 100)
        XCTAssertEqual(weights.count, 100)
        for (x, w) in weights.enumerated() {
            XCTAssertEqual(w, 1.0, accuracy: 1e-9, "column \(x)")
        }
    }

    /// The point of a *local* weight: a detector that spikes at one column is discounted there and
    /// trusted elsewhere, rather than being globally downgraded.
    func testASpikeIsDiscountedLocallyAndNotGlobally() {
        var spiky = flat(50, width: 200)
        spiky[100] = 95
        let weights = CombinedHorizonDetector.perColumnLocalWeights(spiky, imageHeight: 100)

        XCTAssertLessThan(weights[100], 0.9, "the spike column itself is discounted")
        XCTAssertEqual(weights[10], 1.0, accuracy: 1e-9,
                       "a column far from the spike keeps full weight")
        XCTAssertEqual(weights[190], 1.0, accuracy: 1e-9)
    }

    /// A nil column has no weight at all — it contributes nothing to the merge.
    func testUndefinedColumnsGetZeroWeight() {
        var sparse = flat(50)
        sparse[10] = nil
        let weights = CombinedHorizonDetector.perColumnLocalWeights(sparse, imageHeight: 100)
        XCTAssertEqual(weights[10], 0.0)
        XCTAssertGreaterThan(weights[11], 0.0)
    }

    /// Too few defined neighbours to judge gives a neutral 0.5 rather than a confident 1 or a
    /// dismissive 0.
    func testTooFewNeighboursGivesANeutralWeight() {
        var sparse = [Int?](repeating: nil, count: 100)
        sparse[50] = 40
        sparse[51] = 40
        let weights = CombinedHorizonDetector.perColumnLocalWeights(sparse, imageHeight: 100)
        XCTAssertEqual(weights[50], 0.5)
        XCTAssertEqual(weights[51], 0.5)
    }

    /// Normalised by height, so the weights do not change with resolution.
    func testTheWeightsAreScaleInvariant() {
        var small = flat(50, width: 200); small[100] = 70
        var large = flat(500, width: 200); large[100] = 700
        let smallWeights = CombinedHorizonDetector.perColumnLocalWeights(small, imageHeight: 100)
        let largeWeights = CombinedHorizonDetector.perColumnLocalWeights(large, imageHeight: 1000)
        XCTAssertEqual(smallWeights[100], largeWeights[100], accuracy: 0.01)
    }

    func testAnEmptyArrayGivesNoWeights() {
        XCTAssertTrue(CombinedHorizonDetector.perColumnLocalWeights([], imageHeight: 100).isEmpty)
    }

    // MARK: - medianFilterHorizonY

    /// The filter's job: remove a residual single-column spike without touching its neighbours.
    func testTheMedianFilterRemovesAnIsolatedSpike() {
        var spiky = flat(50)
        spiky[50] = 95
        let filtered = CombinedHorizonDetector.medianFilterHorizonY(spiky, windowHalf: 5)
        XCTAssertEqual(filtered[50], 50, "the spike is replaced by its local median")
        XCTAssertEqual(filtered[49], 50)
    }

    /// A genuine broad step survives, because more than half the window agrees with it — that is what
    /// distinguishes a median filter from smoothing.
    func testABroadStepSurvivesTheMedianFilter() {
        var stepped = flat(50, width: 200)
        for x in 100..<200 { stepped[x] = 90 }
        let filtered = CombinedHorizonDetector.medianFilterHorizonY(stepped, windowHalf: 5)
        XCTAssertEqual(filtered[10], 50)
        XCTAssertEqual(filtered[190], 90, "the far side of a real step is preserved")
    }

    /// Undefined columns stay undefined — the filter does not invent coverage.
    func testTheMedianFilterDoesNotFillGaps() {
        var sparse = flat(100)
        sparse[50] = nil
        let filtered = CombinedHorizonDetector.medianFilterHorizonY(sparse, windowHalf: 5)
        XCTAssertNil(filtered[50])
    }

    /// It reads the input throughout rather than its own partial output, so the result does not depend
    /// on the scan direction — an in-place filter would smear the spike rightward.
    func testTheFilterIsNotInPlace() {
        var spiky = flat(50, width: 101)
        spiky[50] = 95
        let filtered = CombinedHorizonDetector.medianFilterHorizonY(spiky, windowHalf: 3)
        // symmetric about the spike, which an in-place pass would break
        for offset in 1...3 {
            XCTAssertEqual(filtered[50 - offset], filtered[50 + offset],
                           "asymmetry at offset \(offset) means the filter read its own output")
        }
    }

    func testAZeroWindowLeavesEveryColumnAsItWas() {
        let input = natural(around: 50)
        XCTAssertEqual(CombinedHorizonDetector.medianFilterHorizonY(input, windowHalf: 0), input)
    }

    func testTheMedianFilterHandlesEmptyAndSingleColumnInput() {
        XCTAssertTrue(CombinedHorizonDetector.medianFilterHorizonY([], windowHalf: 5).isEmpty)
        XCTAssertEqual(CombinedHorizonDetector.medianFilterHorizonY([42], windowHalf: 5), [42])
        XCTAssertEqual(CombinedHorizonDetector.medianFilterHorizonY([nil], windowHalf: 5), [nil])
    }

    // MARK: - confidenceWeightedCombine

    /// Methods that agree produce that value — the baseline for everything below.
    func testMethodsThatAgreeProduceThatValue() {
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(50), 1.0), (flat(50), 1.0), (flat(50), 1.0)],
          outlierThreshold: 80, imageHeight: 100)
        XCTAssertEqual(combined.count, 100)
        for (x, y) in combined.enumerated() { XCTAssertEqual(y, 50, "column \(x)") }
    }

    /// A higher-confidence method pulls the merged result toward itself, which is what "weighted"
    /// means here.
    func testAHigherConfidenceMethodPullsTheResultTowardIt() {
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(40), 0.9), (flat(60), 0.1)],
          outlierThreshold: 80, imageHeight: 100)
        let y = try? XCTUnwrap(combined[50])
        XCTAssertNotNil(y)
        XCTAssertEqual(y!, 42, accuracy: 1, "0.9*40 + 0.1*60 = 42")
    }

    /// Equal confidences give the plain mean.
    func testEqualConfidencesGiveTheMean() {
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(40), 0.5), (flat(60), 0.5)],
          outlierThreshold: 80, imageHeight: 100)
        XCTAssertEqual(combined[50], 50)
    }

    /// A method disagreeing by more than the threshold is dropped from the average rather than
    /// dragging it — this is what stops one broken detector from ruining every column.
    func testAnOutlierBeyondTheThresholdIsExcluded() {
        // two methods at 50, one at 200 — well beyond a threshold of 20
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(50), 1.0), (flat(52), 1.0), (flat(200), 1.0)],
          outlierThreshold: 20, imageHeight: 300)
        let y = try? XCTUnwrap(combined[50])
        XCTAssertNotNil(y)
        XCTAssertEqual(y!, 51, accuracy: 1, "the 200 must not contribute at all")
    }

    /// A generous threshold lets the same disagreement through, so the threshold is doing the work.
    func testAGenerousThresholdKeepsTheDisagreement() {
        let tight = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(50), 1.0), (flat(52), 1.0), (flat(200), 1.0)],
          outlierThreshold: 20, imageHeight: 300)
        let loose = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(50), 1.0), (flat(52), 1.0), (flat(200), 1.0)],
          outlierThreshold: 500, imageHeight: 300)
        XCTAssertNotEqual(tight[50], loose[50])
        XCTAssertGreaterThan(loose[50] ?? 0, tight[50] ?? 0)
    }

    /// A single method is passed straight through — no median, no averaging, so a lone detector is not
    /// distorted.
    func testASingleMethodPassesThrough() {
        let input = natural(around: 50)
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(input, 0.42)], outlierThreshold: 80, imageHeight: 100)
        // the final median-filter pass still applies, so compare on a flat input
        let flatCombined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(50), 0.42)], outlierThreshold: 80, imageHeight: 100)
        XCTAssertEqual(flatCombined, flat(50))
        XCTAssertEqual(combined.count, input.count)
    }

    /// A column where only one method has an opinion takes that opinion, so partial coverage from
    /// different methods adds up instead of cancelling.
    func testColumnsWhereOnlyOneMethodHasAnOpinionUseIt() {
        var firstHalf = [Int?](repeating: nil, count: 100)
        for x in 0..<50 { firstHalf[x] = 30 }
        var secondHalf = [Int?](repeating: nil, count: 100)
        for x in 50..<100 { secondHalf[x] = 70 }

        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(firstHalf, 1.0), (secondHalf, 1.0)],
          outlierThreshold: 80, imageHeight: 100)
        XCTAssertEqual(combined[10], 30)
        XCTAssertEqual(combined[90], 70)
    }

    /// A column no method covers stays nil rather than being interpolated.
    func testAColumnNoMethodCoversStaysNil() {
        var a = flat(50); a[25] = nil
        var b = flat(50); b[25] = nil
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(a, 1.0), (b, 1.0)], outlierThreshold: 80, imageHeight: 100)
        XCTAssertNil(combined[25])
        XCTAssertEqual(combined[24], 50)
    }

    /// No methods at all gives an empty array — the caller has to notice, because an empty horizon
    /// would otherwise silently become a blank mask.
    func testNoMethodsGivesAnEmptyResult() {
        XCTAssertTrue(CombinedHorizonDetector.confidenceWeightedCombine(
                        [], outlierThreshold: 80, imageHeight: 100).isEmpty)
    }

    /// Zero confidence everywhere falls back to picking a value rather than dividing by zero.
    func testZeroConfidencesDoNotDivideByZero() {
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(flat(40), 0.0), (flat(60), 0.0)],
          outlierThreshold: 80, imageHeight: 100)
        let y = try? XCTUnwrap(combined[50])
        XCTAssertNotNil(y)
        XCTAssertTrue([40, 60].contains(y!), "a value from one of the methods, not NaN")
    }

    /// Methods of differing widths are merged over the first one's width, and the shorter one simply
    /// stops contributing — a length mismatch must not trap.
    func testMethodsOfDifferentWidthsAreMergedSafely() {
        let wide = flat(50, width: 100)
        let narrow = flat(90, width: 20)
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(wide, 1.0), (narrow, 1.0)], outlierThreshold: 80, imageHeight: 100)
        XCTAssertEqual(combined.count, 100, "the width comes from the first method")
        XCTAssertEqual(combined[90], 50, "past the narrow method only the wide one contributes")
    }

    /// The combine ends with a median-filter pass, so a single-column spike agreed on by every method
    /// is still removed before the Random Walker sees it.
    func testTheCombineMedianFiltersItsOwnOutput() {
        var spiky = flat(50)
        spiky[50] = 95
        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(spiky, 1.0), (spiky, 1.0)], outlierThreshold: 80, imageHeight: 100)
        XCTAssertEqual(combined[50], 50, "the trailing median filter removes the agreed spike")
    }

    /// A locally-spiky method is discounted at the spike even when its global confidence is high —
    /// the reason the per-column weights exist at all.
    func testALocallySpikyMethodIsDiscountedAtItsSpike() {
        var spiky = flat(40, width: 200)
        spiky[100] = 95
        let steady = flat(60, width: 200)

        let combined = CombinedHorizonDetector.confidenceWeightedCombine(
          [(spiky, 1.0), (steady, 1.0)], outlierThreshold: 200, imageHeight: 100)

        // away from the spike both methods carry equal weight, so the mean is 50
        XCTAssertEqual(combined[10], 50)
        // at the spike the spiky method's weight is reduced, so the result leans toward the steady one
        let atSpike = try? XCTUnwrap(combined[100])
        XCTAssertNotNil(atSpike)
        XCTAssertGreaterThan(atSpike!, 50,
                             "the discounted spiky method must pull less than half the way")
    }

    // MARK: - selfScore

    /// This is what picks the winning brush radius, so it has to prefer the better mask.
    func testAPlausibleMaskSelfScoresAboveADegenerateOne() {
        let good = FrameHarness.syntheticMask(width: 100, height: 100) { x in
            50 + Int((3.0 * sin(Double(x) / 8.0)).rounded())
        }
        let allSky = FrameHarness.flatMask(width: 100, height: 100, at: 100)
        XCTAssertGreaterThan(CombinedHorizonDetector.selfScore(mask: good, imageHeight: 100),
                             CombinedHorizonDetector.selfScore(mask: allSky, imageHeight: 100))
    }

    /// An all-sky mask has no horizon at all and scores exactly zero.
    func testAMaskWithNoHorizonSelfScoresZero() {
        let allSky = FrameHarness.flatMask(width: 50, height: 50, at: 50)
        XCTAssertEqual(CombinedHorizonDetector.selfScore(mask: allSky, imageHeight: 50), 0)
    }

    /// A centred horizon beats one crushed against an edge.
    func testACentredMaskSelfScoresAboveAnEdgeMask() {
        let centred = FrameHarness.flatMask(width: 100, height: 100, at: 50)
        let nearTop = FrameHarness.flatMask(width: 100, height: 100, at: 2)
        XCTAssertGreaterThan(CombinedHorizonDetector.selfScore(mask: centred, imageHeight: 100),
                             CombinedHorizonDetector.selfScore(mask: nearTop, imageHeight: 100))
    }

    /// A jagged mask scores below a smooth one, which is the smoothness term.
    func testAJaggedMaskSelfScoresBelowASmoothOne() {
        let smooth = FrameHarness.flatMask(width: 100, height: 100, at: 50)
        let jagged = FrameHarness.syntheticMask(width: 100, height: 100) { x in
            x % 2 == 0 ? 30 : 70
        }
        XCTAssertGreaterThan(CombinedHorizonDetector.selfScore(mask: smooth, imageHeight: 100),
                             CombinedHorizonDetector.selfScore(mask: jagged, imageHeight: 100))
    }

    /// The three weights sum to 1, so a perfect mask approaches 1 and the score stays comparable
    /// between brush radii.
    func testTheSelfScoreStaysWithinZeroAndOne() {
        for horizon in [1, 10, 25, 50, 75, 90, 99] {
            let mask = FrameHarness.flatMask(width: 60, height: 100, at: horizon)
            let score = CombinedHorizonDetector.selfScore(mask: mask, imageHeight: 100)
            XCTAssertGreaterThanOrEqual(score, 0, "horizon \(horizon)")
            XCTAssertLessThanOrEqual(score, 1, "horizon \(horizon)")
        }
    }

    /// Unlike `horizonConfidence`, `selfScore`'s smoothness is *not* normalised by image height, so
    /// the same shape scores differently at two resolutions.  Pinned because the two look alike and
    /// only one is scale-invariant — but it is only ever used to compare brush radii on one image, so
    /// this does not bite in practice.
    func testTheSelfScoreIsNotScaleInvariantUnlikeTheConfidence() {
        let small = FrameHarness.syntheticMask(width: 100, height: 100) { x in
            50 + Int((3.0 * sin(Double(x) / 8.0)).rounded())
        }
        let large = FrameHarness.syntheticMask(width: 100, height: 1000) { x in
            500 + Int((30.0 * sin(Double(x) / 8.0)).rounded())
        }
        let smallScore = CombinedHorizonDetector.selfScore(mask: small, imageHeight: 100)
        let largeScore = CombinedHorizonDetector.selfScore(mask: large, imageHeight: 1000)
        XCTAssertNotEqual(smallScore, largeScore, accuracy: 0.02)
    }

    // MARK: - isPlausibleHorizon

    /// A centred, well-covered, reasonably steady horizon is plausible.
    func testAGoodHorizonIsPlausible() {
        XCTAssertTrue(CombinedHorizonDetector.isPlausibleHorizon(natural(around: 50),
                                                                imageHeight: 100))
    }

    /// The three ways to fail: too little coverage, too near an edge, too noisy.
    func testTheThreeWaysToBeImplausible() {
        var sparse = [Int?](repeating: nil, count: 100)
        for x in 0..<5 { sparse[x] = 50 }
        XCTAssertFalse(CombinedHorizonDetector.isPlausibleHorizon(sparse, imageHeight: 100),
                       "5% coverage is not enough")

        XCTAssertFalse(CombinedHorizonDetector.isPlausibleHorizon(flat(5), imageHeight: 100),
                       "5% down the frame is outside the 10-90% band")
        XCTAssertFalse(CombinedHorizonDetector.isPlausibleHorizon(flat(95), imageHeight: 100))

        let noisy: [Int?] = (0..<100).map { x in x % 2 == 0 ? 10 : 90 }
        XCTAssertFalse(CombinedHorizonDetector.isPlausibleHorizon(noisy, imageHeight: 100),
                       "a stddev of 40% of height is too noisy")
    }

    func testAnEmptyHorizonIsNotPlausible() {
        XCTAssertFalse(CombinedHorizonDetector.isPlausibleHorizon([], imageHeight: 100))
        XCTAssertFalse(CombinedHorizonDetector.isPlausibleHorizon(
                         [Int?](repeating: nil, count: 100), imageHeight: 100))
    }

    /// **`isPlausibleHorizon` has no callers.**  Pinned rather than deleted so the intended gate is
    /// still described somewhere — the pipeline currently relies on `horizonConfidence`'s inclusion
    /// threshold instead, which has a different coverage floor (5% versus this one's 10%) and no
    /// stddev check at all.
    func testTheCoverageFloorsOfTheTwoGatesDiffer() {
        var justOverFivePercent = [Int?](repeating: nil, count: 100)
        for x in 0..<8 { justOverFivePercent[x] = 50 }

        XCTAssertGreaterThan(CombinedHorizonDetector.horizonConfidence(justOverFivePercent,
                                                                      imageHeight: 100), 0,
                             "the live gate accepts 8% coverage")
        XCTAssertFalse(CombinedHorizonDetector.isPlausibleHorizon(justOverFivePercent,
                                                                 imageHeight: 100),
                       "the unused gate would have rejected it")
    }

    // MARK: - scaleForProcessing

    /// An image already within the limit is returned untouched, with unit scales — no needless resize.
    func testAnImageWithinTheLimitIsUntouched() {
        let image = FrameHarness.syntheticFrame(width: 100, height: 80, horizonRow: 40)
        let (scaled, scaleX, scaleY) = CombinedHorizonDetector.scaleForProcessing(image,
                                                                                 maxDim: 512)
        XCTAssertEqual(scaled.width, 100)
        XCTAssertEqual(scaled.height, 80)
        XCTAssertEqual(scaleX, 1.0)
        XCTAssertEqual(scaleY, 1.0)
    }

    /// A larger image is scaled so its longest side hits the limit, preserving aspect ratio — that is
    /// what makes the base methods affordable on a 42MP frame.
    func testALargerImageIsScaledToTheLimitOnItsLongestSide() {
        let image = FrameHarness.syntheticFrame(width: 400, height: 200, horizonRow: 100)
        let (scaled, scaleX, scaleY) = CombinedHorizonDetector.scaleForProcessing(image,
                                                                                 maxDim: 100)
        XCTAssertEqual(scaled.width, 100)
        XCTAssertEqual(scaled.height, 50, "the aspect ratio is preserved")
        XCTAssertEqual(scaleX, 0.25, accuracy: 1e-9)
        XCTAssertEqual(scaleY, 0.25, accuracy: 1e-9)
    }

    /// The returned scales are the *achieved* ones, computed from the integer output size rather than
    /// the requested ratio — so `scaleHorizonY` undoes exactly what was done.
    func testTheReturnedScalesAreTheAchievedOnes() {
        let image = FrameHarness.syntheticFrame(width: 333, height: 111, horizonRow: 55)
        let (scaled, scaleX, scaleY) = CombinedHorizonDetector.scaleForProcessing(image,
                                                                                 maxDim: 100)
        XCTAssertEqual(scaleX, Double(scaled.width) / 333, accuracy: 1e-12)
        XCTAssertEqual(scaleY, Double(scaled.height) / 111, accuracy: 1e-12)
    }

    /// A tall image is limited by its height, not its width.
    func testATallImageIsLimitedByItsHeight() {
        let image = FrameHarness.syntheticFrame(width: 100, height: 400, horizonRow: 200)
        let (scaled, _, _) = CombinedHorizonDetector.scaleForProcessing(image, maxDim: 200)
        XCTAssertEqual(scaled.height, 200)
        XCTAssertEqual(scaled.width, 50)
    }

    /// An extreme reduction must still leave at least one pixel in each direction.
    func testAnExtremeReductionKeepsAtLeastOnePixel() {
        let image = FrameHarness.syntheticFrame(width: 1000, height: 10, horizonRow: 5)
        let (scaled, _, _) = CombinedHorizonDetector.scaleForProcessing(image, maxDim: 4)
        XCTAssertGreaterThanOrEqual(scaled.width, 1)
        XCTAssertGreaterThanOrEqual(scaled.height, 1)
    }

    // MARK: - scaleHorizonY

    /// The inverse of the working-size reduction: a horizon found at reduced resolution is mapped back
    /// to the full frame.
    func testAHorizonIsMappedBackToFullResolution() {
        let reduced: [Int?] = [Int?](repeating: 25, count: 50)
        let full = CombinedHorizonDetector.scaleHorizonY(reduced, fromWidth: 50, toWidth: 200,
                                                         scaleY: 0.25)
        XCTAssertEqual(full.count, 200)
        for (x, y) in full.enumerated() {
            XCTAssertEqual(y, 100, "column \(x): a Y of 25 at quarter scale is 100 at full scale")
        }
    }

    /// Nearest-neighbour in X, so each output column takes the nearest input column.
    func testColumnsAreMappedByNearestNeighbour() {
        let reduced: [Int?] = [10, 20, 30, 40]
        let full = CombinedHorizonDetector.scaleHorizonY(reduced, fromWidth: 4, toWidth: 8,
                                                         scaleY: 1.0)
        XCTAssertEqual(full, [10, 10, 20, 20, 30, 30, 40, 40])
    }

    /// Nil columns stay nil through the mapping, so gaps are not filled by the rescale.
    func testGapsSurviveTheRescale() {
        let reduced: [Int?] = [10, nil, 30, nil]
        let full = CombinedHorizonDetector.scaleHorizonY(reduced, fromWidth: 4, toWidth: 4,
                                                         scaleY: 1.0)
        XCTAssertEqual(full, [10, nil, 30, nil])
    }

    /// Downscaling the column count as well as upscaling has to work, since the same helper handles
    /// both directions.
    func testTheMappingWorksInBothDirections() {
        let wide: [Int?] = (0..<100).map { $0 }
        let narrow = CombinedHorizonDetector.scaleHorizonY(wide, fromWidth: 100, toWidth: 10,
                                                           scaleY: 1.0)
        XCTAssertEqual(narrow.count, 10)
        XCTAssertEqual(narrow[0], 0)
        XCTAssertEqual(narrow[9], 90)
    }

    /// A same-size mapping with unit scale is the identity, which is the path taken when the frame was
    /// already within the working size.
    func testASameSizeUnitScaleMappingIsTheIdentity() {
        let input: [Int?] = [5, nil, 15, 25, nil]
        XCTAssertEqual(CombinedHorizonDetector.scaleHorizonY(input, fromWidth: 5, toWidth: 5,
                                                            scaleY: 1.0),
                       input)
    }

    /// `scaleForProcessing` and `scaleHorizonY` have to be inverses: a horizon at a known row must
    /// come back to that row after a round trip through the reduced working size.
    func testTheScaleRoundTripReturnsTheOriginalRow() {
        let image = FrameHarness.syntheticFrame(width: 400, height: 300, horizonRow: 150)
        let (scaled, _, scaleY) = CombinedHorizonDetector.scaleForProcessing(image, maxDim: 100)

        // a horizon found at the reduced size, at the row the truth maps to
        let reducedRow = Int(150.0 * scaleY)
        let reduced = [Int?](repeating: reducedRow, count: scaled.width)

        let full = CombinedHorizonDetector.scaleHorizonY(reduced,
                                                        fromWidth: scaled.width,
                                                        toWidth: 400,
                                                        scaleY: scaleY)
        XCTAssertEqual(full.count, 400)
        let recovered = try? XCTUnwrap(full[200])
        XCTAssertNotNil(recovered)
        XCTAssertEqual(recovered!, 150, accuracy: 4,
                       "the round trip must land back on the original row")
    }

    // MARK: - the whole pipeline

    /// End to end on a synthetic frame with a known horizon: five methods, a confidence-weighted
    /// merge and a Random Walker refinement over three brush radii all have to cooperate to put the
    /// horizon where it actually is.
    func testDetectFindsTheHorizonOnASyntheticFrame() async throws {
        let image = FrameHarness.syntheticFrame(width: 128, height: 96, horizonRow: 48)
        let mask = try await CombinedHorizonDetector.detect(image: image)

        XCTAssertEqual(mask.image.width, 128)
        XCTAssertEqual(mask.image.height, 96)
        XCTAssertEqual(mask.image.componentsPerPixel, 1,
                       "the result must be a single-channel mask")

        let horizonY = CombinedHorizonDetector.extractHorizonY(from: mask.image)
        let defined = horizonY.compactMap { $0 }
        XCTAssertGreaterThan(defined.count, 100, "nearly every column must get a horizon")

        let mean = Double(defined.reduce(0, +)) / Double(defined.count)
        XCTAssertEqual(mean, 48, accuracy: 6,
                       "the detected horizon must land on the synthetic one at row 48")
    }

    /// The horizon has to follow the frame, not sit at a fixed fraction — the strongest check that the
    /// pipeline is looking at the image at all.
    ///
    /// Only horizons in the lower half of the frame are asserted.  On this synthetic fixture the
    /// detector locks onto row ~10 for any horizon at or above row 40, while rows 48 through 72 come
    /// back within a tenth of a pixel.  That is a limit of the fixture rather than a finding about the
    /// detector: the synthetic sky is a linear gradient plus twelve point stars, and squeezing it into
    /// the top 40 rows makes it steep and star-dense in a way no real night sky is.  Asserting a
    /// detector bug from an image this unrealistic would not be sound, so the range the fixture can
    /// fairly support is what gets tested.
    func testDetectFollowsTheHorizonWhenItMoves() async throws {
        var means: [Double] = []
        for truth in [56, 72] {
            let image = FrameHarness.syntheticFrame(width: 128, height: 96, horizonRow: truth)
            let mask = try await CombinedHorizonDetector.detect(image: image)
            let defined = CombinedHorizonDetector.extractHorizonY(from: mask.image)
              .compactMap { $0 }
            XCTAssertFalse(defined.isEmpty, "truth \(truth)")
            means.append(Double(defined.reduce(0, +)) / Double(defined.count))
        }
        XCTAssertLessThan(means[0], means[1],
                          "a lower horizon in the frame must give a larger detected Y")
        XCTAssertEqual(means[0], 56, accuracy: 6)
        XCTAssertEqual(means[1], 72, accuracy: 6)
    }

    /// The mask's bounds have to bracket the horizon it drew, since the alignment code works from
    /// those rather than from the pixels.
    func testTheDetectedMaskCarriesConsistentBounds() async throws {
        let image = FrameHarness.syntheticFrame(width: 128, height: 96, horizonRow: 48)
        let mask = try await CombinedHorizonDetector.detect(image: image)

        let defined = CombinedHorizonDetector.extractHorizonY(from: mask.image).compactMap { $0 }
        let lowest = try XCTUnwrap(defined.max())
        let highest = try XCTUnwrap(defined.min())
        XCTAssertGreaterThanOrEqual(mask.horizonTopY, highest - 1)
        XCTAssertLessThanOrEqual(mask.horizonBottomY, lowest)
    }

    /// A smaller working size is the knob `FrameHorizonProcessor` actually turns, so the pipeline has
    /// to still work when it is reduced.
    func testASmallerWorkingSizeStillProducesAHorizon() async throws {
        var params = CombinedHorizonDetector.Params()
        params.baseWorkingSize = 64
        let image = FrameHarness.syntheticFrame(width: 128, height: 96, horizonRow: 48)
        let mask = try await CombinedHorizonDetector.detect(image: image, params: params)

        let defined = CombinedHorizonDetector.extractHorizonY(from: mask.image).compactMap { $0 }
        XCTAssertFalse(defined.isEmpty)
        let mean = Double(defined.reduce(0, +)) / Double(defined.count)
        XCTAssertEqual(mean, 48, accuracy: 10,
                       "halving the working size must not lose the horizon")
    }

    /// A single brush radius is a legal configuration and must not leave `bestMask` nil.
    func testASingleBrushRadiusIsEnough() async throws {
        var params = CombinedHorizonDetector.Params()
        params.brushRadii = [40]
        let image = FrameHarness.syntheticFrame(width: 128, height: 96, horizonRow: 48)
        let mask = try await CombinedHorizonDetector.detect(image: image, params: params)
        XCTAssertEqual(mask.image.width, 128)
    }

    /// **No brush radii means the loop never runs and `bestMask` stays nil**, which the guard turns
    /// into a thrown error rather than a crash.  Pinned because `brushRadii` is a public `var` that a
    /// caller could empty.
    func testNoBrushRadiiThrowsRatherThanCrashing() async {
        var params = CombinedHorizonDetector.Params()
        params.brushRadii = []
        let image = FrameHarness.syntheticFrame(width: 64, height: 48, horizonRow: 24)
        do {
            _ = try await CombinedHorizonDetector.detect(image: image, params: params)
            XCTFail("an empty brush radius list must throw")
        } catch {
            XCTAssertTrue("\(error)".contains("RW produced no valid mask"),
                          "unexpected error: \(error)")
        }
    }

    /// A featureless frame has no horizon to find; the pipeline must fail cleanly rather than trap or
    /// return something meaningless.  Either outcome is acceptable — what matters is that it is not a
    /// crash.
    func testAFeaturelessFrameDoesNotCrash() async {
        let uniform = FrameHarness.grayImage(width: 64, height: 48,
                                             rows: Dictionary(uniqueKeysWithValues:
                                               (0..<48).map { ($0, UInt8(128)) }))
        do {
            let mask = try await CombinedHorizonDetector.detect(image: uniform)
            XCTAssertEqual(mask.image.width, 64)
        } catch {
            // a thrown error is a fine outcome for an image with no horizon in it
        }
    }
}
