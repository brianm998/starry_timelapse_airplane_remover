import XCTest
@testable import StarCore

/// Tests for how `AlignmentValidationOp.validateStaticStarAlignment` chooses one frame's
/// homography set as the model for a static sequence and re-targets it onto every frame.
///
/// The bug these exist for: the chosen set used to be moved onto each frame by shifting
/// every neighbor's frame index by a constant, which carries over the *source* frame's
/// neighbor count and offset shape.  Frames near the ends of a sequence legitimately have
/// fewer neighbors than interior ones — with `numberAlignedNeighborFrames` of 8, frame 0
/// of a 19 frame sequence has 4 and frame 17 has 5 — so whenever the median landed on an
/// end frame, every interior frame inherited the truncated shape.  The merge looks its
/// homography up by offset, so the missing offsets silently dropped merge sources: one
/// measured run stored 5 entries per frame where another stored 8, purely because an
/// unrelated change moved which frame won the median.
final class AlignmentValidationTests: XCTestCase {

    // MARK: - fixtures

    /// Mirrors `FrameAlignmentProcessor.calculateNeighborIndices`, including the detail
    /// that makes end frames asymmetric: `endFrame` is derived from the *unclamped*
    /// `startFrame`, so clamping the start does not widen the end.
    private func neighborIndices(
      for frameIndex: Int,
      alignmentNumber: Int,
      frameCount: Int
    ) -> [Int] {
        var halfNumber = alignmentNumber/2
        if alignmentNumber % 2 == 1 { halfNumber += 1 }
        var startFrame = frameIndex - halfNumber
        var endFrame = startFrame + alignmentNumber + 1
        if startFrame < 0 { startFrame = 0 }
        if endFrame > frameCount { endFrame = frameCount }
        guard startFrame < endFrame else { return [] }
        return (startFrame..<endFrame).filter { $0 != frameIndex }
    }

    /// A homography whose translation is exactly linear in the frame offset, which is the
    /// model a static sequence's sky rotation approximates.  `scale` lets a set be made
    /// deliberately worse so it loses the median.
    private func linearHomography(offset: Int, scale: Double = 1) -> [Double] {
        let d = Double(offset) * scale
        return [
          1, 0, 2.5 * d,
          0, 1, -1.25 * d,
          0, 0, 1
        ]
    }

    private func results(
      forFrame frameIndex: Int,
      neighbors: [Int],
      scale: Double = 1
    ) -> HomographyResultsCodable {
        HomographyResultsCodable(
          for: frameIndex,
          with: neighbors.map { neighborIndex in
              AlignmentWarpInfoCodable(
                homography: linearHomography(offset: neighborIndex - frameIndex,
                                             scale: scale),
                alignmentState: .homographySuccess,
                frameIndex: neighborIndex
              )
          }
        )
    }

    /// Every frame of a 19 frame sequence at the default neighbor count, which is the
    /// sequence the bug was measured on (`test_data/test_a7sii_10`).
    private func wholeSequence(
      frameCount: Int = 19,
      alignmentNumber: Int = 8
    ) -> [HomographyResultsCodable] {
        (0..<frameCount).map { frameIndex in
            results(forFrame: frameIndex,
                    neighbors: neighborIndices(for: frameIndex,
                                               alignmentNumber: alignmentNumber,
                                               frameCount: frameCount))
        }
    }

    private func offsets(of results: HomographyResultsCodable) -> [Int] {
        results.neighborHomography.map { $0.frameIndex - results.frameIndex }.sorted()
    }

    // MARK: - the fixture matches the real neighbor arithmetic

    /// Guards the numbers the rest of these tests lean on.  If
    /// `calculateNeighborIndices` changes, this is what should fail first.
    func testEndFramesHaveFewerNeighborsThanInteriorOnes() {
        let counts = (0..<19).map {
            neighborIndices(for: $0, alignmentNumber: 8, frameCount: 19).count
        }
        XCTAssertEqual(counts[0], 4, "frame 0 measures only forward neighbors")
        XCTAssertEqual(counts[17], 5)
        XCTAssertEqual(counts[9], 8, "interior frames measure the full set")
        XCTAssertEqual(Array(counts[4...14]), Array(repeating: 8, count: 11),
                       "frames 4...14 are the full-shape candidates")
        XCTAssertEqual(offsets(of: results(forFrame: 17,
                                          neighbors: neighborIndices(for: 17,
                                                                     alignmentNumber: 8,
                                                                     frameCount: 19))),
                       [-4, -3, -2, -1, 1],
                       "frame 17's measured shape, the one that used to be inherited")
    }

    // MARK: - median selection

    func testMedianIsNeverPickedFromATruncatedFrame() {
        // make the end frames look best, so deviation alone would choose one of them
        var candidates = wholeSequence()
        for frameIndex in [0, 1, 2, 3, 15, 16, 17, 18] {
            candidates[frameIndex] = results(
              forFrame: frameIndex,
              neighbors: neighborIndices(for: frameIndex,
                                         alignmentNumber: 8,
                                         frameCount: 19),
              scale: 0.1        // tiny deviation, would win on deviation alone
            )
        }
        let median = try? XCTUnwrap(medianHomography(among: candidates))
        XCTAssertEqual(median?.total, 8)
        XCTAssertTrue((4...14).contains(median?.frameIndex ?? -1),
                      "expected a full-shape interior frame, got \(median?.frameIndex as Any)")
    }

    func testMedianStillTakesTheMiddleDeviationAmongFullShapeFrames() {
        // frames 4...14 all have 8 neighbors; give each a distinct deviation
        var candidates: [HomographyResultsCodable] = []
        for (rank, frameIndex) in (4...14).enumerated() {
            candidates.append(
              results(forFrame: frameIndex,
                      neighbors: neighborIndices(for: frameIndex,
                                                 alignmentNumber: 8,
                                                 frameCount: 19),
                      scale: Double(rank + 1))
            )
        }
        let median = try? XCTUnwrap(medianHomography(among: candidates))
        // 11 candidates sorted by deviation, index 5 is the middle
        XCTAssertEqual(median?.frameIndex, 9)
    }

    /// A sequence too short for any frame to have a full set still has to produce a
    /// model, from the widest shape available.
    func testMedianFallsBackToTheWidestShapeAvailable() {
        let candidates = wholeSequence(frameCount: 5, alignmentNumber: 8)
        let median = try? XCTUnwrap(medianHomography(among: candidates))
        XCTAssertEqual(median?.total, 4, "no frame of 5 can have 8 neighbors")
    }

    func testMedianOfNothingIsNil() {
        XCTAssertNil(medianHomography(among: []))
    }

    // MARK: - re-targeting onto a frame's own offsets

    /// The regression itself: an end frame's 5 offset shape must not truncate an interior
    /// frame, even when it is handed in as the source.
    func testInteriorFrameKeepsAllEightNeighborsFromATruncatedSource() {
        let truncated = results(forFrame: 17,
                                neighbors: neighborIndices(for: 17,
                                                           alignmentNumber: 8,
                                                           frameCount: 19))
        XCTAssertEqual(truncated.total, 5, "precondition: the source is truncated")

        let rebuilt = HomographyResultsCodable(
          for: 9,
          with: extrapolateNeighborHomography(
            from: truncated,
            toFrameIndex: 9,
            targetNeighborFrameIndices: neighborIndices(for: 9,
                                                       alignmentNumber: 8,
                                                       frameCount: 19)
          )
        )
        XCTAssertEqual(rebuilt.total, 8)
        XCTAssertEqual(offsets(of: rebuilt), [-4, -3, -2, -1, 1, 2, 3, 4])
        XCTAssertEqual(rebuilt.neighborHomography.map { $0.frameIndex },
                       [5, 6, 7, 8, 10, 11, 12, 13],
                       "neighbor frame indices are the target frame's own")
    }

    /// Every frame of the sequence, from every possible source frame: nobody ever loses
    /// an offset they measured.
    func testNoFrameEverLosesAnOffsetItMeasured() {
        let alignmentNumber = 8, frameCount = 19
        let sequence = wholeSequence(frameCount: frameCount,
                                     alignmentNumber: alignmentNumber)
        for source in sequence {
            for targetFrameIndex in 0..<frameCount {
                let expected = neighborIndices(for: targetFrameIndex,
                                               alignmentNumber: alignmentNumber,
                                               frameCount: frameCount)
                let rebuilt = extrapolateNeighborHomography(
                  from: source,
                  toFrameIndex: targetFrameIndex,
                  targetNeighborFrameIndices: expected
                )
                XCTAssertEqual(rebuilt.map { $0.frameIndex }, expected.sorted(),
                               "frame \(targetFrameIndex) from source \(source.frameIndex)")
                XCTAssertTrue(rebuilt.allSatisfy { $0.homography != nil },
                              "frame \(targetFrameIndex) from source \(source.frameIndex) " +
                              "left a neighbor without a homography")
            }
        }
    }

    /// The other half of the shape mismatch: a source wider than the target must not
    /// leave the target holding neighbor indices outside the sequence.  Those used to be
    /// written to the homography database, where the merge ignored them but
    /// `FrameHorizonProcessor` had to filter them out by failing to name a file.
    func testOffsetsTheTargetDoesNotHaveAreDropped() {
        let interior = results(forFrame: 9,
                               neighbors: neighborIndices(for: 9,
                                                          alignmentNumber: 8,
                                                          frameCount: 19))
        let rebuilt = extrapolateNeighborHomography(
          from: interior,
          toFrameIndex: 0,
          targetNeighborFrameIndices: neighborIndices(for: 0,
                                                     alignmentNumber: 8,
                                                     frameCount: 19)
        )
        XCTAssertEqual(rebuilt.map { $0.frameIndex }, [1, 2, 3, 4])
        XCTAssertTrue(rebuilt.allSatisfy { $0.frameIndex > 0 },
                      "no negative frame index may survive")
    }

    /// A frame index in `targetNeighborFrameIndices` is a neighbor list, so the frame
    /// itself has no business being in it — but it must not become a self-referencing
    /// entry with an identity warp if it is.
    func testTheTargetFrameIsNeverItsOwnNeighbor() {
        let source = results(forFrame: 9,
                             neighbors: neighborIndices(for: 9,
                                                        alignmentNumber: 8,
                                                        frameCount: 19))
        let rebuilt = extrapolateNeighborHomography(
          from: source,
          toFrameIndex: 5,
          targetNeighborFrameIndices: [3, 4, 5, 6, 7]
        )
        XCTAssertEqual(rebuilt.map { $0.frameIndex }, [3, 4, 6, 7])
    }

    /// Offsets the source measured are passed through untouched — extrapolation is only
    /// ever a fallback.
    func testMeasuredOffsetsArePassedThroughUnchanged() {
        let source = results(forFrame: 17,
                             neighbors: neighborIndices(for: 17,
                                                        alignmentNumber: 8,
                                                        frameCount: 19))
        let rebuilt = extrapolateNeighborHomography(
          from: source,
          toFrameIndex: 9,
          targetNeighborFrameIndices: neighborIndices(for: 9,
                                                     alignmentNumber: 8,
                                                     frameCount: 19)
        )
        for entry in rebuilt {
            let offset = entry.frameIndex - 9
            guard let measured = source.neighborHomography.first(
                    where: { $0.frameIndex - source.frameIndex == offset })
            else {
                XCTAssertEqual(entry.alignmentState, .usedExistingHomography,
                               "offset \(offset) was not measured, so it is derived")
                continue
            }
            XCTAssertEqual(entry.homography, measured.homography,
                           "offset \(offset) should be the measured matrix verbatim")
            XCTAssertEqual(entry.deviation, measured.deviation)
            XCTAssertEqual(entry.alignmentState, .homographySuccess)
        }
    }

    // MARK: - the extrapolation model

    /// The model has to reproduce the offsets it was fit on, or the filled offsets are
    /// not on the same curve as the measured ones.
    func testModelReproducesTheOffsetsItWasFitOn() throws {
        let source = results(forFrame: 9,
                             neighbors: neighborIndices(for: 9,
                                                        alignmentNumber: 8,
                                                        frameCount: 19))
        let model = try XCTUnwrap(HomographyOffsetModel(from: source))
        for entry in source.neighborHomography {
            let offset = entry.frameIndex - source.frameIndex
            let fit = model.homography(atOffset: offset)
            for (a, b) in zip(fit, try XCTUnwrap(entry.homography)) {
                XCTAssertEqual(a, b, accuracy: 1e-9, "offset \(offset)")
            }
        }
    }

    /// Fit on forward offsets only, evaluated at backward ones: the sign has to flip,
    /// since a warp `d` frames back is the inverse of the one `d` frames forward.
    func testModelExtrapolatesAcrossZeroOffset() throws {
        let forwardOnly = results(forFrame: 0, neighbors: [1, 2, 3, 4])
        let model = try XCTUnwrap(HomographyOffsetModel(from: forwardOnly))
        for offset in [-4, -3, -2, -1] {
            let fit = model.homography(atOffset: offset)
            for (a, b) in zip(fit, linearHomography(offset: offset)) {
                XCTAssertEqual(a, b, accuracy: 1e-9, "offset \(offset)")
            }
        }
    }

    func testModelIsIdentityAtZeroOffset() throws {
        let source = results(forFrame: 9,
                             neighbors: neighborIndices(for: 9,
                                                        alignmentNumber: 8,
                                                        frameCount: 19))
        let model = try XCTUnwrap(HomographyOffsetModel(from: source))
        XCTAssertEqual(model.homography(atOffset: 0),
                       [1, 0, 0,
                        0, 1, 0,
                        0, 0, 1])
    }

    /// A derived entry's deviation must be computed from its own matrix, not copied —
    /// `alignmentLooksOk` checks deviation against frame distance.
    func testDerivedEntriesCarryTheirOwnDeviation() throws {
        let truncated = results(forFrame: 17,
                                neighbors: neighborIndices(for: 17,
                                                           alignmentNumber: 8,
                                                           frameCount: 19))
        let rebuilt = extrapolateNeighborHomography(
          from: truncated,
          toFrameIndex: 9,
          targetNeighborFrameIndices: neighborIndices(for: 9,
                                                     alignmentNumber: 8,
                                                     frameCount: 19)
        )
        for entry in rebuilt {
            XCTAssertEqual(entry.deviation,
                           homographyDeviation(try XCTUnwrap(entry.homography)),
                           accuracy: 1e-9,
                           "offset \(entry.frameIndex - 9)")
        }
        // and the whole rebuilt set still reads as well aligned
        XCTAssertTrue(HomographyResultsCodable(for: 9, with: rebuilt).alignmentLooksOk)
    }

    func testModelNeedsAtLeastOneUsableHomography() {
        let empty = HomographyResultsCodable(for: 4, with: [])
        XCTAssertNil(HomographyOffsetModel(from: empty))

        let allFailed = HomographyResultsCodable(
          for: 4,
          with: [3, 5].map {
              AlignmentWarpInfoCodable(homography: nil,
                                       alignmentState: .noHomographyFound,
                                       frameIndex: $0)
          }
        )
        XCTAssertNil(HomographyOffsetModel(from: allFailed),
                     "nothing to fit when no neighbor produced a matrix")

        // with nothing to fit, every target offset is skipped rather than filled with a
        // bogus matrix — including the two the source does hold, since an entry with no
        // matrix is no measurement
        XCTAssertEqual(
          extrapolateNeighborHomography(from: allFailed,
                                        toFrameIndex: 9,
                                        targetNeighborFrameIndices: [7, 8, 10, 11]).count,
          0)
    }

    /// An offset the source holds but could not solve is treated as unmeasured: the
    /// model covers it, rather than the target inheriting a failure it never had.
    func testUnsolvedSourceOffsetsAreFilledFromTheModel() throws {
        let source = HomographyResultsCodable(
          for: 9,
          with: [5, 6, 7, 8, 10, 11, 12, 13].map { neighborIndex in
              // offset -1 failed to solve, the rest are good
              neighborIndex == 8
                ? AlignmentWarpInfoCodable(homography: nil,
                                           alignmentState: .noHomographyFound,
                                           frameIndex: neighborIndex)
                : AlignmentWarpInfoCodable(
                    homography: linearHomography(offset: neighborIndex - 9),
                    alignmentState: .homographySuccess,
                    frameIndex: neighborIndex
                  )
          }
        )
        let rebuilt = extrapolateNeighborHomography(
          from: source,
          toFrameIndex: 9,
          targetNeighborFrameIndices: [5, 6, 7, 8, 10, 11, 12, 13]
        )
        XCTAssertEqual(rebuilt.count, 8)
        XCTAssertTrue(rebuilt.allSatisfy { $0.homography != nil })
        let filled = try XCTUnwrap(rebuilt.first { $0.frameIndex == 8 })
        XCTAssertEqual(filled.alignmentState, .usedExistingHomography)
        for (a, b) in zip(try XCTUnwrap(filled.homography),
                          linearHomography(offset: -1)) {
            XCTAssertEqual(a, b, accuracy: 1e-9)
        }
    }

    // MARK: - the whole sequence, end to end

    /// What the cli run checks in the homography database, at the level of the arithmetic:
    /// whichever frame wins the median, every interior frame ends up with 8 neighbors and
    /// the sequence total is the same.
    func testEveryFrameGetsItsNaturalNeighborCountFromAnySource() {
        let alignmentNumber = 8, frameCount = 19
        let expectedCounts = (0..<frameCount).map {
            neighborIndices(for: $0,
                            alignmentNumber: alignmentNumber,
                            frameCount: frameCount).count
        }
        // 4+5+6+7 + 11*8 + 7+6+5+4 = 132
        XCTAssertEqual(expectedCounts.reduce(0, +), 132)

        for source in wholeSequence(frameCount: frameCount,
                                    alignmentNumber: alignmentNumber) {
            let counts = (0..<frameCount).map { targetFrameIndex in
                extrapolateNeighborHomography(
                  from: source,
                  toFrameIndex: targetFrameIndex,
                  targetNeighborFrameIndices:
                    neighborIndices(for: targetFrameIndex,
                                    alignmentNumber: alignmentNumber,
                                    frameCount: frameCount)
                ).count
            }
            XCTAssertEqual(counts, expectedCounts,
                           "source frame \(source.frameIndex) changed the shape " +
                           "of the sequence")
            XCTAssertEqual(Array(counts[4...14]), Array(repeating: 8, count: 11),
                           "source frame \(source.frameIndex) truncated an interior frame")
        }
    }
}


/// Tests for `GroundTrackingCoverage`, the count that decides whether the user is told
/// that star could not track the ground.
///
/// The threshold is the whole content of the type, and getting it wrong is quiet in both
/// directions: too permissive and every moving sequence raises a banner about a couple of
/// fills nobody would have noticed, too strict and a sequence whose foreground was clipped
/// to black by a video export finishes with a dirty ground and says nothing about it.
final class GroundTrackingCoverageTests: XCTestCase {

    // MARK: - fixtures

    private func warp(_ frameIndex: Int, solved: Bool) -> AlignmentWarpInfoCodable {
        AlignmentWarpInfoCodable(
          homography: solved ? [1, 0, 0, 0, 1, 0, 0, 0, 1] : nil,
          deviation: 0,
          alignmentState: solved ? .homographySuccess : .noHomographyFound,
          frameIndex: frameIndex
        )
    }

    /// One frame with a neighbour at each of `offsets`, of which the first `solved`
    /// produced a matrix.  `solved: nil` means the homography op left no container at
    /// all, which is a different thing from a container whose warps all failed.
    private func frame(_ index: Int,
                       offsets: [Int],
                       solved: Int?) -> GroundTrackingCoverage.Frame
    {
        let neighbours = offsets.map { index + $0 }
        guard let solved else {
            return GroundTrackingCoverage.Frame(neighborFrameIndices: neighbours,
                                                homography: nil)
        }
        return GroundTrackingCoverage.Frame(
          neighborFrameIndices: neighbours,
          homography: HomographyResultsCodable(
            for: index,
            with: neighbours.enumerated().map { warp($0.element, solved: $0.offset < solved) }
          )
        )
    }

    /// A ten frame sequence, every frame with the same four neighbours and the same
    /// number of them solved.
    private func sequence(solvedPerFrame: Int?) -> [GroundTrackingCoverage.Frame] {
        (0..<10).map { frame($0, offsets: [-2, -1, 1, 2], solved: solvedPerFrame) }
    }

    // MARK: - the threshold

    func testASequenceThatSolvedEveryPairIsSilent() {
        let coverage = GroundTrackingCoverage(frames: sequence(solvedPerFrame: 4))
        XCTAssertEqual(coverage.expectedPairs, 40)
        XCTAssertEqual(coverage.solvedPairs, 40)
        XCTAssertEqual(coverage.failedPairs, 0)
        XCTAssertFalse(coverage.groundWasNotTracked)
    }

    /// Ground estimation failing on individual pairs is ordinary, and the continuity
    /// filter fills those from the frames around them.  A quarter gone is not news.
    func testAFewFailedPairsAreSilent() {
        let coverage = GroundTrackingCoverage(frames: sequence(solvedPerFrame: 3))
        XCTAssertEqual(coverage.failedPairs, 10)
        XCTAssertFalse(coverage.groundWasNotTracked)
    }

    /// The boundary is strict: exactly half still leaves a solid enough local model for
    /// the continuity filter to fill the other half from.
    func testExactlyHalfIsStillSilent() {
        let coverage = GroundTrackingCoverage(frames: sequence(solvedPerFrame: 2))
        XCTAssertEqual(coverage.solvedPairs, 20)
        XCTAssertEqual(coverage.failedPairs, 20)
        XCTAssertEqual(coverage.solvedFraction, 0.5, accuracy: 1e-12)
        XCTAssertFalse(coverage.groundWasNotTracked)
    }

    /// One pair either side of the boundary, so the comparison cannot be off by one and
    /// still pass.
    func testJustPastHalfIsReported() {
        var frames = sequence(solvedPerFrame: 2)
        frames[0] = frame(0, offsets: [-2, -1, 1, 2], solved: 1)
        let coverage = GroundTrackingCoverage(frames: frames)
        XCTAssertEqual(coverage.solvedPairs, 19)
        XCTAssertLessThan(coverage.solvedFraction, 0.5)
        XCTAssertTrue(coverage.groundWasNotTracked)
    }

    func testNothingSolvedAtAllIsReported() {
        let coverage = GroundTrackingCoverage(frames: sequence(solvedPerFrame: 0))
        XCTAssertEqual(coverage.solvedPairs, 0)
        XCTAssertEqual(coverage.failedPairs, 40)
        XCTAssertTrue(coverage.groundWasNotTracked)
    }

    // MARK: - why it counts pairs

    /// The reason the count is per pair: every frame here has a homography container, so
    /// a per-frame count calls this sequence fully measured, and not one pair solved.
    func testAContainerWhoseWarpsAllFailedCountsAsNothingSolved() {
        let frames = sequence(solvedPerFrame: 0)
        XCTAssertTrue(frames.allSatisfy { $0.homography != nil },
                      "the fixture has to have a container per frame for this to mean anything")
        XCTAssertEqual(GroundTrackingCoverage(frames: frames).solvedPairs, 0)
        XCTAssertTrue(GroundTrackingCoverage(frames: frames).groundWasNotTracked)
    }

    /// A frame whose homography op never ran at all counts the same as one whose warps
    /// all failed — both leave those pairs unmeasured.
    func testAMissingContainerCountsTheSameAsAFailedOne() {
        let missing = GroundTrackingCoverage(frames: sequence(solvedPerFrame: nil))
        let failed = GroundTrackingCoverage(frames: sequence(solvedPerFrame: 0))
        XCTAssertEqual(missing.expectedPairs, failed.expectedPairs)
        XCTAssertEqual(missing.solvedPairs, failed.solvedPairs)
        XCTAssertTrue(missing.groundWasNotTracked)
    }

    // MARK: - edges

    /// Frames near the ends of a sequence legitimately have fewer neighbours, so the
    /// expected total is not frame count times neighbour count.  Counting the full
    /// shape for them would invent failures that were never possible.
    func testTruncatedEndFramesCountOnlyTheNeighboursTheyHave() {
        var frames = (1..<9).map { frame($0, offsets: [-2, -1, 1, 2], solved: 4) }
        frames.append(frame(0, offsets: [1, 2], solved: 2))
        frames.append(frame(9, offsets: [-2, -1], solved: 2))
        let coverage = GroundTrackingCoverage(frames: frames)
        XCTAssertEqual(coverage.expectedPairs, 36, "8 interior frames at 4, 2 end frames at 2")
        XCTAssertEqual(coverage.failedPairs, 0)
        XCTAssertFalse(coverage.groundWasNotTracked)
    }

    /// A sequence with nothing to measure has a solved fraction of zero for want of a
    /// denominator, not because anything failed — so it must not raise the warning, and
    /// must not divide by zero getting there.
    func testASequenceWithNoNeighboursAtAllIsSilent() {
        let coverage = GroundTrackingCoverage(frames: [])
        XCTAssertEqual(coverage.expectedPairs, 0)
        XCTAssertEqual(coverage.solvedFraction, 0)
        XCTAssertFalse(coverage.groundWasNotTracked)
    }
}
