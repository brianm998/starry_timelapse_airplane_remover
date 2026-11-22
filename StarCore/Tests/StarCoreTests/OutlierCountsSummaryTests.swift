import XCTest
import Foundation
import StarCppBridge
@testable import StarCore

/// The per-frame decision-count summary, and releasing a frame's groups from memory without losing them.
final class OutlierCountsSummaryTests: FrameHarnessTestCase {

    private func makeGroup(id: UInt16, at origin: Int, frameIndex: Int = 0) -> OutlierGroup {
        let bounds = BoundingBox(min: Coord(x: origin, y: origin), max: Coord(x: origin + 3, y: origin + 3))
        var pixelSet: Set<SortablePixel> = []
        for y in origin..<(origin + 4) { for x in origin..<(origin + 4) {
            pixelSet.insert(SortablePixel(x: x, y: y, value: .sixteenBit(1000)))
        } }
        return OutlierGroup(id: id, size: 16, brightness: 1000, bounds: bounds, frameIndex: frameIndex,
                            imageWidth: 128, imageHeight: 128,
                            pixels: [UInt16](repeating: 1000, count: 16), pixelSet: pixelSet)
    }

    /// Three groups (keep, remove, undecided) written to disk with their decisions and summary.
    private func writeFixture(_ h: FrameHarness, _ outlier: FrameOutlierProcessor) async throws {
        let saved = OutlierGroups(frameIndex: 0, config: h.config)
        let a = makeGroup(id: 1, at: 10), b = makeGroup(id: 2, at: 30), c = makeGroup(id: 3, at: 50)
        _ = await a.shouldRemove(.userSelected(true))
        _ = await b.shouldRemove(.userSelected(false))
        await saved.add(a); await saved.add(b); await saved.add(c)
        try await saved.writeOutliersBinary(to: await outlier.outliersDirname)
        try await saved.write(to: h.config.outlierOutputDirname)
    }

    func testCountsRoundTripAndMissingIsNil() throws {
        let dir = NSTemporaryDirectory() + "counts-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        XCTAssertNil(OutlierCounts.load(frameDir: dir))
        let counts = OutlierCounts(positive: 3, negative: 2, undecided: 1, trash: 7)
        try JSONEncoder().encode(counts).write(to: URL(fileURLWithPath: OutlierCounts.path(frameDir: dir)))
        XCTAssertEqual(OutlierCounts.load(frameDir: dir), counts)
    }

    func testSummaryEqualsRecomputedCountsWithoutLoadingGroups() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "countsummary")
        harness = h
        let outlier = await h.frames[0].outlierProcessor
        try await writeFixture(h, outlier)

        let stored = OutlierCounts.load(frameDir: await outlier.outliersDirname)
        XCTAssertEqual(stored, OutlierCounts(positive: 1, negative: 1, undecided: 1, trash: 0))

        let loaded = await outlier.loadCountsFromSummary()
        XCTAssertTrue(loaded)
        let groups = await outlier.getOutlierGroups()
        XCTAssertNil(groups, "counts must not load the groups")
    }

    func testMissingSummaryFallsBackToOneLoadThatWritesIt() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "countfallback")
        harness = h
        let outlier = await h.frames[0].outlierProcessor
        try await writeFixture(h, outlier)
        let dir = await outlier.outliersDirname
        try FileManager.default.removeItem(atPath: OutlierCounts.path(frameDir: dir))

        let loaded = await outlier.loadCountsFromSummary()
        XCTAssertTrue(loaded)
        XCTAssertEqual(OutlierCounts.load(frameDir: dir),
                       OutlierCounts(positive: 1, negative: 1, undecided: 1, trash: 0))
        let groups = await outlier.getOutlierGroups()
        XCTAssertNil(groups, "the fallback load is released again")
    }

    func testReleaseThenReloadGivesSameGroups() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "releasereload")
        harness = h
        let outlier = await h.frames[0].outlierProcessor
        try await writeFixture(h, outlier)

        try await outlier.loadOutliers(loadOnly: true)
        func snapshot() async -> [String] {
            guard let groups = await outlier.getOutlierGroups() else { return [] }
            var rows: [String] = []
            for (id, g) in await groups.getMembers() {
                rows.append("\(id) \(g.bounds) \(String(describing: await g.shouldRemove()))")
            }
            return rows.sorted()
        }
        let before = await snapshot()
        XCTAssertEqual(before.count, 3)

        let released = await outlier.releaseOutlierGroups()
        XCTAssertTrue(released)
        let gone = await outlier.getOutlierGroups()
        XCTAssertNil(gone)

        try await outlier.loadOutliers(loadOnly: true)
        let after = await snapshot()
        XCTAssertEqual(before, after)
    }

    func testEditedFrameIsNeverReleased() async throws {
        let h = try await FrameHarness.make(frameCount: 1, width: 128, height: 128, named: "releaseedited")
        harness = h
        let frame = h.frames[0]
        let outlier = await frame.outlierProcessor
        try await writeFixture(h, outlier)
        try await outlier.loadOutliers(loadOnly: true)

        await frame.markAsChanged()
        let released = await outlier.releaseOutlierGroups()
        XCTAssertFalse(released, "an unsaved edit must keep its groups")
        let kept = await outlier.getOutlierGroups()
        XCTAssertNotNil(kept)

        await frame.changesHandled()
        let releasedAfter = await outlier.releaseOutlierGroups()
        XCTAssertTrue(releasedAfter)
    }
}
