import XCTest
import Foundation
@testable import StarCore

/// `FinalHorizonMaskBudget` bounds how many frames keep a cached final horizon mask.
///
/// Without it every frame kept its mask until it reached `.complete`, which no frame can
/// before the whole sequence has been aligned — so the first half of a run held one
/// full-frame mask per frame processed, 38GB on a 36GB machine 889 frames into a 1911-frame
/// sequence, and the MemoryMonitor's reality brake slowed the run to one op a minute.
///
/// The first group pins the bookkeeping with stand-in holders; the second runs real horizon
/// merges and checks that only the most recently used frames are left holding a mask.
final class FinalHorizonMaskBudgetTests: FrameHarnessTestCase {

    /// Stands in for a frame: counts how often it was asked to let its mask go.
    private actor FakeHolder: FinalHorizonMaskHolder {
        private(set) var releases = 0
        func releaseCachedFinalHorizonMask() async { releases += 1 }
    }

    // MARK: - the bookkeeping

    func testHoldersUpToTheLimitAreAllKept() async {
        let budget = FinalHorizonMaskBudget(limit: 3)
        let a = FakeHolder(), b = FakeHolder(), c = FakeHolder()

        var evicted = await budget.holding(a)
        XCTAssertTrue(evicted.isEmpty)
        evicted = await budget.holding(b)
        XCTAssertTrue(evicted.isEmpty)
        evicted = await budget.holding(c)
        XCTAssertTrue(evicted.isEmpty)

        let count = await budget.count
        XCTAssertEqual(count, 3)
    }

    func testTheLeastRecentlyUsedIsEvictedFirst() async {
        let budget = FinalHorizonMaskBudget(limit: 2)
        let a = FakeHolder(), b = FakeHolder(), c = FakeHolder()

        _ = await budget.holding(a)
        _ = await budget.holding(b)
        let evicted = await budget.holding(c)

        XCTAssertEqual(evicted.count, 1)
        XCTAssertTrue(evicted.first === a, "the oldest holder should have been the one to go")
        let aHeld = await budget.isHolding(a)
        let bHeld = await budget.isHolding(b)
        let cHeld = await budget.isHolding(c)
        XCTAssertFalse(aHeld)
        XCTAssertTrue(bHeld)
        XCTAssertTrue(cHeld)
    }

    /// A cache hit books the holder again, which is what keeps a frame still being worked on
    /// from being evicted in favour of one that has moved on.
    func testUsingAMaskAgainKeepsItsHolderFromBeingEvicted() async {
        let budget = FinalHorizonMaskBudget(limit: 2)
        let a = FakeHolder(), b = FakeHolder(), c = FakeHolder()

        _ = await budget.holding(a)
        _ = await budget.holding(b)
        _ = await budget.holding(a)          // a served its mask again
        let evicted = await budget.holding(c)

        XCTAssertEqual(evicted.count, 1)
        XCTAssertTrue(evicted.first === b, "b was the least recently used once a was touched")
    }

    func testTheHolderJustBookedIsNeverTheOneEvicted() async {
        let budget = FinalHorizonMaskBudget(limit: 1)
        let a = FakeHolder(), b = FakeHolder()

        _ = await budget.holding(a)
        let evicted = await budget.holding(b)

        XCTAssertTrue(evicted.first === a)
        let bHeld = await budget.isHolding(b)
        XCTAssertTrue(bHeld)
    }

    /// A frame that lets its mask go on its own — on reaching `.complete`, or a horizon edit —
    /// must not keep a place it no longer uses, or the budget would evict live masks to make
    /// room for dead ones.
    func testAReleasedHolderGivesUpItsPlace() async {
        let budget = FinalHorizonMaskBudget(limit: 2)
        let a = FakeHolder(), b = FakeHolder(), c = FakeHolder()

        _ = await budget.holding(a)
        _ = await budget.holding(b)
        await budget.released(a)
        let evicted = await budget.holding(c)

        XCTAssertTrue(evicted.isEmpty, "a's place was free, so nothing should have had to go")
    }

    /// The budget holds its holders weakly, so it never keeps a frame alive, and a frame that
    /// has gone takes up no place.  Both halves at once: a budget that kept the departed
    /// holder alive would still count it, and would hand it back for eviction below.
    func testAHolderThatHasGoneAwayTakesNoPlace() async {
        let budget = FinalHorizonMaskBudget(limit: 2)
        let b = FakeHolder(), c = FakeHolder()

        // booked, and gone again as soon as this returns
        func bookATemporaryHolder() async { _ = await budget.holding(FakeHolder()) }
        await bookATemporaryHolder()

        _ = await budget.holding(b)
        let evicted = await budget.holding(c)
        XCTAssertTrue(evicted.isEmpty, "the departed holder's place should have been reused")
        let count = await budget.count
        XCTAssertEqual(count, 2)
    }

    func testShrinkingTheLimitReleasesTheOverflow() async {
        let budget = FinalHorizonMaskBudget(limit: 4)
        let holders = (0..<4).map { _ in FakeHolder() }
        for holder in holders { _ = await budget.holding(holder) }

        await budget.configure(limit: 2)

        var releases: [Int] = []
        for holder in holders { releases.append(await holder.releases) }
        XCTAssertEqual(releases, [1, 1, 0, 0], "the two least recently used should have been released")
        let count = await budget.count
        XCTAssertEqual(count, 2)
    }

    func testTheLimitScalesWithConcurrencyAboveAFloor() {
        XCTAssertEqual(FinalHorizonMaskBudget.limit(forConcurrency: 12), 24)
        XCTAssertEqual(FinalHorizonMaskBudget.limit(forConcurrency: 1),
                       FinalHorizonMaskBudget.minimumLimit)
    }

    // MARK: - real frames

    /// The case that stalled the run: frames merging their horizons one after another, none of
    /// them able to complete yet.  Every frame used to keep its mask; now only the most
    /// recently used ones do.
    func testOnlyTheMostRecentlyMergedFramesKeepTheirMasks() async throws {
        let h = try await FrameHarness.make(frameCount: 5, named: "mask-budget")
        harness = h
        let budget = FinalHorizonMaskBudget(limit: 2)
        for frame in h.frames { await frame.horizonProcessor.setMaskBudgetForTesting(budget) }

        for index in 1...3 {
            let op = HorizonMergeOp(frame: h.frames[index]) { _ in }
            await op.asyncExecute()
        }

        let first = await h.frames[1].cachedFinalHorizonMaskForTesting()
        let second = await h.frames[2].cachedFinalHorizonMaskForTesting()
        let third = await h.frames[3].cachedFinalHorizonMaskForTesting()
        XCTAssertNil(first, "the least recently used frame should have let its mask go")
        XCTAssertNotNil(second)
        XCTAssertNotNil(third)
        let count = await budget.count
        XCTAssertEqual(count, 2)
    }

    /// Being evicted costs a decode, not the mask: the next reader gets it back from disk.
    func testAnEvictedFrameStillGetsItsMaskBack() async throws {
        let h = try await FrameHarness.make(frameCount: 5, named: "mask-budget-reload")
        harness = h
        let budget = FinalHorizonMaskBudget(limit: 1)
        for frame in h.frames { await frame.horizonProcessor.setMaskBudgetForTesting(budget) }

        for index in 1...2 {
            let op = HorizonMergeOp(frame: h.frames[index]) { _ in }
            await op.asyncExecute()
        }
        let evicted = await h.frames[1].cachedFinalHorizonMaskForTesting()
        XCTAssertNil(evicted, "precondition: frame 1 was pushed out by frame 2")

        let reloaded = try await h.frames[1].loadOrCreateFinalHorizonMask()
        XCTAssertNotNil(reloaded, "the merged mask on disk should have been decoded again")
        let nowHeld = await h.frames[1].cachedFinalHorizonMaskForTesting()
        let pushedOut = await h.frames[2].cachedFinalHorizonMaskForTesting()
        XCTAssertNotNil(nowHeld)
        XCTAssertNil(pushedOut, "with room for one, reloading frame 1 pushes frame 2 out")
    }

    /// Reaching `.complete` releases the mask, and with it the frame's place in the budget.
    func testCompletingAFrameFreesItsPlace() async throws {
        let h = try await FrameHarness.make(frameCount: 5, named: "mask-budget-complete")
        harness = h
        let budget = FinalHorizonMaskBudget(limit: 4)
        for frame in h.frames { await frame.horizonProcessor.setMaskBudgetForTesting(budget) }

        let op = HorizonMergeOp(frame: h.frames[2]) { _ in }
        await op.asyncExecute()
        let booked = await budget.isHolding(h.frames[2].horizonProcessor)
        XCTAssertTrue(booked)

        await h.frames[2].releaseRecomputableState()

        let stillBooked = await budget.isHolding(h.frames[2].horizonProcessor)
        XCTAssertFalse(stillBooked)
        let cached = await h.frames[2].cachedFinalHorizonMaskForTesting()
        XCTAssertNil(cached)
    }
}
