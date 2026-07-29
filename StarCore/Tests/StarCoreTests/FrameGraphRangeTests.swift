import XCTest
@testable import StarCore

/// Tests for the frame-index range arithmetic behind
/// `FrameGraphBuilder.build(frames:startIndex:endIndex:closure:errorClosure:)`.
///
/// The bugs these exist for: `endIndex` used to be honored by the horizon and keypoint
/// stages only, so the homography, outlier and merge stages ran on every frame handed
/// in — a partial range still wrote output for the whole sequence, and did it with
/// keypoints detected inline by the homography op, outside the `KeypointLimiter`.
/// Separately, an empty sequence or an inverted range reached `startIndex...lastIndex`
/// and trapped.
final class FrameGraphRangeTests: XCTestCase {

    /// Stands in for `FrameAlignmentProcessor.calculateNeighborIndices`: a window of
    /// `radius` frames either side, clamped to the sequence, excluding the frame itself.
    private func neighbours(count: Int, radius: Int) -> [Int: [Int]] {
        var ret: [Int: [Int]] = [:]
        for frameIndex in 0..<count {
            let low = max(0, frameIndex - radius)
            let high = min(count - 1, frameIndex + radius)
            ret[frameIndex] = (low...high).filter { $0 != frameIndex }
        }
        return ret
    }

    private func range(
      count: Int,
      startIndex: Int = 0,
      endIndex: Int? = nil,
      alignmentRadius: Int = 4,
      horizonMergeRadius: Int? = nil
    ) -> FrameGraphRange {
        FrameGraphRange(
          sequenceIndices: Array(0..<count),
          startIndex: startIndex,
          endIndex: endIndex,
          alignmentNeighbours: neighbours(count: count, radius: alignmentRadius),
          horizonMergeNeighbours: horizonMergeRadius.map { neighbours(count: count, radius: $0) } ?? [:]
        )
    }

    // MARK: - the full sequence

    /// The default arguments must not change what a full run does — every stage still
    /// covers every frame.
    func testAFullRangeCoversEveryFrameAtEveryStage() {
        let r = range(count: 20, horizonMergeRadius: 8)
        XCTAssertEqual(r.output, Array(0..<20))
        XCTAssertEqual(r.keypoint, Array(0..<20))
        XCTAssertEqual(r.horizon, Array(0..<20))
        XCTAssertFalse(r.isEmpty)
    }

    // MARK: - a partial range

    /// The point of the whole type: output stays inside the request, while the stages
    /// feeding it reach out to the neighbours the boundary frames align against.
    func testAPartialRangeRestrictsOutputAndWidensAlignment() {
        let r = range(count: 50, startIndex: 20, endIndex: 24,
                      alignmentRadius: 4, horizonMergeRadius: 8)

        XCTAssertEqual(r.output, [20, 21, 22, 23, 24],
                       "only the requested frames may have their output written")
        XCTAssertEqual(r.keypoint, Array(16...28),
                       "frame 20 aligns against 16 and frame 24 against 28, " +
                       "so both need keypoints")
        XCTAssertEqual(r.horizon, Array(8...36),
                       "each keypoint frame's merged mask pulls in masks 8 either side")
    }

    /// A single-frame request is the narrowest case, and the one a
    /// `startIndex == endIndex` caller expects to work at all.
    func testASingleFrameRangeStillWidensForItsNeighbours() {
        let r = range(count: 50, startIndex: 30, endIndex: 30, alignmentRadius: 4)
        XCTAssertEqual(r.output, [30])
        XCTAssertEqual(r.keypoint, Array(26...34))
    }

    /// A range at the start of the sequence cannot widen below frame 0.
    func testWideningClampsToTheSequenceBounds() {
        let low = range(count: 50, startIndex: 0, endIndex: 2, alignmentRadius: 4)
        XCTAssertEqual(low.output, [0, 1, 2])
        XCTAssertEqual(low.keypoint, Array(0...6))

        let high = range(count: 50, startIndex: 47, alignmentRadius: 4)
        XCTAssertEqual(high.output, [47, 48, 49])
        XCTAssertEqual(high.keypoint, Array(43...49))
    }

    /// `endIndex` is a frame index, not a count, and one past the end is a clamp
    /// rather than an error.
    func testAnEndIndexPastTheSequenceIsClamped() {
        let r = range(count: 10, startIndex: 5, endIndex: 999)
        XCTAssertEqual(r.output, [5, 6, 7, 8, 9])
    }

    /// A static sequence has one horizon merge op that votes over the whole sequence, so
    /// there is nothing to widen the horizon stage to beyond the keypoint frames.
    func testWithNoHorizonMergeNeighboursTheHorizonStageMatchesTheKeypointStage() {
        let r = range(count: 50, startIndex: 20, endIndex: 24, horizonMergeRadius: nil)
        XCTAssertEqual(r.horizon, r.keypoint)
        XCTAssertEqual(r.keypoint, Array(16...28))
    }

    // MARK: - ranges that select nothing

    /// `for frameIndex in startIndex...lastIndex` trapped on all four of these.

    func testAnInvertedRangeSelectsNothing() {
        let r = range(count: 20, startIndex: 10, endIndex: 4)
        XCTAssertTrue(r.isEmpty)
        XCTAssertEqual(r.output, [])
        XCTAssertEqual(r.keypoint, [])
        XCTAssertEqual(r.horizon, [])
    }

    func testAnEmptySequenceSelectsNothing() {
        let r = FrameGraphRange(
          sequenceIndices: [],
          startIndex: 0,
          endIndex: nil,
          alignmentNeighbours: [:],
          horizonMergeNeighbours: [:]
        )
        XCTAssertTrue(r.isEmpty)
    }

    func testAStartIndexPastTheSequenceSelectsNothing() {
        XCTAssertTrue(range(count: 10, startIndex: 10).isEmpty)
        XCTAssertTrue(range(count: 10, startIndex: 100, endIndex: 200).isEmpty)
    }

    func testAnEndIndexBelowTheSequenceSelectsNothing() {
        let r = FrameGraphRange(
          sequenceIndices: [10, 11, 12],
          startIndex: 0,
          endIndex: 4,
          alignmentNeighbours: [:],
          horizonMergeNeighbours: [:]
        )
        XCTAssertTrue(r.isEmpty)
    }

    // MARK: - frame indices are not array indices

    /// A caller that passes a subset of the sequence must not leave the builder asking
    /// for an op on a frame it was never given, even though the neighbour lists name it.
    func testNeighboursMissingFromTheSequenceAreDropped() {
        // frames 5...9 only, but each names neighbours across the full 0...49 sequence
        let r = FrameGraphRange(
          sequenceIndices: Array(5...9),
          startIndex: 7,
          endIndex: 7,
          alignmentNeighbours: neighbours(count: 50, radius: 4),
          horizonMergeNeighbours: neighbours(count: 50, radius: 8)
        )
        XCTAssertEqual(r.output, [7])
        XCTAssertEqual(r.keypoint, Array(5...9), "frames 3, 4, 10 and 11 were not passed in")
        XCTAssertEqual(r.horizon, Array(5...9))
    }

    /// Gaps are preserved rather than filled in — nothing here counts frames.
    func testAGappedSequenceKeepsItsGaps() {
        let indices = [0, 1, 2, 10, 11, 12, 20]
        let r = FrameGraphRange(
          sequenceIndices: indices,
          startIndex: 1,
          endIndex: 11,
          alignmentNeighbours: neighbours(count: 21, radius: 4),
          horizonMergeNeighbours: [:]
        )
        XCTAssertEqual(r.output, [1, 2, 10, 11])
        // 1's neighbours reach 0, 11's reach up to 15 — of which only 12 was passed in
        XCTAssertEqual(r.keypoint, [0, 1, 2, 10, 11, 12])
    }

    /// Every list is sorted no matter what order the frames arrived in, since the
    /// builder walks them to create ops and the moving-alignment validator relies on
    /// frame-index order.
    func testTheListsAreSortedRegardlessOfInputOrder() {
        let r = FrameGraphRange(
          sequenceIndices: [4, 0, 3, 1, 2],
          startIndex: 0,
          endIndex: nil,
          alignmentNeighbours: neighbours(count: 5, radius: 1),
          horizonMergeNeighbours: neighbours(count: 5, radius: 2)
        )
        XCTAssertEqual(r.output, [0, 1, 2, 3, 4])
        XCTAssertEqual(r.keypoint, [0, 1, 2, 3, 4])
        XCTAssertEqual(r.horizon, [0, 1, 2, 3, 4])
    }

    /// A negative `startIndex` is a clamp, not an out-of-bounds walk.
    func testANegativeStartIndexIsHarmless() {
        let r = range(count: 5, startIndex: -10, endIndex: 1, alignmentRadius: 1)
        XCTAssertEqual(r.output, [0, 1])
        XCTAssertEqual(r.keypoint, [0, 1, 2])
    }

    // MARK: - stage containment

    /// Each stage must be a superset of the one it feeds, or the builder attaches a
    /// dependency to an op that was never created.
    func testEachStageContainsTheOneItFeeds() {
        for startIndex in [0, 1, 7, 18] {
            for endIndex in [1, 7, 18, 19] where endIndex >= startIndex {
                let r = range(count: 20, startIndex: startIndex, endIndex: endIndex,
                              alignmentRadius: 4, horizonMergeRadius: 8)
                let output = Set(r.output)
                let keypoint = Set(r.keypoint)
                let horizon = Set(r.horizon)
                XCTAssertTrue(output.isSubset(of: keypoint),
                              "\(startIndex)...\(endIndex): output frames need keypoints")
                XCTAssertTrue(keypoint.isSubset(of: horizon),
                              "\(startIndex)...\(endIndex): keypoint frames need a horizon")
            }
        }
    }
}
