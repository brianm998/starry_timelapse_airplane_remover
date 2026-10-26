import XCTest
@testable import StarCore

/// The keys of the two horizon caches that could serve a stale or someone else's answer.
final class HorizonCacheKeyTests: XCTestCase {

    // MARK: - star aligned mask digest

    /// A repaint of a stretch 50 columns wide and 10 rows deep: under 600 pixels of a 2000x1000
    /// mask. A one-in-643 stride over the plane steps straight over a change this small.
    func testAFiftyByTenRepaintChangesTheDigest() {
        let w = 2000, h = 1000
        let before = FrameHarness.syntheticMask(width: w, height: h) { _ in 700 }
        let after = FrameHarness.syntheticMask(width: w, height: h) { x in (900...949).contains(x) ? 710 : 700 }
        XCTAssertNotEqual(StarAlignedHorizonMaskCache.digest(of: before),
                          StarAlignedHorizonMaskCache.digest(of: after))
    }

    func testTheSameHorizonHasTheSameDigestWhateverWrapsIt() {
        let a = FrameHarness.syntheticMask(width: 300, height: 200) { x in 100 + x % 7 }
        let b = FrameHarness.syntheticMask(width: 300, height: 200) { x in 100 + x % 7 }
        XCTAssertEqual(StarAlignedHorizonMaskCache.digest(of: a), StarAlignedHorizonMaskCache.digest(of: b))
    }

    func testTheExtentIsPartOfTheDigest() {
        let a = FrameHarness.syntheticMask(width: 300, height: 200) { _ in 100 }
        let b = FrameHarness.syntheticMask(width: 300, height: 220) { _ in 100 }
        XCTAssertNotEqual(StarAlignedHorizonMaskCache.digest(of: a), StarAlignedHorizonMaskCache.digest(of: b))
    }

    /// The cache itself: a touched-up mask is a miss, not a hit on the old intersection.
    func testARepaintedMaskIsNotServedTheStaleIntersection() async throws {
        let w = 800, h = 400
        let base = FrameHarness.syntheticMask(width: w, height: h) { _ in 300 }
        let touched = FrameHarness.syntheticMask(width: w, height: h) { x in (400...449).contains(x) ? 310 : 300 }
        let homography: [Double] = [1, 0, 0, 0, 1, 0, 0, 0, 1]
        let cache = StarAlignedHorizonMaskCache()
        _ = await cache.mask(from: base, homographies: [homography])
        _ = await cache.mask(from: touched, homographies: [homography])
        let stats = await cache.stats()
        XCTAssertEqual(stats.computes, 2, "the touched-up mask was served the first mask's intersection")
        XCTAssertEqual(stats.hits, 0)
    }

    // MARK: - reference stats registry

    private func stats(_ index: Int, sky: Double) -> ReferenceHorizonFrameStats {
        ReferenceHorizonFrameStats(frameIndex: index, skyGaussian: nil, groundGaussian: nil,
                                   minHorizonY: 1, maxHorizonY: 2, horizonYPerColumn: [1, 2],
                                   medianSkyBrightness: sky, medianGroundBrightness: 0.1)
    }

    func testTwoSequencesWithReferencesAtTheSameIndexGetTheirOwnStatistics() async {
        let registry = ReferenceHorizonStatsRegistry()
        let a = await registry.cache(sequence: "/seq/A/horizonReference", neighborhoodSize: 1, bucketCount: 256)
        let b = await registry.cache(sequence: "/seq/B/horizonReference", neighborhoodSize: 1, bucketCount: 256)
        await a.set(stats(12, sky: 0.25))
        let inA = await a.stats(for: 12)
        let inB = await b.stats(for: 12)
        XCTAssertEqual(inA?.medianSkyBrightness, 0.25)
        XCTAssertNil(inB, "sequence B was served sequence A's statistics for frame 12")
    }

    func testADifferentNeighbourhoodOrBucketCountIsADifferentCache() async {
        let registry = ReferenceHorizonStatsRegistry()
        let base = await registry.cache(sequence: "/s", neighborhoodSize: 1, bucketCount: 256)
        let sameAgain = await registry.cache(sequence: "/s", neighborhoodSize: 1, bucketCount: 256)
        let otherNeighbourhood = await registry.cache(sequence: "/s", neighborhoodSize: 5, bucketCount: 256)
        let otherBuckets = await registry.cache(sequence: "/s", neighborhoodSize: 1, bucketCount: 64)
        XCTAssertTrue(base === sameAgain)
        XCTAssertFalse(base === otherNeighbourhood)
        XCTAssertFalse(base === otherBuckets)
    }

    func testRepaintingClearsAFramesStatsInEverySequence() async {
        let registry = ReferenceHorizonStatsRegistry()
        let a = await registry.cache(sequence: "/a", neighborhoodSize: 1, bucketCount: 256)
        let b = await registry.cache(sequence: "/b", neighborhoodSize: 1, bucketCount: 256)
        await a.set(stats(3, sky: 0.4)); await b.set(stats(3, sky: 0.5)); await b.set(stats(4, sky: 0.6))
        await registry.clearStats(for: 3)
        let a3 = await a.stats(for: 3), b3 = await b.stats(for: 3), b4 = await b.stats(for: 4)
        XCTAssertNil(a3)
        XCTAssertNil(b3)
        XCTAssertNotNil(b4, "an unrelated frame was cleared")
    }

    func testClosingASequenceDropsItsCaches() async {
        let registry = ReferenceHorizonStatsRegistry()
        _ = await registry.cache(sequence: "/keep", neighborhoodSize: 1, bucketCount: 256)
        _ = await registry.cache(sequence: "/close", neighborhoodSize: 1, bucketCount: 256)
        _ = await registry.cache(sequence: "/close", neighborhoodSize: 3, bucketCount: 256)
        await registry.removeSequence("/close")
        let remaining = await registry.cacheCount
        XCTAssertEqual(remaining, 1)
    }
}
