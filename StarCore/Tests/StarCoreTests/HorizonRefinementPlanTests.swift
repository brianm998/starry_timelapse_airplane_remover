import XCTest
@testable import StarCore

/// Which frames a painted reference horizon leaves stale, and -- the part that is not
/// obvious -- which ones stay stale after a run over part of the sequence has taken some of
/// them on.  The gui shows those frames in orange, enables two buttons by them and deletes
/// their rendered output on the strength of them, so a frame dropped from this set is a
/// frame with no picture that nothing says is owed one.
final class HorizonRefinementPlanTests: XCTestCase {

    private func affected(updated: Set<Int>,
                          references: [Int],
                          stillPending: Set<Int> = [],
                          frames: Int = 20) -> Set<Int> {
        HorizonRefinementPlan.affectedFrames(
          updatedReferences: updated,
          referenceIndices: references,
          stillPending: stillPending,
          frameCount: frames
        )
    }

    /// The only reference in the sequence: every other frame interpolates from it.
    func testALoneReferenceAffectsEveryOtherFrame() {
        XCTAssertEqual(affected(updated: [10], references: [10], frames: 20),
                       Set((0..<20).filter { $0 != 10 }))
    }

    /// With references either side, a repaint reaches only as far as its neighbours.
    func testASpanStopsAtTheNeighbouringReferences() {
        XCTAssertEqual(affected(updated: [10], references: [5, 10, 15], frames: 20),
                       Set(6...14).subtracting([10]))
    }

    /// A reference frame serves its painted mask directly, so it is never in the set --
    /// including the frame that was just painted, which was an interpolated one until then.
    func testReferenceFramesAreNeverAffected() {
        let result = affected(updated: [10], references: [5, 10, 15], frames: 20)
        for reference in [5, 10, 15] {
            XCTAssertFalse(result.contains(reference), "frame \(reference)")
        }
    }

    func testNothingUpdatedAffectsNothing() {
        XCTAssertEqual(affected(updated: [], references: [5, 10]), [])
    }

    /// The regression the `stillPending` parameter exists for: a run over part of the sequence took
    /// frames 6...9, and then another reference was painted somewhere else entirely.
    /// Frames 11...14 are still owed their refinement and must survive the recompute.
    func testFramesAPartialRunLeftBehindSurviveANewReference() {
        let result = affected(updated: [17], references: [5, 10, 15, 17],
                              stillPending: Set(11...14), frames: 20)
        XCTAssertTrue(result.isSuperset(of: 11...14))
        // ...alongside the span the new reference at 17 opens: 16, and 18...19.
        XCTAssertTrue(result.isSuperset(of: [16, 18, 19]))
    }

    /// Still pending, still not a reference: a frame painted since must drop out even if it
    /// was pending before.
    func testAPendingFrameThatHasBecomeAReferenceDropsOut() {
        XCTAssertFalse(affected(updated: [], references: [12], stillPending: [12])
                         .contains(12))
    }

    // MARK: - the record

    /// Saving a reference marks its span, and reports who moved in and out.
    func testSavingAReferenceMarksItsSpan() {
        var plan = HorizonRefinementPlan()
        let change = plan.recordReferenceUpdated(frameIndex: 10, referenceIndices: [5, 10, 15], frameCount: 20)
        XCTAssertEqual(plan.updatedReferences, [10])
        XCTAssertEqual(plan.affected, Set(6...14).subtracting([10]))
        XCTAssertEqual(change.nowPending, plan.affected)
        XCTAssertTrue(change.noLongerPending.isEmpty)
    }

    /// A frame that becomes a reference is no longer pending, and is reported as such.
    func testAFramePaintedAsAReferenceStopsBeingPending() {
        var plan = HorizonRefinementPlan()
        plan.recordReferenceUpdated(frameIndex: 10, referenceIndices: [5, 10, 15], frameCount: 20)
        let change = plan.recordReferenceUpdated(frameIndex: 12, referenceIndices: [5, 10, 12, 15], frameCount: 20)
        XCTAssertFalse(plan.affected.contains(12))
        XCTAssertTrue(change.noLongerPending.contains(12))
    }

    func testNothingIsPendingUntilSomethingIsSaved() {
        XCTAssertFalse(HorizonRefinementPlan().hasPending { _ in false })
    }

    /// A lone reference next to another has no span to refine but still has its own output to render again.
    func testAReferenceWithOutputIsPendingEvenWithNoSpan() {
        var plan = HorizonRefinementPlan()
        plan.recordReferenceUpdated(frameIndex: 6, referenceIndices: [5, 6], frameCount: 7)
        XCTAssertTrue(plan.affected.isEmpty)
        XCTAssertFalse(plan.hasPending { _ in false })
        XCTAssertTrue(plan.hasPending { $0 == 6 })
    }

    /// Once "Later" has taken a frame's output away, the record of that is the only thing saying it is owed one.
    func testAStrippedFrameIsOwedARenderWhateverIsOnDisk() {
        var plan = HorizonRefinementPlan()
        plan.markStripped([3])
        XCTAssertTrue(plan.hasPending { _ in false })
        XCTAssertEqual(plan.framesNeedingRerender([3, 4]) { _ in false }, [3])
    }

    func testThePromptQuotesTheFramesAndTheRendersAndIsNilWithNothingToAskAbout() {
        var plan = HorizonRefinementPlan()
        XCTAssertNil(plan.promptCounts { _ in true })
        plan.recordReferenceUpdated(frameIndex: 10, referenceIndices: [5, 10, 15], frameCount: 20)
        // frames 6...14 minus 10 are affected (8); 7 and 10 have output
        let counts = plan.promptCounts { $0 == 7 || $0 == 10 }
        XCTAssertEqual(counts, .init(frameCount: 9, renderCount: 2))
    }

    /// A run over part of the sequence takes only what is in its range, and leaves the rest pending.
    func testARunTakesOnlyTheWorkInItsRange() {
        var plan = HorizonRefinementPlan()
        plan.recordReferenceUpdated(frameIndex: 10, referenceIndices: [5, 10, 15], frameCount: 20)
        let taken = plan.take(range: 6...9)
        XCTAssertEqual(taken?.frames, Set(6...9))
        XCTAssertEqual(plan.affected, Set(11...14))
        XCTAssertEqual(taken?.referencesToClear, [10], "every waiting reference's numbers are stale, not just the ones taken")
        XCTAssertEqual(plan.updatedReferences, [10], "the reference's own frame is outside the range")
    }

    func testARunWithNothingInItsRangeTakesNothing() {
        var plan = HorizonRefinementPlan()
        plan.recordReferenceUpdated(frameIndex: 10, referenceIndices: [5, 10, 15], frameCount: 20)
        XCTAssertNil(plan.take(range: 0...2))
        XCTAssertEqual(plan.affected, Set(6...14).subtracting([10]))
    }

    /// A stopped run gives back everything it claimed.
    func testAStoppedRunReturnsWhatItClaimed() {
        var plan = HorizonRefinementPlan()
        plan.recordReferenceUpdated(frameIndex: 10, referenceIndices: [5, 10, 15], frameCount: 20)
        plan.markStripped([8])
        let claim = plan.claimAll()
        XCTAssertTrue(plan.affected.isEmpty && plan.updatedReferences.isEmpty && plan.stripped.isEmpty)
        XCTAssertEqual(plan.inFlight, claim)

        let back = plan.returnInFlight()
        XCTAssertEqual(back, claim.affected)
        XCTAssertEqual(plan.affected, claim.affected)
        XCTAssertEqual(plan.updatedReferences, [10])
        XCTAssertEqual(plan.stripped, [8])
        XCTAssertNil(plan.inFlight)
    }

    /// A run that finished keeps what it claimed.
    func testAFinishedRunKeepsWhatItClaimed() {
        var plan = HorizonRefinementPlan()
        plan.recordReferenceUpdated(frameIndex: 10, referenceIndices: [5, 10, 15], frameCount: 20)
        _ = plan.claimAll()
        plan.finishClaim()
        XCTAssertNil(plan.returnInFlight())
        XCTAssertTrue(plan.affected.isEmpty)
    }
}
