import XCTest
import Foundation
@testable import StarCore

/// Adjudicates the last of the pinned scoring findings: **`CombinedHorizonDetector.horizonConfidence`
/// computes its smoothness term over the *compacted* horizon array**, so a nil gap is bridged and the
/// jump across it is counted as roughness.
///
/// That confidence decides two things: whether a base method is included in the merge at all (the
/// caller drops anything scoring at or below 0.05) and how much weight it carries per column.  So the
/// question is not whether the code matches its comment — it does not — but whether the five real base
/// methods produce arrays with enough gaps for it to change either decision.
///
/// This runs the five methods `detect` actually merges on real frames and compares the shipped
/// confidence against one computed with properly adjacent differences.
///
/// Skips when the fixtures are absent.
///
/// ## Result, 2026-07-31 — `stationary/03_21_2026-fx3-2`, 3 frames at 4240x2832
///
/// **Every base method returns a fully dense array**: 4240 of 4240 columns defined, zero nils, on all
/// three frames and all five methods.  So the shipped confidence and the adjacent-difference version
/// agree to **0.000000** across all 15 comparisons, and no inclusion decision can flip.  The bridged
/// gap is real as a mechanism — `CombinedHorizonDetectorTests` constructs one by hand — but there is
/// nothing in production that produces the input it mishandles.
///
/// The density is structural, not luck: every base method ends in `scaleHorizonY`, which emits a value
/// for each output column whenever its source column had one, and the smoothing and dynamic-programming
/// stages upstream fill every column.
///
/// Committed with 1 frame because the methods run at full resolution and each frame costs ~30s; the
/// numbers above are from 3.  Raise the `prefix` to reproduce.
final class CombinedConfidenceMeasurement: XCTestCase {

    private let baseWorkingSize = 512     // CombinedHorizonDetector.Params default

    private func fixtureDirectory() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
          .deletingLastPathComponent()
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

    /// `horizonConfidence` with the one line changed: differences taken between adjacent columns that
    /// are *both* defined, rather than across the compacted array.  Everything else is identical, so
    /// any difference in the result is attributable to the gap bridging alone.
    private func confidenceWithAdjacentDiffs(_ horizonY: [Int?], imageHeight: Int) -> Double {
        let defined = horizonY.compactMap { $0 }
        guard defined.count > horizonY.count / 20 else { return 0 }

        let coverage = Double(defined.count) / Double(max(1, horizonY.count))

        // the only change: adjacent pairs where both columns exist
        var diffs: [Int] = []
        for i in 1..<max(1, horizonY.count) {
            if let prev = horizonY[i - 1], let curr = horizonY[i] {
                diffs.append(abs(curr - prev))
            }
        }
        let meanDiff = diffs.isEmpty ? 0.0 : Double(diffs.reduce(0, +)) / Double(diffs.count)
        let normalizedDiff = meanDiff / Double(max(1, imageHeight))
        let smoothness = 1.0 / (1.0 + normalizedDiff * 200.0)

        let avg = Double(defined.reduce(0, +)) / Double(defined.count)
        let heightFrac = avg / Double(imageHeight)
        let plausibility: Double
        if heightFrac < 0.05 || heightFrac > 0.95 {
            plausibility = 0.0
        } else if heightFrac < 0.15 || heightFrac > 0.85 {
            plausibility = 0.3
        } else {
            plausibility = 1.0 - abs(heightFrac - 0.5) * 1.2
        }
        return coverage * smoothness * max(0.05, min(1.0, plausibility))
    }

    /// The longest run of consecutive nils, which is what determines how large a bridged jump can be.
    private func longestGap(_ horizonY: [Int?]) -> Int {
        var longest = 0, current = 0
        for value in horizonY {
            if value == nil { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        return longest
    }

    func testWhetherBridgedGapsChangeAnyMethodsConfidence() async throws {
        let dir = try fixtureDirectory()
        let frames = try FileManager.default.contentsOfDirectory(atPath: dir.path)
          .filter { $0.hasSuffix(".tiff") && $0 != "horizon.tiff" }
          .sorted()
          .prefix(1)
          .map { dir.appendingPathComponent($0) }
        try XCTSkipIf(frames.isEmpty, "no frames in the reference sequence")

        print("""

        ========== combined-detector confidence measurement ==========
        the five base methods detect() merges, on \(frames.count) real frames
        """)

        var anyGaps = false
        var worstDelta = 0.0
        var inclusionFlips = 0
        var comparisons = 0

        for frameURL in frames {
            guard let image = PixelatedImage(filename: frameURL.path) else { continue }
            let (scaled, _, _) = CombinedHorizonDetector.scaleForProcessing(
                                   image, maxDim: baseWorkingSize)
            let params = CombinedHorizonDetector.Params()
            let height = image.height

            var methods: [(String, [Int?])] = []
            if let otsu = await CombinedHorizonDetector.runOtsu(scaled: scaled, image: image) {
                methods.append(("otsu", otsu))
            }
            if let dp = await CombinedHorizonDetector.runDP(scaled: scaled, image: image,
                                                            params: params) {
                methods.append(("dp", dp))
            }
            methods.append(("siox", CombinedHorizonDetector.runSIOX(scaled: scaled, image: image,
                                                                   params: params)))
            methods.append(("grad", CombinedHorizonDetector.runGradProfile(scaled: scaled,
                                                                          image: image)))
            methods.append(("tex", CombinedHorizonDetector.runTexture(scaled: scaled, image: image)))

            print("""

            --- \(frameURL.lastPathComponent) (\(image.width)x\(image.height)) ---
              method  defined/total   nils  longestGap   shipped   adjacent     delta  included
            """)

            for (name, horizonY) in methods {
                let defined = horizonY.compactMap { $0 }.count
                let nils = horizonY.count - defined
                let gap = longestGap(horizonY)
                let shipped = CombinedHorizonDetector.horizonConfidence(horizonY,
                                                                        imageHeight: height)
                let adjacent = confidenceWithAdjacentDiffs(horizonY, imageHeight: height)
                let delta = abs(shipped - adjacent)
                let shippedIncluded = shipped > 0.05
                let adjacentIncluded = adjacent > 0.05

                if nils > 0 { anyGaps = true }
                worstDelta = max(worstDelta, delta)
                comparisons += 1
                if shippedIncluded != adjacentIncluded { inclusionFlips += 1 }

                print(String(format:
                  "  %-6@  %5d/%-5d  %5d  %10d   %7.4f   %8.4f  %8.4f  %@",
                  name as NSString, defined, horizonY.count, nils, gap,
                  shipped, adjacent, delta,
                  (shippedIncluded == adjacentIncluded
                     ? (shippedIncluded ? "both yes" : "both no")
                     : "FLIPPED") as NSString))
            }
        }

        print("""

        ========== verdict ==========
        any method produced a gap:            \(anyGaps ? "YES" : "no")
        comparisons:                          \(comparisons)
        worst confidence delta:               \(String(format: "%.6f", worstDelta))
        inclusion decisions that flipped:     \(inclusionFlips)
        =============================

        """)

        // A regression guard on the conclusion, not just a printout: if a base method ever starts
        // returning gaps, the "inert" verdict above stops holding and this fails rather than the
        // finding quietly becoming live again.
        XCTAssertGreaterThan(comparisons, 0, "no base method produced an array to measure")
        XCTAssertFalse(anyGaps,
                       "a base method now returns nil columns, so horizonConfidence's bridged-gap " +
                       "finding is live again — re-run this with more frames and reconsider the fix")
        XCTAssertEqual(worstDelta, 0, accuracy: 1e-9,
                       "the compacted and adjacent forms diverged, which only happens with gaps")
        XCTAssertEqual(inclusionFlips, 0)
    }
}
