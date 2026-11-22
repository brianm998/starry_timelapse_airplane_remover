import XCTest
@testable import StarCore

final class HorizonColumnsCacheTests: FrameHarnessTestCase {

    private func overlays(_ h: FrameHarness, _ index: Int) async -> [HorizonThumbnailOverlay] {
        await h.frames[index].horizonProcessor
            .loadHorizonThumbnailOverlays(thumbnailWidth: 32, thumbnailHeight: 32)
    }

    /// A1: sixty frames sharing one painted reference extract its columns once.
    func testStaticReferenceComputedOnce() async throws {
        let h = try await FrameHarness.make(frameCount: 60, width: 64, height: 64, named: "colcache60")
        harness = h
        await horizonColumnsCache.invalidateAll()
        await horizonReferenceMaskCache.invalidateAll()
        try h.plantReferenceMask(FrameHarness.flatMask(width: 64, height: 64, at: 30), perFrame: false)
        let before = await horizonColumnsCache.stats().extractions
        let loadsBefore = await horizonReferenceMaskCache.stats().loads
        for i in 0..<60 {
            let result = await overlays(h, i)
            XCTAssertEqual(result.first?.yPerColumn.first ?? -1, 15, accuracy: 1)
        }
        let after = await horizonColumnsCache.stats().extractions
        let loadsAfter = await horizonReferenceMaskCache.stats().loads
        XCTAssertEqual(after - before, 1)
        XCTAssertLessThanOrEqual(loadsAfter - loadsBefore, 1)
    }

    /// A2: a valid sidecar gives the line without decoding the mask.
    func testSidecarAvoidsDecode() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "colsidecar")
        harness = h
        await horizonColumnsCache.invalidateAll()
        let path = try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 40), ofType: .horizon)
        let manager = h.configManager
        let config = await MainActor.run { manager.config() }
        // a sidecar that says row 10, which the mask itself does not
        HorizonLineSidecar.write(columns: [Int?](repeating: 10, count: 64), width: 64, height: 64,
                                 frameIndex: 0, maskPath: path, config: config)
        let before = await horizonColumnsCache.stats().extractions
        let result = await overlays(h, 0)
        let after = await horizonColumnsCache.stats().extractions
        XCTAssertEqual(after, before, "no decode, no extraction")
        XCTAssertEqual(result.first?.yPerColumn.first ?? -1, 5, accuracy: 1)
    }

    /// A3: rewriting a mask gives the new line.
    func testRewrittenMaskIsRecomputed() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 64, height: 64, named: "colrewrite")
        harness = h
        await horizonColumnsCache.invalidateAll()
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 40), ofType: .mergedHorizon)
        var result = await overlays(h, 0)
        XCTAssertEqual(result.first?.yPerColumn.first ?? -1, 20, accuracy: 1)
        try await Task.sleep(nanoseconds: 20_000_000)
        try h.plantImage(FrameHarness.flatMask(width: 64, height: 64, at: 20), ofType: .mergedHorizon)
        result = await overlays(h, 0)
        XCTAssertEqual(result.first?.yPerColumn.first ?? -1, 10, accuracy: 1)
    }
}
