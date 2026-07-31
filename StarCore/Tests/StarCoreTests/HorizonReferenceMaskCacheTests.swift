import XCTest
import Foundation
@testable import StarCore

/// The global `reference.tiff` is one file shared by every frame of a static sequence, but it used to
/// be decoded once per frame — a user's crash log showed 1,108 decodes of the same 42MP TIFF inside a
/// 16-second run, each followed by `ensureGray8U()` and a full-image `horizonBounds()` scan.
///
/// Two properties have to hold together for the cache to be worth having.  It must actually collapse
/// those reads, and it must never answer with a mask the user has since repainted: `reference.tiff` is
/// rewritten by the horizon painter mid-session, so a stale hit means the painting silently does
/// nothing.  Both are covered here, along with the deliberate non-caching of per-frame references.
final class HorizonReferenceMaskCacheTests: FrameHarnessTestCase {

    /// Counters and cached entry both live for the whole process by design, so each test starts from a
    /// dropped entry and records where the counters stood.
    private var baseline: (loads: Int, hits: Int) = (0, 0)

    override func setUp() async throws {
        try await super.setUp()
        await horizonReferenceMaskCache.invalidateAll()
        baseline = await horizonReferenceMaskCache.stats()
    }

    /// Loads and hits attributable to this test.  The cache is shared across the whole test process, so
    /// the absolute counters carry whatever ran earlier; only the delta says anything.
    private func activity() async -> (loads: Int, hits: Int) {
        let now = await horizonReferenceMaskCache.stats()
        return (now.loads - baseline.loads, now.hits - baseline.hits)
    }

    private func processor(_ h: FrameHarness, at index: Int = 0) async -> FrameHorizonProcessor {
        await h.frames[index].horizonProcessor
    }

    // MARK: - collapsing the repeated reads

    /// The whole point: N frames asking for the same reference cause one decode, not N.
    func testRepeatedLookupsOfTheSameReferenceDecodeItOnce() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "cachehit")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 20),
                                            perFrame: false)

        for attempt in 0..<25 {
            let mask = await horizonReferenceMaskCache.mask(atPath: path)
            XCTAssertNotNil(mask, "lookup \(attempt) found no reference")
        }

        let stats = await activity()
        XCTAssertEqual(stats.loads, 1, "the same unchanged file must only be decoded once")
        XCTAssertEqual(stats.hits, 24, "every lookup after the first must be served from cache")
    }

    /// Frames reach the horizon stage in a batch — the crash log had 14 arrive inside one millisecond.
    /// Concurrent cold misses must still produce a single decode, not one per caller.
    func testConcurrentColdLookupsStillDecodeOnce() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "concurrent")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 30),
                                            perFrame: false)

        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<14 {
                group.addTask { await horizonReferenceMaskCache.mask(atPath: path) != nil }
            }
            for await found in group { XCTAssertTrue(found) }
        }

        let stats = await activity()
        XCTAssertEqual(stats.loads, 1, "14 simultaneous askers must not each decode the file")
        XCTAssertEqual(stats.hits, 13)
    }

    /// A hit has to be the real mask, not merely non-nil: bounds and size come from the file.
    func testACachedHitCarriesTheSameMaskAsTheFirstLoad() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "sameMask")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 25),
                                            perFrame: false)

        let loadedFirst  = await horizonReferenceMaskCache.mask(atPath: path)
        let loadedSecond = await horizonReferenceMaskCache.mask(atPath: path)
        let first  = try XCTUnwrap(loadedFirst)
        let second = try XCTUnwrap(loadedSecond)

        XCTAssertEqual(first.horizonTopY, second.horizonTopY)
        XCTAssertEqual(first.horizonBottomY, second.horizonBottomY)
        XCTAssertEqual(second.image.width, 64)
        XCTAssertEqual(second.image.height, 64)
    }

    // MARK: - never serving a repaint stale

    /// The failure that would matter to a user: repaint the horizon and the next load still hands back
    /// the old one.  Freshness comes from the file stamp, so this must hold with no invalidate call.
    func testAReferenceRewrittenOnDiskIsReloadedWithoutAnyInvalidateCall() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "rewrite")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 10),
                                            perFrame: false)

        let loadedBefore = await horizonReferenceMaskCache.mask(atPath: path)
        let before = try XCTUnwrap(loadedBefore)

        // Rewrite in place with a different horizon.  Same path, same dimensions, same byte count —
        // which is exactly the repaint case, and why size alone cannot be the freshness signal.
        FrameHarness.flatMask(width: 64, height: 64, at: 50).writeTIFFEncoding(toFilename: path)

        let loadedAfter = await horizonReferenceMaskCache.mask(atPath: path)
        let after = try XCTUnwrap(loadedAfter)

        XCTAssertNotEqual(before.horizonBottomY, after.horizonBottomY,
                          "a repainted reference must not be served from the pre-repaint copy")
        let stats = await activity()
        XCTAssertEqual(stats.loads, 2, "the changed file has to be decoded again")
    }

    /// `invalidate` is the explicit path the in-process writers take; it must drop what it names.
    func testInvalidateForcesTheNextLookupToReload() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "invalidate")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 15),
                                            perFrame: false)

        _ = await horizonReferenceMaskCache.mask(atPath: path)
        await horizonReferenceMaskCache.invalidate(path: path)
        _ = await horizonReferenceMaskCache.mask(atPath: path)

        let stats = await activity()
        XCTAssertEqual(stats.loads, 2)
        XCTAssertEqual(stats.hits, 0, "an invalidated entry must not serve a hit")
    }

    /// Invalidating some other path must not discard the entry that is held — there is one slot, so a
    /// careless `forget` would clear it on behalf of an unrelated file.
    func testInvalidatingADifferentPathLeavesTheHeldEntryAlone() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "otherpath")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 15),
                                            perFrame: false)

        _ = await horizonReferenceMaskCache.mask(atPath: path)
        await horizonReferenceMaskCache.invalidate(path: path + ".someone-elses-sequence")
        _ = await horizonReferenceMaskCache.mask(atPath: path)

        let stats = await activity()
        XCTAssertEqual(stats.loads, 1)
        XCTAssertEqual(stats.hits, 1)
    }

    /// The daemon's `clearReference` handler deletes `reference.tiff` outright, from another module.
    /// A deleted reference must read as absent, and must not linger to be served if the path returns.
    func testADeletedReferenceReadsAsAbsentAndIsNotResurrected() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "deleted")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 10),
                                            perFrame: false)

        let planted = await horizonReferenceMaskCache.mask(atPath: path)
        XCTAssertNotNil(planted)
        try FileManager.default.removeItem(atPath: path)

        let gone = await horizonReferenceMaskCache.mask(atPath: path)
        XCTAssertNil(gone, "a deleted reference must not be served from cache")

        // Recreate at the same path with a different horizon; the pre-deletion copy must not return.
        FrameHarness.flatMask(width: 64, height: 64, at: 55).writeTIFFEncoding(toFilename: path)
        let reloaded = await horizonReferenceMaskCache.mask(atPath: path)
        let fresh = try XCTUnwrap(reloaded)
        XCTAssertGreaterThan(fresh.horizonBottomY, 40,
                             "the recreated file must be decoded, not answered from the old entry")
    }

    /// A sequence with no painted reference is the common case: a cheap nil that occupies no slot.
    func testAMissingReferenceIsNilAndCachesNothing() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "absent")
        harness = h
        let (directory, _) = try XCTUnwrap(h.horizonReferenceDirectory())
        let absent = directory.appendingPathComponent("reference.tiff").path

        let missing = await horizonReferenceMaskCache.mask(atPath: absent)
        XCTAssertNil(missing)
        let stats = await activity()
        XCTAssertEqual(stats.loads, 0)
        XCTAssertEqual(stats.hits, 0)
    }

    /// Opening a second sequence replaces the single slot rather than accumulating masks — the bounded
    /// footprint is the reason this is one slot and not a dictionary.
    func testASecondSequenceReplacesTheHeldEntry() async throws {
        let first = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "seqA")
        harness = first
        let firstPath = try first.plantReferenceMask(
          FrameHarness.flatMask(width: 64, height: 64, at: 12), perFrame: false)
        let firstMask = await horizonReferenceMaskCache.mask(atPath: firstPath)
        XCTAssertNotNil(firstMask)

        let second = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "seqB")
        defer { second.cleanUp() }
        let secondPath = try second.plantReferenceMask(
          FrameHarness.flatMask(width: 64, height: 64, at: 48), perFrame: false)
        XCTAssertNotEqual(firstPath, secondPath, "the harnesses must not share a temp directory")

        let secondMask = await horizonReferenceMaskCache.mask(atPath: secondPath)
        XCTAssertNotNil(secondMask)
        // Back to the first: the second evicted it, so this is a load, not a hit.
        let firstAgain = await horizonReferenceMaskCache.mask(atPath: firstPath)
        XCTAssertNotNil(firstAgain)

        let stats = await activity()
        XCTAssertEqual(stats.loads, 3)
        XCTAssertEqual(stats.hits, 0, "one slot means the other sequence's mask is not retained")
    }

    // MARK: - what the loader does with it

    /// End to end through the processor, over three frames, which is the shape of the run that burned
    /// 1,108 reads: every frame resolves the same global reference and only the first decodes it.
    func testEveryFrameServesTheGlobalReferenceFromOneDecode() async throws {
        let h = try await FrameHarness.make(frameCount: 3, width: 64, height: 64, named: "viaLoader")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 22),
                                 perFrame: false)

        for index in 0..<3 {
            let mask = try await processor(h, at: index).loadOrCreateHorizonMask()
            XCTAssertEqual(mask.image.width, 64, "frame \(index) got no usable reference")
        }

        let stats = await activity()
        XCTAssertEqual(stats.loads, 1, "the reference must be decoded once for the whole sequence")
        XCTAssertGreaterThanOrEqual(stats.hits, 2, "the later frames must be served from cache")
    }

    /// Per-frame references are intentionally left uncached — one reader each, so caching them would
    /// pin a mask per frame and never serve a hit.  Guards against someone "tidying" that into it.
    func testPerFrameReferencesDoNotGoThroughTheSharedCache() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "perFrame")
        harness = h
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 33),
                                 perFrame: true)

        _ = try await processor(h).loadOrCreateHorizonMask()

        let stats = await activity()
        XCTAssertEqual(stats.loads, 0, "a per-frame reference must not occupy the shared slot")
        XCTAssertEqual(stats.hits, 0)
    }

    /// Saving a painted reference must leave the cache ready to serve the new mask, not the one that
    /// was there when the painter opened.  This is the gui's repaint path.
    func testSavingAPaintedReferenceInvalidatesWhatWasCached() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "repaint")
        harness = h
        let path = try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 10),
                                            perFrame: false)

        let loadedBefore = await horizonReferenceMaskCache.mask(atPath: path)
        let before = try XCTUnwrap(loadedBefore)

        try await processor(h).saveHorizonReferenceMask(
          paintedYPerColumn: [Int?](repeating: 48, count: 64),
          viewWidth: 64,
          viewHeight: 64
        )

        let loadedAfter = await horizonReferenceMaskCache.mask(atPath: path)
        let after = try XCTUnwrap(loadedAfter)
        XCTAssertNotEqual(before.horizonBottomY, after.horizonBottomY,
                          "the freshly painted reference must be what the next frame loads")
    }
}
