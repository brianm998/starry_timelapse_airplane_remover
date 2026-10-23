import XCTest
@testable import StarCore

/// `borderBrightness` reads the frame's original once per outlier group through a weakly-held
/// cache. Holding one strong reference across the pass is what makes those reads hits.
final class OriginalHoldTests: FrameHarnessTestCase {

    func testAHeldOriginalTurnsEveryLaterReadIntoACacheHit() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "originalhold")
        harness = h
        let accessor = h.imageAccessor

        func misses() async -> UInt { await imageCache.prepareUpdate().1 }
        func hits() async -> UInt { await imageCache.prepareUpdate().0 }

        // without a hold: each read decodes again once the previous image is gone
        let startMisses = await misses()
        for _ in 0..<3 {
            _ = try await accessor.loadFinal(frameIndex: 0, type: .original, atSize: .original)
        }
        let unheldMisses = await misses() - startMisses
        XCTAssertGreaterThanOrEqual(unheldMisses, 2, "premise: unheld reads should keep missing")

        // with one strong reference held, only the first read can miss
        let held = try await accessor.loadFinal(frameIndex: 0, type: .original, atSize: .original)
        let before = await misses()
        let beforeHits = await hits()
        for _ in 0..<5 {
            _ = try await accessor.loadFinal(frameIndex: 0, type: .original, atSize: .original)
        }
        let heldMisses = await misses() - before
        let heldHits = await hits() - beforeHits
        withExtendedLifetime(held) {}
        XCTAssertEqual(heldMisses, 0)
        XCTAssertEqual(heldHits, 5)
    }
}
