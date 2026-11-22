import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// Two callers asking for a frame's outliers at once both get them: the second waits for the first
/// instead of returning at once with nothing loaded.
final class OutlierLoadCoalescingTests: FrameHarnessTestCase {

    private func writeGroup(for outlier: FrameOutlierProcessor, config: Config) async throws {
        let bounds = BoundingBox(min: Coord(x: 10, y: 10), max: Coord(x: 13, y: 13))
        var pixelSet: Set<SortablePixel> = []
        let pixels = [UInt16](repeating: 1000, count: 16)
        for y in 10..<14 { for x in 10..<14 {
            pixelSet.insert(SortablePixel(x: x, y: y, value: .sixteenBit(1000)))
        } }
        let group = OutlierGroup(id: 1, size: 16, brightness: 1000, bounds: bounds, frameIndex: 0,
                                 imageWidth: 1000, imageHeight: 500,
                                 pixels: pixels, pixelSet: pixelSet)
        // written through a separate collection, so the processor itself still has nothing loaded
        let saved = OutlierGroups(frameIndex: 0, config: config)
        await saved.add(group)
        try await saved.writeOutliersBinary(to: await outlier.outliersDirname)
    }

    func testConcurrentLoadsBothSeeGroups() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "coalesce")
        harness = h
        let outlier = await h.frames[0].outlierProcessor
        try await writeGroup(for: outlier, config: h.config)
        let before = await outlier.getOutlierGroups()
        XCTAssertNil(before)

        async let first: Void = outlier.loadOutliers(loadOnly: true)
        async let second: Void = outlier.loadOutliers(loadOnly: true)
        try await first
        try await second

        let groups = await outlier.getOutlierGroups()
        XCTAssertNotNil(groups, "both callers must come back with the groups loaded")
        let count = await groups?.getMembers().count
        XCTAssertEqual(count, 1)
        let loading = await outlier.isLoadingOutliers
        XCTAssertFalse(loading)

        // a third call finds them loaded and keeps the same collection: the file was read once
        try await outlier.loadOutliers(loadOnly: true)
        let again = await outlier.getOutlierGroups()
        XCTAssertTrue(again === groups)
    }

    func testCancelledLoadDoesNotBlockNext() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "coalescecancel")
        harness = h
        let outlier = await h.frames[0].outlierProcessor

        let cancelled = Task { try await outlier.loadOutliers() }
        cancelled.cancel()
        _ = try? await cancelled.value

        let loading = await outlier.isLoadingOutliers
        XCTAssertFalse(loading, "a cancelled load must clear its in-flight marker")

        try await writeGroup(for: outlier, config: h.config)
        try await outlier.loadOutliers(loadOnly: true)
        let groups = await outlier.getOutlierGroups()
        XCTAssertNotNil(groups, "the next call must load afresh")
    }
}
