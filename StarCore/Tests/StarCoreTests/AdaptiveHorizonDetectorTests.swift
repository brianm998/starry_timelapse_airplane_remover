import XCTest
import Foundation
@testable import StarCore

/// `AdaptiveHorizonDetector.swift` is the scoring and search-narrowing layer of horizon detection:
/// `FrameHorizonProcessor` generates candidate masks over a grid of crop amounts and DP parameters,
/// scores each one here, and keeps the highest `totalScore`.  Everything in the file is pure, but it
/// had no coverage at all — and it decides which horizon a frame ends up with, so a wrong score is a
/// wrong horizon, which is a wrong sky mask, which changes which outliers are even considered.
///
/// Several tests below pin behaviour that disagrees with the doc comment above the code.  Where that
/// happens the test says so and says which one this codebase actually relies on; none of them are
/// changed here, because the scores feed decisions whose thresholds were tuned against the current
/// numbers.
final class AdaptiveHorizonDetectorTests: XCTestCase {

    // MARK: - fixtures

    private func flatHorizon(width: Int, at y: Int) -> [Int?] {
        [Int?](repeating: y, count: width)
    }

    /// A gently varying line, which is what a real horizon looks like.
    private func naturalHorizon(width: Int, around y: Int, amplitude: Int = 4) -> [Int?] {
        (0..<width).map { x in
            y + Int((Double(amplitude) * sin(Double(x) / 9.0)).rounded())
        }
    }

    // MARK: - HorizonScore.totalScore

    /// The four additive weights are documented as 0.30/0.30/0.15/0.25 and `cropBoundaryScore` as a
    /// multiplier.  Everything downstream compares candidates on `totalScore`, so the arithmetic is
    /// worth pinning exactly.
    func testTotalScoreAppliesTheDocumentedWeights() {
        let score = HorizonScore(smoothnessScore: 1,
                                 edgeAlignmentScore: 1,
                                 coverageScore: 1,
                                 localConsistencyScore: 1,
                                 cropBoundaryScore: 1)
        XCTAssertEqual(score.totalScore, 1.0, accuracy: 1e-12,
                       "the four additive weights must sum to 1")

        let single = HorizonScore(smoothnessScore: 1,
                                  edgeAlignmentScore: 0,
                                  coverageScore: 0,
                                  localConsistencyScore: 0,
                                  cropBoundaryScore: 1)
        XCTAssertEqual(single.totalScore, 0.30, accuracy: 1e-12)

        let coverageOnly = HorizonScore(smoothnessScore: 0,
                                        edgeAlignmentScore: 0,
                                        coverageScore: 1,
                                        localConsistencyScore: 0,
                                        cropBoundaryScore: 1)
        XCTAssertEqual(coverageOnly.totalScore, 0.15, accuracy: 1e-12)
    }

    /// `cropBoundaryScore` is a multiplier rather than another additive term, deliberately: a mask
    /// that snapped to the crop boundary scores well on every other axis, so an additive penalty
    /// could not outweigh them.
    func testTheCropBoundaryScoreMultipliesTheWholeTotal() {
        let full = HorizonScore(smoothnessScore: 0.8, edgeAlignmentScore: 0.6,
                                coverageScore: 1, localConsistencyScore: 0.5,
                                cropBoundaryScore: 1)
        let halved = HorizonScore(smoothnessScore: 0.8, edgeAlignmentScore: 0.6,
                                  coverageScore: 1, localConsistencyScore: 0.5,
                                  cropBoundaryScore: 0.5)
        XCTAssertEqual(halved.totalScore, full.totalScore * 0.5, accuracy: 1e-12)

        let suppressed = HorizonScore(smoothnessScore: 1, edgeAlignmentScore: 1,
                                      coverageScore: 1, localConsistencyScore: 1,
                                      cropBoundaryScore: 0)
        XCTAssertEqual(suppressed.totalScore, 0,
                       "a zero crop-boundary score must suppress an otherwise perfect candidate")
    }

    func testTheDescriptionNamesEveryComponent() {
        let text = HorizonScore(smoothnessScore: 0.1, edgeAlignmentScore: 0.2,
                                coverageScore: 0.3, localConsistencyScore: 0.4,
                                cropBoundaryScore: 0.5).description
        for fragment in ["total=", "smooth=", "edge=", "coverage=", "consist=", "cropBnd="] {
            XCTAssertTrue(text.contains(fragment), "description is missing \(fragment)")
        }
    }

    // MARK: - smoothnessScore

    /// A perfectly flat line scores zero, not one.  This is the point of the flatness term: a
    /// constant horizon is nearly always the crop boundary rather than the real skyline.
    func testAPerfectlyFlatHorizonScoresZeroForSmoothness() {
        let flat = flatHorizon(width: 64, at: 30)
        XCTAssertEqual(HorizonScoring.smoothnessScore(horizonY: flat), 0, accuracy: 1e-12,
                       "zero derivative variance is the crop-boundary signature")
    }

    /// A gently varying line beats a flat one, which is the flatness half of the penalty working.
    func testAGentleHorizonBeatsAFlatOne() {
        let flat = flatHorizon(width: 128, at: 40)
        let gentle = naturalHorizon(width: 128, around: 40, amplitude: 5)
        XCTAssertGreaterThan(HorizonScoring.smoothnessScore(horizonY: gentle),
                             HorizonScoring.smoothnessScore(horizonY: flat))
    }

    /// **The score ranks a wild sawtooth above a gentle real horizon.**  A ±30px column-to-column
    /// alternation — the least plausible horizon imaginable — scores about 0.016, while a gentle 5px
    /// sinusoid scores about 0.012.
    ///
    /// This follows from where the curve peaks (see the next test): the flatness term is still
    /// suppressing anything with a derivative spread below ~1px far harder than the roughness term
    /// suppresses a spread of 60px.  So "smoothness" is not measuring what its name says over the
    /// range real horizons occupy.
    ///
    /// Not changed here.  Reshaping this curve moves the winning candidate on every frame, and there
    /// is no way to tell whether the result is better without re-running against the reference
    /// horizon masks — that is a tuning decision, and the reference sequences are the only evidence
    /// that could settle it.
    func testAJaggedSawtoothOutScoresAGentleHorizon() {
        let gentle = naturalHorizon(width: 128, around: 40, amplitude: 5)
        let jagged: [Int?] = (0..<128).map { x in 40 + (x % 2 == 0 ? -30 : 30) }

        let gentleScore = HorizonScoring.smoothnessScore(horizonY: gentle)
        let jaggedScore = HorizonScoring.smoothnessScore(horizonY: jagged)

        XCTAssertGreaterThan(jaggedScore, gentleScore,
                             "pinning the current ordering, which is backwards from the intent")
        XCTAssertEqual(gentleScore, 0.0122, accuracy: 0.002)
        XCTAssertEqual(jaggedScore, 0.0164, accuracy: 0.002)
    }

    /// **The doc comment is wrong about both the location and the height of the peak.**  It says the
    /// score "peaks around stddev ≈ 2–4 pixels"; it actually peaks near stddev ≈ 5.2, and the peak
    /// value is only ~0.125.
    ///
    /// That ceiling is the part that matters.  `totalScore` weights smoothness at 0.30, the same as
    /// edge alignment, but edge alignment, coverage and local consistency can all reach 1.0 while
    /// smoothness can never exceed ~0.125.  So smoothness contributes at most 0.0375 of the total —
    /// it is effectively weighted about an eighth of what the weights say.
    ///
    /// Left alone: raising it would change the winning candidate on real sequences, and the
    /// thresholds around it were tuned against these numbers.
    func testSmoothnessCanNeverReachOneAndPeaksNearFiveNotThree() {
        // sweep stddev by building lines with a known column-to-column derivative spread
        var best = (stddev: 0.0, score: 0.0)
        for step in stride(from: 0.0, through: 20.0, by: 0.25) {
            // alternating +/- step gives derivative values of ±2*step about a mean of 0
            let line: [Int?] = (0..<200).map { x in
                60 + Int((Double(x % 2 == 0 ? 1 : -1) * step / 2).rounded())
            }
            let score = HorizonScoring.smoothnessScore(horizonY: line)
            if score > best.score { best = (step, score) }
        }

        XCTAssertLessThan(best.score, 0.13,
                          "smoothness cannot approach 1.0, so its documented 0.30 weight is " +
                          "effectively about 0.0375")

        // and directly: the analytic peak of (1/(1+s)) * (1 - exp(-s^2/18)) is near s = 5.2
        func atStddev(_ s: Double) -> Double {
            (1.0 / (1.0 + s)) * (1.0 - exp(-(s * s) / 18.0))
        }
        XCTAssertGreaterThan(atStddev(5.2), atStddev(3.0),
                             "the peak is not in the documented 2-4 range")
        XCTAssertGreaterThan(atStddev(5.2), atStddev(8.0))
        XCTAssertEqual(atStddev(5.2), 0.1252, accuracy: 0.002)
    }

    /// Fewer than two usable derivatives is not enough to judge, so the score is neutral rather than
    /// zero — otherwise a mask with one defined column would be scored as maximally flat.
    func testTooFewDefinedColumnsGiveANeutralScore() {
        XCTAssertEqual(HorizonScoring.smoothnessScore(horizonY: []), 0.5)
        XCTAssertEqual(HorizonScoring.smoothnessScore(horizonY: [10]), 0.5)
        XCTAssertEqual(HorizonScoring.smoothnessScore(horizonY: [10, 12]), 0.5,
                       "one derivative is still not enough")
        XCTAssertEqual(HorizonScoring.smoothnessScore(horizonY: [nil, nil, 5, nil, nil]), 0.5)
    }

    /// Only adjacent pairs where *both* columns are defined contribute, so a gap does not fabricate
    /// a huge derivative across it.
    func testGapsDoNotCreateSpuriousDerivatives() {
        let withGap: [Int?] = [10, 11, nil, 90, 91, 92]
        let withoutBridge: [Int?] = [10, 11, 91, 92]
        // the gap version must not be scored as if 11 -> 90 were a real step
        XCTAssertNotEqual(HorizonScoring.smoothnessScore(horizonY: withGap),
                          HorizonScoring.smoothnessScore(horizonY: withoutBridge))
    }

    /// A steady slope has zero derivative *variance*, so it scores as flat — the metric measures
    /// variation in the slope, not the slope itself.  Worth pinning: a tilted horizon from a camera
    /// that is not level is scored exactly like a crop-boundary artefact.
    func testASteadySlopeIsScoredAsFlat() {
        let gentleSlope: [Int?] = (0..<100).map { 20 + $0 }          // +1 per column
        let steepSlope: [Int?] = (0..<100).map { 20 + $0 * 3 }       // +3 per column
        XCTAssertEqual(HorizonScoring.smoothnessScore(horizonY: gentleSlope), 0, accuracy: 1e-12,
                       "a constant slope has no derivative variance")
        XCTAssertEqual(HorizonScoring.smoothnessScore(horizonY: steepSlope), 0, accuracy: 1e-12,
                       "the slope's steepness is invisible to the score")
    }

    func testTheNaturalStddevParameterMovesThePeak() {
        let line = naturalHorizon(width: 200, around: 50, amplitude: 6)
        let tight = HorizonScoring.smoothnessScore(horizonY: line, naturalStddev: 1.0)
        let loose = HorizonScoring.smoothnessScore(horizonY: line, naturalStddev: 12.0)
        XCTAssertGreaterThan(tight, loose,
                             "a smaller naturalStddev is more forgiving of a smooth line")
    }

    // MARK: - extractHorizonYPerColumn

    func testTheHorizonIsTheTopmostGroundPixelInEachColumn() {
        let mask = FrameHarness.syntheticMask(width: 32, height: 32) { x in 6 + x / 8 }
        let horizonY = HorizonScoring.extractHorizonYPerColumn(from: mask)
        XCTAssertEqual(horizonY.count, 32)
        for x in 0..<32 {
            XCTAssertEqual(horizonY[x], 6 + x / 8, "column \(x)")
        }
    }

    /// An all-sky column has no ground pixel, so it is nil — the only genuinely undefined case.
    func testAnAllSkyColumnIsNil() {
        let mask = FrameHarness.syntheticMask(width: 8, height: 16) { x in
            x == 3 ? 16 : 8      // column 3 is sky all the way down
        }
        let horizonY = HorizonScoring.extractHorizonYPerColumn(from: mask)
        XCTAssertNil(horizonY[3])
        XCTAssertEqual(horizonY[0], 8)
    }

    /// **The doc comment claims an all-ground column is nil too.  It is not** — the scan finds ground
    /// at row 0 and returns 0.  That is the more useful answer here (`coverageScore` sees an average
    /// Y near the top and penalises it as degenerate, which an all-nil column would not trigger),
    /// but any caller taking the comment at face value would be wrong.
    func testAnAllGroundColumnIsZeroNotNil() {
        let mask = FrameHarness.syntheticMask(width: 8, height: 16) { x in
            x == 5 ? 0 : 8       // column 5 is ground all the way up
        }
        let horizonY = HorizonScoring.extractHorizonYPerColumn(from: mask)
        XCTAssertEqual(horizonY[5], 0, "the doc says nil; the scan finds ground at row 0")
        XCTAssertNotNil(horizonY[5])
    }

    func testAnEntirelySkyMaskGivesAllNils() {
        let mask = FrameHarness.flatMask(width: 16, height: 16, at: 16)
        let horizonY = HorizonScoring.extractHorizonYPerColumn(from: mask)
        XCTAssertEqual(horizonY.compactMap { $0 }.count, 0)
    }

    // MARK: - coverageScore

    func testAHorizonInTheMiddleWithEveryColumnDefinedScoresOne() {
        let horizonY = flatHorizon(width: 64, at: 50)
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: horizonY, imageHeight: 100), 1.0,
                       accuracy: 1e-12)
    }

    /// The two degenerate cases the score exists to catch: a horizon jammed against the top or the
    /// bottom of the frame.
    func testAHorizonAgainstEitherEdgeIsPenalised() {
        let nearTop = flatHorizon(width: 64, at: 2)          // 2% down
        let nearBottom = flatHorizon(width: 64, at: 98)      // 98% down
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: nearTop, imageHeight: 100), 0.1,
                       accuracy: 1e-12)
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: nearBottom, imageHeight: 100), 0.1,
                       accuracy: 1e-12)
    }

    /// The boundaries are 5% and 95% of the height, and the test straddles them so an off-by-one in
    /// the comparison would show up.
    func testThePositionPenaltyBoundariesAreFiveAndNinetyFivePercent() {
        // 5% exactly is not penalised (the test is `< 0.05`)
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: flatHorizon(width: 8, at: 5),
                                                    imageHeight: 100), 1.0, accuracy: 1e-12)
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: flatHorizon(width: 8, at: 4),
                                                    imageHeight: 100), 0.1, accuracy: 1e-12)
        // 95% exactly is not penalised (the test is `> 0.95`)
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: flatHorizon(width: 8, at: 95),
                                                    imageHeight: 100), 1.0, accuracy: 1e-12)
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: flatHorizon(width: 8, at: 96),
                                                    imageHeight: 100), 0.1, accuracy: 1e-12)
    }

    /// Undefined columns scale the score down linearly, so a mask that found a horizon in only half
    /// its columns cannot beat one that found it everywhere.
    func testUndefinedColumnsScaleTheScoreLinearly() {
        var half: [Int?] = flatHorizon(width: 64, at: 50)
        for x in 0..<32 { half[x] = nil }
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: half, imageHeight: 100), 0.5,
                       accuracy: 1e-12)
    }

    func testNoHorizonAtAllScoresZero() {
        XCTAssertEqual(HorizonScoring.coverageScore(horizonY: [Int?](repeating: nil, count: 32),
                                                    imageHeight: 100), 0.0)
    }

    // MARK: - localConsistencyScore

    /// A clean line has no column far from its local median.
    func testACleanLineHasFullLocalConsistency() {
        let line = naturalHorizon(width: 128, around: 60, amplitude: 3)
        XCTAssertEqual(HorizonScoring.localConsistencyScore(horizonY: line), 1.0, accuracy: 1e-12)
    }

    /// The failure this score exists for: isolated single-column spikes from Otsu on a narrow strip,
    /// which the global stddev averages away.
    func testAnIsolatedSpikeIsPenalisedEvenThoughStddevBarelyMoves() {
        var line = flatHorizon(width: 101, at: 50)
        line[50] = 90       // one column, 40px out

        let score = HorizonScoring.localConsistencyScore(horizonY: line)
        XCTAssertLessThan(score, 1.0)
        // 1 spike in 101 columns -> (1 - 1/101)^2
        XCTAssertEqual(score, pow(1.0 - 1.0 / 101.0, 2), accuracy: 1e-12)
    }

    /// The penalty is squared, so a modest spike fraction costs noticeably more than its raw share —
    /// documented as deliberate.
    func testThePenaltyIsSquaredSoSpikesCostMoreThanTheirShare() {
        var line = flatHorizon(width: 100, at: 50)
        for x in stride(from: 0, to: 100, by: 5) { line[x] = 50 + 40 }   // 20% spikes
        let score = HorizonScoring.localConsistencyScore(horizonY: line)
        XCTAssertLessThan(score, 0.8, "a linear penalty would give 0.8; the square gives less")
        XCTAssertGreaterThan(score, 0.0)
    }

    /// A deviation exactly at the threshold is not a spike — the test is strict `>`.
    func testADeviationAtTheThresholdIsNotASpike() {
        var atThreshold = flatHorizon(width: 41, at: 50)
        atThreshold[20] = 58        // exactly 8 from the median of 50
        XCTAssertEqual(HorizonScoring.localConsistencyScore(horizonY: atThreshold,
                                                            spikeThreshold: 8.0),
                       1.0, accuracy: 1e-12)

        var justOver = flatHorizon(width: 41, at: 50)
        justOver[20] = 59
        XCTAssertLessThan(HorizonScoring.localConsistencyScore(horizonY: justOver,
                                                               spikeThreshold: 8.0), 1.0)
    }

    /// A wide window makes a broad bulge look like a spike; a narrow one lets the bulge define its
    /// own local median.  Pinning this because the default of 5 is what production uses.
    func testTheWindowRadiusDecidesWhatCountsAsLocal() {
        var line = flatHorizon(width: 200, at: 60)
        for x in 90..<110 { line[x] = 90 }        // a 20 column wide plateau

        let narrow = HorizonScoring.localConsistencyScore(horizonY: line, windowRadius: 2)
        let wide = HorizonScoring.localConsistencyScore(horizonY: line, windowRadius: 40)
        XCTAssertGreaterThan(narrow, wide,
                             "with a narrow window the plateau is its own local median")
    }

    /// A window with fewer than three defined values is skipped rather than judged, so sparse
    /// regions do not manufacture spikes.
    func testAnEmptyOrSparseLineIsHandled() {
        XCTAssertEqual(HorizonScoring.localConsistencyScore(horizonY: []), 0.0)
        XCTAssertEqual(HorizonScoring.localConsistencyScore(
                         horizonY: [Int?](repeating: nil, count: 20)), 0.0)
        // two defined columns: no window reaches three values, so no spikes are found
        var sparse = [Int?](repeating: nil, count: 40)
        sparse[0] = 10
        sparse[39] = 90
        XCTAssertEqual(HorizonScoring.localConsistencyScore(horizonY: sparse), 1.0,
                       accuracy: 1e-12)
    }

    // MARK: - cropBoundaryScore

    /// **The doc comment describes a sigmoid ramp from 0.05 to 1.0 over three times the tolerance.
    /// The implementation is a plain fraction** of columns at least `tolerancePixels` from the
    /// boundary — no ramp, no 0.05 floor, and distance beyond the tolerance makes no difference.
    ///
    /// The behaviour is defensible on its own terms, and it is what the tuned thresholds were fitted
    /// against, so it is the comment that is stale.
    func testTheScoreIsAPlainFractionOfColumnsClearOfTheBoundary() {
        // every column right at the boundary
        let atBoundary = flatHorizon(width: 64, at: 40)
        XCTAssertEqual(HorizonScoring.cropBoundaryScore(horizonY: atBoundary, cropBoundaryY: 40),
                       0.0, accuracy: 1e-12,
                       "the documented 0.05 floor does not exist")

        // half clear of it
        var half = flatHorizon(width: 64, at: 40)
        for x in 0..<32 { half[x] = 100 }
        XCTAssertEqual(HorizonScoring.cropBoundaryScore(horizonY: half, cropBoundaryY: 40),
                       0.5, accuracy: 1e-12)

        // and distance past the tolerance buys nothing extra — no ramp
        let justClear = flatHorizon(width: 64, at: 48)     // exactly 8 away
        let farClear = flatHorizon(width: 64, at: 400)     // absurdly far
        XCTAssertEqual(HorizonScoring.cropBoundaryScore(horizonY: justClear, cropBoundaryY: 40),
                       HorizonScoring.cropBoundaryScore(horizonY: farClear, cropBoundaryY: 40),
                       accuracy: 1e-12)
    }

    /// The comparison is `>=`, so a column exactly `tolerancePixels` away counts as clear.
    func testExactlyTheToleranceCountsAsClear() {
        XCTAssertEqual(HorizonScoring.cropBoundaryScore(horizonY: flatHorizon(width: 16, at: 48),
                                                        cropBoundaryY: 40,
                                                        tolerancePixels: 8),
                       1.0, accuracy: 1e-12)
        XCTAssertEqual(HorizonScoring.cropBoundaryScore(horizonY: flatHorizon(width: 16, at: 47),
                                                        cropBoundaryY: 40,
                                                        tolerancePixels: 8),
                       0.0, accuracy: 1e-12)
    }

    /// Distance is absolute, so a horizon above the boundary is judged the same as one below it.
    func testTheDistanceIsAbsolute() {
        let above = HorizonScoring.cropBoundaryScore(horizonY: flatHorizon(width: 16, at: 30),
                                                     cropBoundaryY: 40)
        let below = HorizonScoring.cropBoundaryScore(horizonY: flatHorizon(width: 16, at: 50),
                                                     cropBoundaryY: 40)
        XCTAssertEqual(above, below, accuracy: 1e-12)
        XCTAssertEqual(above, 1.0, accuracy: 1e-12)
    }

    /// With nothing detected there is nothing to penalise, so the multiplier is 1 — the degenerate
    /// case is caught by `coverageScore` instead.
    func testAnEmptyHorizonIsNotPenalisedHere() {
        XCTAssertEqual(HorizonScoring.cropBoundaryScore(
                         horizonY: [Int?](repeating: nil, count: 32), cropBoundaryY: 40), 1.0)
        XCTAssertEqual(HorizonScoring.cropBoundaryScore(horizonY: [], cropBoundaryY: 40), 1.0)
    }

    // MARK: - edgeAlignmentScore

    /// The score is the fraction of horizon columns with a Canny edge within `tolerance` rows.
    func testAHorizonSittingOnAnEdgeScoresOne() {
        // an "edge image": a white line at row 40
        let edges = FrameHarness.syntheticMask(width: 64, height: 80) { _ in 0 }
        let onEdge = edgeImage(width: 64, height: 80, edgeRows: [40])
        _ = edges
        XCTAssertEqual(HorizonScoring.edgeAlignmentScore(horizonY: flatHorizon(width: 64, at: 40),
                                                         edgeImage: onEdge),
                       1.0, accuracy: 1e-12)
    }

    func testAHorizonNowhereNearAnEdgeScoresZero() {
        let edges = edgeImage(width: 64, height: 80, edgeRows: [10])
        XCTAssertEqual(HorizonScoring.edgeAlignmentScore(horizonY: flatHorizon(width: 64, at: 60),
                                                         edgeImage: edges),
                       0.0, accuracy: 1e-12)
    }

    /// The search is inclusive of `tolerance` in both directions, which is what lets a mask that is a
    /// pixel or two off still count as aligned.
    func testTheToleranceWindowIsInclusiveInBothDirections() {
        let edges = edgeImage(width: 32, height: 80, edgeRows: [40])
        for offset in [-3, -1, 0, 1, 3] {
            XCTAssertEqual(HorizonScoring.edgeAlignmentScore(
                             horizonY: flatHorizon(width: 32, at: 40 + offset),
                             edgeImage: edges, tolerance: 3),
                           1.0, accuracy: 1e-12, "offset \(offset) is within tolerance")
        }
        for offset in [-4, 4] {
            XCTAssertEqual(HorizonScoring.edgeAlignmentScore(
                             horizonY: flatHorizon(width: 32, at: 40 + offset),
                             edgeImage: edges, tolerance: 3),
                           0.0, accuracy: 1e-12, "offset \(offset) is outside tolerance")
        }
    }

    /// Undefined columns are not counted in the denominator, so a sparse horizon that happens to sit
    /// on edges where it is defined still scores 1.
    func testUndefinedColumnsAreExcludedFromTheDenominator() {
        let edges = edgeImage(width: 64, height: 80, edgeRows: [40])
        var sparse = [Int?](repeating: nil, count: 64)
        for x in stride(from: 0, to: 64, by: 8) { sparse[x] = 40 }
        XCTAssertEqual(HorizonScoring.edgeAlignmentScore(horizonY: sparse, edgeImage: edges),
                       1.0, accuracy: 1e-12)
    }

    func testNoDefinedColumnsScoresZero() {
        let edges = edgeImage(width: 16, height: 32, edgeRows: [16])
        XCTAssertEqual(HorizonScoring.edgeAlignmentScore(
                         horizonY: [Int?](repeating: nil, count: 16), edgeImage: edges), 0.0)
    }

    /// A horizon array wider than the edge image must not read out of bounds — this happens when a
    /// mask is scored against a differently-scaled edge image.
    func testAWiderHorizonThanTheEdgeImageIsClamped() {
        let edges = edgeImage(width: 16, height: 32, edgeRows: [16])
        let wide = flatHorizon(width: 64, at: 16)
        XCTAssertEqual(HorizonScoring.edgeAlignmentScore(horizonY: wide, edgeImage: edges),
                       1.0, accuracy: 1e-12,
                       "columns past the edge image's width are skipped, not counted as misses")
    }

    /// A horizon Y past the bottom of the edge image gives an empty search window, which is skipped
    /// rather than trapping — the `yMin <= yMax` guard.
    func testAHorizonBelowTheEdgeImageDoesNotTrap() {
        let edges = edgeImage(width: 16, height: 32, edgeRows: [16])
        let below = flatHorizon(width: 16, at: 100)
        let score = HorizonScoring.edgeAlignmentScore(horizonY: below, edgeImage: edges)
        XCTAssertEqual(score, 0.0, accuracy: 1e-12)
    }

    /// The threshold is intensity > 128, so a mid-grey edge does not count.
    func testAFaintEdgeDoesNotCount() {
        let faint = grayImage(width: 16, height: 32, rows: [16: 100])
        XCTAssertEqual(HorizonScoring.edgeAlignmentScore(horizonY: flatHorizon(width: 16, at: 16),
                                                         edgeImage: faint),
                       0.0, accuracy: 1e-12)
        let bright = grayImage(width: 16, height: 32, rows: [16: 200])
        XCTAssertEqual(HorizonScoring.edgeAlignmentScore(horizonY: flatHorizon(width: 16, at: 16),
                                                         edgeImage: bright),
                       1.0, accuracy: 1e-12)
    }

    // MARK: - HorizonCropAmounts

    func testFirstPassSpansTheBoundsInclusive() {
        XCTAssertEqual(HorizonCropAmounts.firstPass(bounds: [30, 70], count: 5),
                       [30, 40, 50, 60, 70])
        XCTAssertEqual(HorizonCropAmounts.firstPass(bounds: [0, 100], count: 3),
                       [0, 50, 100])
    }

    /// A count below two would divide by zero, so it is clamped to two — the endpoints.
    func testACountBelowTwoIsClampedToTheEndpoints() {
        XCTAssertEqual(HorizonCropAmounts.firstPass(bounds: [20, 80], count: 1), [20, 80])
        XCTAssertEqual(HorizonCropAmounts.firstPass(bounds: [20, 80], count: 0), [20, 80])
        XCTAssertEqual(HorizonCropAmounts.firstPass(bounds: [20, 80], count: -5), [20, 80])
    }

    /// Malformed bounds fall back to a single mid-range value rather than trapping on the index.
    func testMalformedBoundsFallBackToFifty() {
        XCTAssertEqual(HorizonCropAmounts.firstPass(bounds: [], count: 5), [50])
        XCTAssertEqual(HorizonCropAmounts.firstPass(bounds: [42], count: 5), [50])
        XCTAssertEqual(HorizonCropAmounts.firstPassStep(bounds: [], count: 5), 10)
        XCTAssertEqual(HorizonCropAmounts.firstPassStep(bounds: [42], count: 5), 10)
    }

    /// The step has to match the spacing `firstPass` actually produced, because `secondPass` uses it
    /// as the half-width of the refined search.
    func testTheStepMatchesTheSpacingFirstPassProduces() {
        for count in 2...9 {
            let values = HorizonCropAmounts.firstPass(bounds: [10, 90], count: count)
            let step = HorizonCropAmounts.firstPassStep(bounds: [10, 90], count: count)
            XCTAssertEqual(values[1] - values[0], step, accuracy: 1e-12, "count \(count)")
        }
    }

    func testSecondPassIsCentredOnTheBestValue() {
        XCTAssertEqual(HorizonCropAmounts.secondPass(bestCrop: 50, firstPassStep: 10, count: 5),
                       [40, 45, 50, 55, 60])
    }

    /// The refined range is clamped to 0...100, which makes it asymmetric near the ends — the centre
    /// is no longer the best value there.
    func testTheSecondPassRangeIsClampedToTheValidPercentage() {
        let nearZero = HorizonCropAmounts.secondPass(bestCrop: 5, firstPassStep: 20, count: 5)
        XCTAssertEqual(nearZero.first, 0)
        XCTAssertEqual(nearZero.last, 25)
        XCTAssertFalse(nearZero.contains(5), "clamping moves the samples off the best value")

        let nearHundred = HorizonCropAmounts.secondPass(bestCrop: 95, firstPassStep: 20, count: 5)
        XCTAssertEqual(nearHundred.first, 75)
        XCTAssertEqual(nearHundred.last, 100)
    }

    /// A zero step collapses the refined pass onto the single best value, rather than producing NaN.
    func testAZeroStepCollapsesToTheBestValue() {
        let values = HorizonCropAmounts.secondPass(bestCrop: 60, firstPassStep: 0, count: 5)
        XCTAssertEqual(values, [60, 60, 60, 60, 60])
        XCTAssertFalse(values.contains { $0.isNaN })
    }

    // MARK: - AdaptiveHorizonState

    /// The first frame gets the caller's defaults untouched — there is nothing yet to narrow around.
    func testTheFirstFrameGetsTheDefaultBounds() async {
        let state = AdaptiveHorizonState()
        let isFirst = await state.isFirstFrame
        XCTAssertTrue(isFirst)
        let bounds = await state.narrowedCropBounds(defaults: [30, 70], narrowingRange: 10)
        XCTAssertEqual(bounds, [30, 70])
    }

    /// After a frame records a best value, later frames search a window around it — this is the whole
    /// point of the state, and it is why frame 2 onward is much cheaper than frame 1.
    func testLaterFramesSearchAroundThePreviousBest()  async {
        let state = AdaptiveHorizonState()
        await state.recordBest(cropAmount: 55, firstPassStep: 10)
        let isFirst = await state.isFirstFrame
        XCTAssertFalse(isFirst)
        let bounds = await state.narrowedCropBounds(defaults: [0, 100], narrowingRange: 12)
        XCTAssertEqual(bounds, [43, 67])
    }

    /// The narrowed window is clamped to 0...100 like the crop percentages it describes.
    func testTheNarrowedBoundsAreClampedToTheValidPercentage() async {
        let low = AdaptiveHorizonState()
        await low.recordBest(cropAmount: 3, firstPassStep: 10)
        let lowBounds = await low.narrowedCropBounds(defaults: [0, 100], narrowingRange: 20)
        XCTAssertEqual(lowBounds, [0, 23])

        let high = AdaptiveHorizonState()
        await high.recordBest(cropAmount: 97, firstPassStep: 10)
        let highBounds = await high.narrowedCropBounds(defaults: [0, 100], narrowingRange: 20)
        XCTAssertEqual(highBounds, [77, 100])
    }

    /// Only the most recent frame's best value is used — the state is a one-frame memory, not an
    /// average, so a sequence whose horizon drifts keeps following it.
    func testOnlyTheMostRecentBestIsRemembered() async {
        let state = AdaptiveHorizonState()
        await state.recordBest(cropAmount: 20, firstPassStep: 10)
        await state.recordBest(cropAmount: 80, firstPassStep: 10)
        let bounds = await state.narrowedCropBounds(defaults: [0, 100], narrowingRange: 5)
        XCTAssertEqual(bounds, [75, 85])
    }

    /// `firstPassStep` is recorded but nothing reads it back — `narrowedCropBounds` takes its
    /// narrowing range from the caller instead.  Pinned so a later change that starts using the
    /// stored step is a deliberate one.
    func testTheRecordedStepDoesNotAffectTheNarrowedBounds() async {
        let small = AdaptiveHorizonState()
        await small.recordBest(cropAmount: 50, firstPassStep: 1)
        let large = AdaptiveHorizonState()
        await large.recordBest(cropAmount: 50, firstPassStep: 40)
        let smallBounds = await small.narrowedCropBounds(defaults: [0, 100], narrowingRange: 10)
        let largeBounds = await large.narrowedCropBounds(defaults: [0, 100], narrowingRange: 10)
        XCTAssertEqual(smallBounds, largeBounds)
    }

    /// Concurrent frames record into the same actor; the point is that it serialises rather than
    /// races, and that a valid pair of bounds always comes back.
    func testConcurrentRecordingIsSerialised() async {
        let state = AdaptiveHorizonState()
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<50 {
                group.addTask { await state.recordBest(cropAmount: Double(i), firstPassStep: 10) }
            }
        }
        let bounds = await state.narrowedCropBounds(defaults: [0, 100], narrowingRange: 10)
        XCTAssertEqual(bounds.count, 2)
        XCTAssertLessThanOrEqual(bounds[0], bounds[1])
        XCTAssertGreaterThanOrEqual(bounds[0], 0)
        XCTAssertLessThanOrEqual(bounds[1], 100)
    }

    // MARK: - the composite score

    /// The overload that takes a prepared edge image must agree with the one that runs Canny itself
    /// on every component it can compute without Canny.  Only edge alignment may differ.
    func testTheTwoScoreOverloadsAgreeOnEverythingButEdgeAlignment() throws {
        let image = FrameHarness.syntheticFrame(width: 96, height: 72, horizonRow: 36)
        let mask = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 96, height: 72, at: 36)))
        let edges = edgeImage(width: 96, height: 72, edgeRows: [36])

        let viaCanny = HorizonScoring.score(horizonMask: mask,
                                            originalImage: image,
                                            cannyMinThreshold: 50,
                                            cannyMaxThreshold: 150,
                                            useL2Gradient: false)
        let viaEdges = HorizonScoring.score(horizonMask: mask, edgeImage: edges)

        XCTAssertEqual(viaCanny.smoothnessScore, viaEdges.smoothnessScore, accuracy: 1e-12)
        XCTAssertEqual(viaCanny.coverageScore, viaEdges.coverageScore, accuracy: 1e-12)
        XCTAssertEqual(viaCanny.localConsistencyScore, viaEdges.localConsistencyScore,
                       accuracy: 1e-12)
    }

    /// Passing a boundary Y switches the multiplier on; leaving it nil is the "no penalty" path.
    func testPassingACropBoundaryEngagesTheMultiplier() throws {
        let mask = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 64, height: 80, at: 40)))
        let edges = edgeImage(width: 64, height: 80, edgeRows: [40])

        let withoutBoundary = HorizonScoring.score(horizonMask: mask, edgeImage: edges)
        // the horizon sits exactly on the boundary, so every column is inside the tolerance
        let atBoundary = HorizonScoring.score(horizonMask: mask, edgeImage: edges,
                                              cropBoundaryY: 40)
        XCTAssertEqual(atBoundary.cropBoundaryScore, 0.0, accuracy: 1e-12)
        XCTAssertEqual(atBoundary.totalScore, 0.0, accuracy: 1e-12,
                       "a crop-boundary artefact must be suppressed entirely")
        XCTAssertGreaterThan(withoutBoundary.totalScore, 0)

        let clearOfBoundary = HorizonScoring.score(horizonMask: mask, edgeImage: edges,
                                                   cropBoundaryY: 10)
        XCTAssertEqual(clearOfBoundary.cropBoundaryScore, 1.0, accuracy: 1e-12)
    }

    /// The neutral "no crop boundary known" multiplier must be the same in both overloads, and must
    /// actually be neutral.  It was 0.999 in one and 0.99 in the other; the overloads are chosen for
    /// the same candidate set on whether an edge image happened to be cached, so an identical mask
    /// scored differently for a reason unrelated to the mask.
    func testBothOverloadsUseTheSameNeutralCropBoundaryMultiplier() throws {
        let image = FrameHarness.syntheticFrame(width: 64, height: 80, horizonRow: 40)
        let mask = try XCTUnwrap(HorizonMask(FrameHarness.flatMask(width: 64, height: 80, at: 40)))
        let edges = edgeImage(width: 64, height: 80, edgeRows: [40])

        let viaCanny = HorizonScoring.score(horizonMask: mask,
                                            originalImage: image,
                                            cannyMinThreshold: 50,
                                            cannyMaxThreshold: 150,
                                            useL2Gradient: false)
        let viaEdges = HorizonScoring.score(horizonMask: mask, edgeImage: edges)

        XCTAssertEqual(viaCanny.cropBoundaryScore, viaEdges.cropBoundaryScore, accuracy: 1e-12)
        XCTAssertEqual(viaEdges.cropBoundaryScore, 1.0, accuracy: 1e-12,
                       "\"no penalty\" has to mean no penalty")
    }

    /// A degenerate all-sky mask must not out-score a plausible one, whichever route it takes.
    func testADegenerateMaskCannotOutScoreAPlausibleOne() throws {
        let edges = edgeImage(width: 96, height: 72, edgeRows: [36])
        let plausible = try XCTUnwrap(
          HorizonMask(FrameHarness.syntheticMask(width: 96, height: 72) { x in
              36 + Int((4.0 * sin(Double(x) / 9.0)).rounded())
          }))
        // all sky: no ground pixel anywhere, so no horizon at all
        let degenerate = HorizonMask(image: FrameHarness.flatMask(width: 96, height: 72, at: 72),
                                     horizonTopY: 0, horizonBottomY: 71)

        let plausibleScore = HorizonScoring.score(horizonMask: plausible, edgeImage: edges)
        let degenerateScore = HorizonScoring.score(horizonMask: degenerate, edgeImage: edges)
        XCTAssertGreaterThan(plausibleScore.totalScore, degenerateScore.totalScore)
        XCTAssertEqual(degenerateScore.coverageScore, 0.0)
    }

    // MARK: - helpers

    /// A stand-in for a Canny result: black with white rows where an edge is.
    private func edgeImage(width: Int, height: Int, edgeRows: [Int]) -> PixelatedImage {
        var rows: [Int: UInt8] = [:]
        for row in edgeRows { rows[row] = 255 }
        return grayImage(width: width, height: height, rows: rows)
    }

    private func grayImage(width: Int, height: Int, rows: [Int: UInt8]) -> PixelatedImage {
        FrameHarness.grayImage(width: width, height: height, rows: rows)
    }
}
