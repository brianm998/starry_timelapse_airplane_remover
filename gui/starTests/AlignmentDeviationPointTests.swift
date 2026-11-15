import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The alignment window's per-warp quality marking.
///
/// `DeviationPoint.isGood` was hardcoded `true`, which made the tooltip's green/red
/// deviation reading say "good" about every warp ever measured, and sat next to an
/// `.opacity(point.isGood ? 1.0 : 0.4) // XXX doesn't work` on a `LineMark` — which could
/// not have worked, since a LineMark's style applies to the segment it draws and cannot
/// fade one reading out of a continuous line.  It is now computed from
/// `HomographyResultsCodable.partitionWarps()` and drawn as a mark of its own.
final class AlignmentDeviationPointTests: XCTestCase {

    /// Two frames from the `11_30_2024-a9-1-aurora-topaz` sequence whose star alignment
    /// was measured correctly and which the per-frame heuristics nonetheless distrust part
    /// of — frame 1 here has 3 of its 8 warps flagged, frame 2 has 1.  Slopes taken from
    /// the run's own `deviation` values, scaled so the flagged ones land outside the ±8%
    /// band the same way the real ones do.
    private func warps(
      forFrame frameIndex: Int,
      slopes: [Int: Double]
    ) -> [AlignmentWarpInfoCodable] {
        slopes.map { offset, slope in
            let d = Double(offset)
            // ty dominates, as it does on this sequence; tx carries the rate
            let scale = slope / 6.0
            return AlignmentWarpInfoCodable(
              homography: [1, 0, -2.6 * d * scale,
                           0, 1, -6.0 * d * scale,
                           0, 0, 1],
              alignmentState: .homographySuccess,
              frameIndex: frameIndex + offset)
        }
        .sorted { $0.frameIndex < $1.frameIndex }
    }

    /// A set every warp of which sits on the same slope: nothing to flag.
    func testAUniformSetHasNoDistrustedWarps() {
        let uniform = Dictionary(uniqueKeysWithValues:
                                   [-4, -3, -2, -1, 1, 2, 3, 4].map { ($0, 6.0) })
        let points = AlignmentDeviationChart.deviationPoints(
          frames: [warps(forFrame: 0, slopes: uniform)])
        XCTAssertEqual(points.count, 8)
        XCTAssertTrue(points.allSatisfy(\.isGood))
    }

    /// One warp well off the frame's own median slope is marked, and only that one.
    func testOnlyTheDistrustedWarpIsMarked() {
        var slopes = Dictionary(uniqueKeysWithValues:
                                  [-4, -3, -2, -1, 1, 2, 3, 4].map { ($0, 6.0) })
        slopes[-4] = 4.0        // ratio 0.67 against a 0.926 floor
        let points = AlignmentDeviationChart.deviationPoints(
          frames: [warps(forFrame: 0, slopes: slopes)])
        XCTAssertEqual(points.count, 8)
        let marked = points.filter { !$0.isGood }.map(\.offset)
        XCTAssertEqual(marked, [-4])
    }

    /// The marking is per frame, computed against that frame's own median slope — one
    /// frame's flagged warp must not mark the same offset on its neighbour.
    func testMarkingIsPerFrameNotPerOffset() {
        let uniform = Dictionary(uniqueKeysWithValues:
                                   [-4, -3, -2, -1, 1, 2, 3, 4].map { ($0, 6.0) })
        var odd = uniform
        odd[3] = 9.0
        let points = AlignmentDeviationChart.deviationPoints(
          frames: [warps(forFrame: 0, slopes: uniform),
                   warps(forFrame: 1, slopes: odd)])
        let markedOnFrame0 = points.filter { !$0.isGood && $0.baseFrame == 0 }
        let markedOnFrame1 = points.filter { !$0.isGood && $0.baseFrame == 1 }
        XCTAssertTrue(markedOnFrame0.isEmpty)
        XCTAssertEqual(markedOnFrame1.map(\.offset), [3])
    }

    /// Deviation is drawn signed so the two directions separate on the chart, and the
    /// offset-zero self entry is never a point.
    func testPointsAreSignedByOffsetAndExcludeSelf() {
        let uniform = Dictionary(uniqueKeysWithValues:
                                   [-2, -1, 1, 2].map { ($0, 6.0) })
        var withSelf = warps(forFrame: 5, slopes: uniform)
        withSelf.append(AlignmentWarpInfoCodable(homography: [1,0,0, 0,1,0, 0,0,1],
                                                 alignmentState: .homographySuccess,
                                                 frameIndex: 5))
        let points = AlignmentDeviationChart.deviationPoints(
          frames: Array(repeating: [], count: 5) + [withSelf])
        XCTAssertEqual(points.count, 4)
        XCTAssertFalse(points.contains { $0.offset == 0 })
        for point in points {
            XCTAssertEqual(point.signedDeviation > 0, point.offset > 0,
                           "offset \(point.offset)")
        }
    }
}
