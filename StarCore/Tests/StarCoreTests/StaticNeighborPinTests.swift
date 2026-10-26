import XCTest
@testable import StarCore

/// A static-earth op merges `staticNeighborFrames`; their decodes must be held for the op so
/// the star and earth builds share them.
final class StaticNeighborPinTests: FrameHarnessTestCase {

    private func setUpFrame(tripodMoving: Bool) async throws -> FrameAlignmentProcessor {
        let h = try await FrameHarness.make(frameCount: 8, named: "staticpin")
        harness = h
        var config = await h.configManager.config()
        config.tripodHeadWasMoving = tripodMoving
        let manager = h.configManager
        await MainActor.run { manager.update(config, save: false) }
        let processor = await h.frames[3].alignmentProcessor
        await processor.setNumberOfStaticNeighborFrames()
        return processor
    }

    func testAStaticEarthOpPinsItsStaticNeighbours() async throws {
        let processor = try await setUpFrame(tripodMoving: false)
        let staticFiles = await processor.getStaticNeighborFilenames()
        XCTAssertFalse(staticFiles.isEmpty)

        let before = DecodedFrameStore.shared.pinnedPathCount
        let pin = await processor.pinNeighborDecodes()
        let held = DecodedFrameStore.shared.pinnedPathCount - before
        XCTAssertGreaterThanOrEqual(held, Set(staticFiles).count,
                                    "the static merge's neighbours were not all pinned")
        pin.release()
        XCTAssertEqual(DecodedFrameStore.shared.pinnedPathCount, before)
    }

    func testAMovingTripodOpDoesNotPinStaticNeighbours() async throws {
        let processor = try await setUpFrame(tripodMoving: true)
        let staticFiles = await processor.getStaticNeighborFilenames()
        XCTAssertFalse(staticFiles.isEmpty)
        let before = DecodedFrameStore.shared.pinnedPathCount
        let pin = await processor.pinNeighborDecodes()
        let held = DecodedFrameStore.shared.pinnedPathCount - before
        let alignmentOnly = await Set(processor.pinnedAlignmentPaths()).count
        XCTAssertEqual(held, alignmentOnly, "only the alignment neighbours belong to a moving-tripod op")
        pin.release()
    }
}
