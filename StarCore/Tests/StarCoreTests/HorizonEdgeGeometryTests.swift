import XCTest
@testable import StarCore

/// Horizon code that built a Swift range from frame geometry trapped when the geometry was
/// degenerate: an expected horizon far outside the frame, or a search band of a few rows.
final class HorizonEdgeGeometryTests: FrameHarnessTestCase {

    /// A band narrower than 2 * derivR + 1 rows has no variance transition to find.
    func testTextureMethodOnAFiveRowFrameReportsNothingInsteadOfTrapping() {
        let image = FrameHarness.syntheticFrame(width: 40, height: 5, horizonRow: 2)
        let result = CombinedHorizonDetector.runTexture(scaled: image, image: image)
        XCTAssertEqual(result.count, 40)
        XCTAssertTrue(result.allSatisfy { $0 == nil })
    }

    func testTextureMethodOnATallFrameStillFindsAHorizon() {
        let image = FrameHarness.syntheticFrame(width: 64, height: 120, horizonRow: 60)
        let result = CombinedHorizonDetector.runTexture(scaled: image, image: image)
        XCTAssertEqual(result.count, 64)
    }

    /// An expected Y far below the frame empties the band for that column; the refinement must
    /// skip the column rather than trap on `bandTop...bandBottom`.
    func testBrightnessRefinementSkipsColumnsWhoseBandIsOutsideTheFrame() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "edgegeom")
        harness = h
        let processor = await h.frames[0].horizonProcessor

        let original = FrameHarness.syntheticFrame(width: 40, height: 60, horizonRow: 30)
        let maskImage = FrameHarness.syntheticMask(width: 40, height: 60) { _ in 30 }
        let detected = try XCTUnwrap(HorizonMask(maskImage))
        let stats = [ReferenceHorizonFrameStats(frameIndex: 1,
                                                skyGaussian: nil, groundGaussian: nil,
                                                minHorizonY: 30, maxHorizonY: 30,
                                                horizonYPerColumn: [Int?](repeating: 30, count: 40),
                                                medianSkyBrightness: 0.4,
                                                medianGroundBrightness: 0.1)]
        // every column expects a horizon 10,000 rows down
        let far = [Int?](repeating: 10_000, count: 40)
        _ = await processor.referenceStatsBrightnessRefinedHorizonMask(
            detected: detected, original: original, stats: stats,
            expectedYPerColumn: far, searchRadius: 10)
        // and far above
        let above = [Int?](repeating: -10_000, count: 40)
        _ = await processor.referenceStatsBrightnessRefinedHorizonMask(
            detected: detected, original: original, stats: stats,
            expectedYPerColumn: above, searchRadius: 10)
    }
}
