import XCTest
import Foundation
@testable import StarCore

/// A measurement, not an assertion suite.
///
/// Four horizon-scoring findings were pinned rather than fixed on the grounds that "only the reference
/// masks can adjudicate."  This runs that adjudication: it reproduces `FrameHorizonProcessor`'s
/// candidate search on real frames that have a ground-truth `horizon.tiff`, then asks which candidate
/// each scoring variant *picks* and how far that pick is from the truth.
///
/// The metric's job is selection, so the figure of merit is the mean absolute Y error of the candidate
/// the metric chooses — not the metric's own value.  An oracle row (the best MAE available among the
/// candidates) shows how much accuracy the metric is leaving on the table.
///
/// Skips when the fixtures are absent; they are 1GB/5.8GB and not committed.
///
/// ## Result, 2026-07-31 — `stationary/03_21_2026-fx3-2`, 15 frames at 4240x2832
///
/// ```
///   variant     mean MAE (shrunk rows)   (full px)
///   current                      0.89          6.5
///   gaussian                     0.89          6.5     <- peak moved to ~3.4, normalised to 1.0
///   smoother                     0.88          6.5     <- opposite preference in the live region
///   none                         0.95          7.0     <- smoothness removed, weights renormalised
///   cropDoc                      0.89          6.5     <- cropBoundaryScore as documented
///   nilGround                    0.89          6.5     <- all-ground columns nilled before scoring
///   oracle                       0.76          5.6
/// ```
///
/// (`current`/`gaussian`/`smoother`/`cropDoc`/`nilGround` are 0.94 over the committed 5 frames and
/// 0.89 over 15; the ordering is identical either way.)
///
/// **Three of the four pinned findings are inert, each for its own structural reason.**  All three are
/// genuine doc/implementation mismatches, and none of them changes the mask that gets chosen:
///
///  - `cropBoundaryScore` is a plain column fraction, not the documented sigmoid from 0.05.  Both
///    forms return exactly 1.000 for every *viable* candidate and diverge only on candidates already
///    being rejected on other grounds (0.250 vs 0.810 on one, 0.989 vs 0.896 on another).
///  - `extractHorizonYPerColumn` returns 0 rather than nil for an all-ground column.  Across 80 real
///    candidate masks there are **zero** all-ground columns, which is structural: the crop step fills
///    the top of the frame white, so row 0 is sky by construction.  The user-painted reference has
///    none either.
///  - `horizonConfidence` bridges nil gaps — measured separately in `CombinedConfidenceMeasurement`,
///    where all five base methods turn out fully dense, so the delta is 0.000000.
///
/// The fourth, `smoothnessScore`'s shape, is inert for the *selection* it drives but load bearing as a
/// tie-breaker; see below.
///
/// **Reshaping `smoothnessScore` is a measured no-op.**  Three curves with different shapes — and
/// opposite preferences at the derivative stddev real candidates actually occupy — pick masks within
/// 0.07 full pixels of each other.  Two reasons, both visible in the per-frame candidate table:
///
///  1. Every real Otsu candidate lands at a derivative stddev of 0.48–0.54.  The sawtooth-beats-
///     sinusoid inversion the curve permits needs a stddev in the tens, which never occurs, so the
///     pathology is unreachable in production.
///  2. In that narrow band the stddev is uncorrelated with the true error.  MAE varies smoothly with
///     the crop amount (a U-shape, 0.94 → 0.76 → 0.95) while the stddev wanders without pattern.
///
/// **The term is nonetheless load bearing.**  Among the 13 viable candidates on a frame, edge
/// alignment, coverage, local consistency and the crop-boundary multiplier are *all* exactly 1.000 —
/// so smoothness is the only discriminator, resolving a 0.0003 spread in total score.  Removing it
/// (the `none` row) drops the choice to the "prefer the larger crop amount" tie-break, which is
/// consistently worse.  An arbitrary tie-breaker beats no tie-breaker here.
///
/// **What the metric is actually good at** is rejection, and it does that cleanly: the genuinely
/// broken candidates score 0.25–0.55 against 0.70 for the viable ones, and they are wrong by ~50
/// shrunk rows (~380 full px), so nothing marginal is at stake in that decision.
///
/// **Where the real headroom is.**  The whole viable spread, 0.76 to 0.95 shrunk rows, is under a
/// *single* working-resolution row — `horizonSearchSize` is 384x384, where one row is 7.4 full pixels.
/// The oracle beats the shipped metric by 0.13 shrunk rows, i.e. about 1 full pixel, which is well
/// below the search's own quantisation.  No scoring function can do better than ±1 working row at this
/// resolution; raising `horizonSearchSize` is the lever, not the score.
///
/// Committed with 5 frames to keep the suite quick.  15 frames gives the same ordering and the numbers
/// above; change `limit:` to reproduce.
final class HorizonScoringMeasurement: XCTestCase {

    // production values, from Config's defaults
    private let workingSize: UInt = 384
    private let cannyMin = 50.0
    private let cannyMax = 120.0
    private let useL2 = true
    private let cropBounds: [Double] = [10, 90]
    private let cropCount = 16

    private func fixtureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .deletingLastPathComponent()      // the test runs from StarCore/
        for candidate in ["small_horizon_test_data", "horizon_test_data"] {
            let dir = root.appendingPathComponent(candidate)
              .appendingPathComponent("stationary/03_21_2026-fx3-2")
            if FileManager.default.fileExists(
                 atPath: dir.appendingPathComponent("horizon.tiff").path) {
                return dir
            }
        }
        throw XCTSkip("no horizon reference fixtures present")
    }

    /// The frames in the sequence, excluding the reference mask itself.
    private func frameURLs(in dir: URL, limit: Int) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(atPath: dir.path)
          .filter { $0.hasSuffix(".tiff") && $0 != "horizon.tiff" }
          .sorted()
        return all.prefix(limit).map { dir.appendingPathComponent($0) }
    }

    // MARK: - the scoring variants

    /// Standard deviation of the column-to-column derivative, counting only adjacent pairs where both
    /// columns are defined — the quantity `smoothnessScore` is a function of.
    private func derivativeStddev(_ horizonY: [Int?]) -> Double? {
        var diffs: [Double] = []
        for i in 1..<max(1, horizonY.count) {
            if let prev = horizonY[i - 1], let curr = horizonY[i] {
                diffs.append(Double(curr - prev))
            }
        }
        guard diffs.count > 1 else { return nil }
        let mean = diffs.reduce(0, +) / Double(diffs.count)
        let variance = diffs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(diffs.count)
        return variance.squareRoot()
    }

    /// The shipped curve: `1/(1+s)` roughness times a Gaussian flatness floor.  Peaks near s=5.2 at
    /// about 0.125.
    private func currentSmoothness(_ s: Double) -> Double {
        (1.0 / (1.0 + s)) * (1.0 - exp(-(s * s) / 18.0))
    }

    /// A candidate correction that matches what the doc comment describes: still penalises flatness,
    /// but the roughness penalty is Gaussian so it actually falls away, and the result is normalised
    /// so a good horizon scores near 1 like the other three components.
    private func gaussianSmoothness(_ s: Double,
                                    naturalStddev: Double = 1.5,
                                    roughStddev: Double = 5.0) -> Double {
        let lower = 1.0 - exp(-(s * s) / (2 * naturalStddev * naturalStddev))
        let upper = exp(-(s * s) / (2 * roughStddev * roughStddev))
        // peak of the product, for normalisation to [0, 1]
        let peak = 0.7255
        return min(1.0, lower * upper / peak)
    }

    /// Recombine a score with a substituted smoothness value, using the shipped weights.
    private func total(_ score: HorizonScore, smoothness: Double) -> Double {
        let additive = smoothness * 0.30
                     + score.edgeAlignmentScore * 0.30
                     + score.coverageScore * 0.15
                     + score.localConsistencyScore * 0.25
        return additive * score.cropBoundaryScore
    }

    /// A curve whose flatness penalty has already saturated by the stddev real candidates occupy
    /// (~0.5), so it is *falling* there and therefore prefers the smoother candidate — the opposite
    /// preference from both the shipped curve and the gaussian variant, which are still rising at 0.5.
    private func prefersSmootherSmoothness(_ s: Double) -> Double {
        let lower = 1.0 - exp(-(s * s) / (2 * 0.2 * 0.2))
        let upper = exp(-(s * s) / (2 * 5.0 * 5.0))
        return lower * upper
    }

    /// Smoothness dropped entirely, the other three weights renormalised to sum to 1.
    private func totalWithoutSmoothness(_ score: HorizonScore) -> Double {
        let additive = score.edgeAlignmentScore * (0.30 / 0.70)
                     + score.coverageScore * (0.15 / 0.70)
                     + score.localConsistencyScore * (0.25 / 0.70)
        return additive * score.cropBoundaryScore
    }

    /// The four additive terms with the shipped weights, without the crop-boundary multiplier — so a
    /// different multiplier can be substituted.
    private func additive(_ score: HorizonScore) -> Double {
        score.smoothnessScore * 0.30
          + score.edgeAlignmentScore * 0.30
          + score.coverageScore * 0.15
          + score.localConsistencyScore * 0.25
    }

    /// `cropBoundaryScore` as its doc comment describes it, rather than as it is implemented: a
    /// penalty on the distance from the **average** horizon Y to the boundary, ramping smoothly from
    /// 0.05 at one tolerance to 1.0 at three tolerances.
    ///
    /// The shipped version instead counts the *fraction of columns* at least one tolerance clear, with
    /// no ramp and no floor.
    private func documentedCropBoundaryScore(horizonY: [Int?],
                                             cropBoundaryY: Int,
                                             tolerancePixels: Double = 8) -> Double {
        let defined = horizonY.compactMap { $0 }
        guard !defined.isEmpty else { return 1.0 }
        let average = Double(defined.reduce(0, +)) / Double(defined.count)
        let distance = abs(average - Double(cropBoundaryY))
        if distance <= tolerancePixels { return 0.05 }
        if distance >= 3 * tolerancePixels { return 1.0 }
        let u = (distance - tolerancePixels) / (2 * tolerancePixels)   // 0...1
        let smoothstep = u * u * (3 - 2 * u)
        return 0.05 + smoothstep * 0.95
    }


    /// Rescore a mask as if `extractHorizonYPerColumn` returned nil for an all-ground column instead
    /// of 0.  A column is all-ground when its very first row is already ground, so the scan finds the
    /// "horizon" at row 0 — which is not a horizon at all, it is a column with no sky in it.
    private func rescoreWithAllGroundColumnsNilled(_ candidate: Candidate,
                                                   edgeImage: PixelatedImage?,
                                                   imageHeight: Int) -> (score: HorizonScore,
                                                                         allGroundColumns: Int) {
        let shipped = HorizonScoring.extractHorizonYPerColumn(from: candidate.mask.image)
        var corrected = shipped
        var allGround = 0
        for x in 0..<corrected.count where corrected[x] == 0 {
            corrected[x] = nil
            allGround += 1
        }
        let edge: Double
        if let edgeImage {
            edge = HorizonScoring.edgeAlignmentScore(horizonY: corrected, edgeImage: edgeImage,
                                                    tolerance: 3)
        } else {
            edge = 0.5
        }
        let score = HorizonScore(
          smoothnessScore: HorizonScoring.smoothnessScore(horizonY: corrected),
          edgeAlignmentScore: edge,
          coverageScore: HorizonScoring.coverageScore(horizonY: corrected,
                                                      imageHeight: imageHeight),
          localConsistencyScore: HorizonScoring.localConsistencyScore(horizonY: corrected),
          cropBoundaryScore: HorizonScoring.cropBoundaryScore(horizonY: corrected,
                                                              cropBoundaryY: candidate.cropBoundaryY))
        return (score, allGround)
    }

    // MARK: - the measurement

    private struct Candidate {
        let cropAmount: Double
        let truthMAE: Double          // in shrunk rows
        let score: HorizonScore
        let stddev: Double?
        let horizonY: [Int?]
        let cropBoundaryY: Int
        let mask: HorizonMask
    }

    func testWhichScoringVariantPicksTheCandidateClosestToTheReference() async throws {
        let dir = try fixtureDirectory()
        let referencePath = dir.appendingPathComponent("horizon.tiff").path
        let referenceFull = try XCTUnwrap(PixelatedImage(filename: referencePath),
                                          "could not load the reference mask")

        let frames = try frameURLs(in: dir, limit: 5)
        try XCTSkipIf(frames.isEmpty, "the sequence has a reference mask but no frames")

        // the reference, reduced the same way the search reduces the frame
        let referenceShrunk = try XCTUnwrap(referenceFull.downScaleTo(width: workingSize,
                                                                     height: workingSize))
        let referenceY = CombinedHorizonDetector.extractHorizonY(from: referenceShrunk)
        let referenceDefined = referenceY.compactMap { $0 }
        try XCTSkipIf(referenceDefined.isEmpty, "the reference mask has no horizon")

        let fullHeight = referenceFull.height
        let rowScale = Double(fullHeight) / Double(workingSize)   // shrunk rows -> full rows

        print("""

        ================ horizon scoring measurement ================
        sequence     \(dir.lastPathComponent)
        reference    \(referenceFull.width)x\(referenceFull.height), \
        horizon rows \(referenceDefined.min()!)..\(referenceDefined.max()!) (shrunk)
        working size \(workingSize)x\(workingSize), 1 shrunk row = \
        \(String(format: "%.2f", rowScale)) full rows
        frames       \(frames.count)
        crop amounts \(HorizonCropAmounts.firstPass(bounds: cropBounds, count: cropCount)
                        .map { String(format: "%.0f", $0) }.joined(separator: ","))
        """)

        // The reference mask is user-painted, so unlike an Otsu candidate it *could* contain a column
        // with no sky — a building or tree touching the top of the frame.  That is the only way the
        // 0-vs-nil convention can bite.
        let referenceViaScoring = HorizonScoring.extractHorizonYPerColumn(from: referenceShrunk)
        let referenceAllGround = referenceViaScoring.filter { $0 == 0 }.count
        let referenceNil = referenceViaScoring.filter { $0 == nil }.count
        print("""
          reference mask: \(referenceAllGround) all-ground columns, \(referenceNil) all-sky columns, \
        \(referenceViaScoring.count - referenceAllGround - referenceNil) with a real horizon
        """)

        var picks: [String: [Double]] = ["current": [], "gaussian": [], "smoother": [],
                                         "none": [], "cropDoc": [], "nilGround": [], "oracle": []]

        for frameURL in frames {
            guard let original = PixelatedImage(filename: frameURL.path) else {
                print("  ! could not load \(frameURL.lastPathComponent)")
                continue
            }
            guard let shrunk = original.downScaleTo(width: workingSize, height: workingSize) else {
                print("  ! could not downscale \(frameURL.lastPathComponent)")
                continue
            }
            let edges = try? shrunk.cannyEdgeDetect(minThreshold: cannyMin,
                                                    maxThreshold: cannyMax,
                                                    useL2Gradient: useL2)

            var candidates: [Candidate] = []
            for crop in HorizonCropAmounts.firstPass(bounds: cropBounds, count: cropCount) {
                guard let mask = try await shrunk.horizonMask(
                        at: 0,
                        bottomPercentage: crop,
                        useCannyEdgeDetection: true,
                        cannyMinThreshold: cannyMin,
                        cannyMaxThreshold: cannyMax,
                        useL2Gradient: useL2)
                else { continue }

                let cropBoundaryY = Int(Double(workingSize) * crop / 100.0)
                let score: HorizonScore
                if let edges {
                    score = HorizonScoring.score(horizonMask: mask, edgeImage: edges,
                                                 cropBoundaryY: cropBoundaryY)
                } else {
                    score = HorizonScoring.score(horizonMask: mask, originalImage: shrunk,
                                                 cannyMinThreshold: cannyMin,
                                                 cannyMaxThreshold: cannyMax,
                                                 useL2Gradient: useL2,
                                                 cropBoundaryY: cropBoundaryY)
                }

                let candidateY = CombinedHorizonDetector.extractHorizonY(from: mask.image)
                let mae = HomographyHorizonDetector.score(algorithmY: candidateY,
                                                          referenceY: referenceY)
                candidates.append(Candidate(cropAmount: crop,
                                            truthMAE: mae,
                                            score: score,
                                            stddev: derivativeStddev(candidateY),
                                            horizonY: candidateY,
                                            cropBoundaryY: cropBoundaryY,
                                            mask: mask))
            }

            guard !candidates.isEmpty else {
                print("  ! no candidates for \(frameURL.lastPathComponent)")
                continue
            }

            func pick(_ key: String, by value: (Candidate) -> Double) -> Candidate {
                // production tie-breaks on the larger crop amount
                let best = candidates.max {
                    value($0) != value($1) ? value($0) < value($1)
                                           : $0.cropAmount < $1.cropAmount
                }!
                picks[key]!.append(best.truthMAE)
                return best
            }

            let current = pick("current") { $0.score.totalScore }
            let gaussian = pick("gaussian") { candidate in
                let smoothness = candidate.stddev.map { self.gaussianSmoothness($0) } ?? 0.5
                return self.total(candidate.score, smoothness: smoothness)
            }
            let smoother = pick("smoother") { candidate in
                let smoothness = candidate.stddev.map { self.prefersSmootherSmoothness($0) } ?? 0.5
                return self.total(candidate.score, smoothness: smoothness)
            }
            let none = pick("none") { self.totalWithoutSmoothness($0.score) }
            let nilGround = pick("nilGround") { candidate in
                self.rescoreWithAllGroundColumnsNilled(candidate, edgeImage: edges,
                                                       imageHeight: Int(self.workingSize))
                  .score.totalScore
            }
            let cropDoc = pick("cropDoc") { candidate in
                self.additive(candidate.score)
                  * self.documentedCropBoundaryScore(horizonY: candidate.horizonY,
                                                     cropBoundaryY: candidate.cropBoundaryY)
            }
            let oracle = candidates.min { $0.truthMAE < $1.truthMAE }!
            picks["oracle"]!.append(oracle.truthMAE)

            print("""

            --- \(frameURL.lastPathComponent) (\(original.width)x\(original.height)) ---
              variant    crop   MAE(shrunk)  MAE(full px)
              current    \(String(format: "%4.0f", current.cropAmount))   \
            \(String(format: "%8.2f", current.truthMAE))   \
            \(String(format: "%8.1f", current.truthMAE * rowScale))
              gaussian   \(String(format: "%4.0f", gaussian.cropAmount))   \
            \(String(format: "%8.2f", gaussian.truthMAE))   \
            \(String(format: "%8.1f", gaussian.truthMAE * rowScale))
              smoother   \(String(format: "%4.0f", smoother.cropAmount))   \
            \(String(format: "%8.2f", smoother.truthMAE))   \
            \(String(format: "%8.1f", smoother.truthMAE * rowScale))
              none       \(String(format: "%4.0f", none.cropAmount))   \
            \(String(format: "%8.2f", none.truthMAE))   \
            \(String(format: "%8.1f", none.truthMAE * rowScale))
              cropDoc    \(String(format: "%4.0f", cropDoc.cropAmount))   \
            \(String(format: "%8.2f", cropDoc.truthMAE))   \
            \(String(format: "%8.1f", cropDoc.truthMAE * rowScale))
              nilGround  \(String(format: "%4.0f", nilGround.cropAmount))   \
            \(String(format: "%8.2f", nilGround.truthMAE))   \
            \(String(format: "%8.1f", nilGround.truthMAE * rowScale))
              oracle     \(String(format: "%4.0f", oracle.cropAmount))   \
            \(String(format: "%8.2f", oracle.truthMAE))   \
            \(String(format: "%8.1f", oracle.truthMAE * rowScale))
            """)

            // what the shipped smoothness term is actually contributing at the picked candidate
            if let s = current.stddev {
                print("""
                  picked candidate: derivative stddev \(String(format: "%.2f", s)) -> \
                current smoothness \(String(format: "%.4f", currentSmoothness(s))) \
                (contributes \(String(format: "%.4f", currentSmoothness(s) * 0.30)) of a possible 0.30)
                """)
            }

            // How many columns the shipped extraction reports as "horizon at row 0" — columns with
            // no sky at all, which the doc says should be nil.  Zero here makes the question moot.
            let allGroundCounts = candidates.map {
                self.rescoreWithAllGroundColumnsNilled($0, edgeImage: edges,
                                                       imageHeight: Int(self.workingSize))
                  .allGroundColumns
            }
            print("""
              all-ground columns (of \(workingSize)): min \(allGroundCounts.min() ?? -1), \
            max \(allGroundCounts.max() ?? -1), candidates with any: \
            \(allGroundCounts.filter { $0 > 0 }.count)/\(allGroundCounts.count)
            """)

            // The two things that decide whether reshaping the curve could matter at all:
            // how much the candidates' MAE actually varies, and what stddev range they occupy.
            let maes = candidates.map(\.truthMAE).sorted()
            let stddevs = candidates.compactMap(\.stddev).sorted()
            print("""
              candidate spread: MAE \(String(format: "%.2f", maes.first!))..\
            \(String(format: "%.2f", maes.last!)) shrunk rows \
            (\(String(format: "%.1f", (maes.last! - maes.first!) * rowScale)) full px between best and worst)
              candidate stddev: \(String(format: "%.2f", stddevs.first ?? -1))..\
            \(String(format: "%.2f", stddevs.last ?? -1)) \
            -> current smoothness \(String(format: "%.4f", currentSmoothness(stddevs.first ?? 0)))..\
            \(String(format: "%.4f", currentSmoothness(stddevs.last ?? 0)))
            """)

            // full table for the first frame, so the shape of the search is on the record
            if frameURL == frames.first {
                print("  full candidate table:")
                print("    crop   MAE   stddev   smooth   edge   cover  consist  cropBnd  cropDoc    total")
                for c in candidates.sorted(by: { $0.cropAmount < $1.cropAmount }) {
                    print(String(format:
                      "    %4.0f  %5.2f   %6.2f   %6.4f  %5.3f  %5.3f    %5.3f    %5.3f    %5.3f  %7.4f",
                      c.cropAmount, c.truthMAE, c.stddev ?? -1,
                      c.score.smoothnessScore, c.score.edgeAlignmentScore,
                      c.score.coverageScore, c.score.localConsistencyScore,
                      c.score.cropBoundaryScore,
                      self.documentedCropBoundaryScore(horizonY: c.horizonY,
                                                       cropBoundaryY: c.cropBoundaryY),
                      c.score.totalScore))
                }
            }
        }

        print("\n================ summary over \(picks["current"]!.count) frames ================")
        for key in ["current", "gaussian", "smoother", "none", "cropDoc", "nilGround", "oracle"] {
            let values = picks[key]!
            guard !values.isEmpty else { continue }
            let mean = values.reduce(0, +) / Double(values.count)
            print(String(format: "  %-9@  mean MAE %7.2f shrunk rows  %8.1f full px",
                         key as NSString, mean, mean * rowScale))
        }
        print("============================================================\n")

        // The measurement's own sanity check: the oracle cannot be worse than any picker.
        let oracleMean = picks["oracle"]!.reduce(0, +) / Double(max(1, picks["oracle"]!.count))
        for key in ["current", "gaussian", "smoother", "none", "cropDoc", "nilGround"] {
            let values = picks[key]!
            guard !values.isEmpty else { continue }
            let mean = values.reduce(0, +) / Double(values.count)
            XCTAssertGreaterThanOrEqual(mean, oracleMean - 1e-9,
                                        "\(key) beat the oracle, which means the measurement is wrong")
        }
    }
}
