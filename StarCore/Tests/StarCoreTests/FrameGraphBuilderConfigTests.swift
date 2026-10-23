import XCTest
@testable import StarCore

/// `FrameGraphBuilder.set(configManager:)` is called again for every session and run.
final class FrameGraphBuilderConfigTests: XCTestCase {

    private func manager() async -> ConfigManager {
        let path = NSTemporaryDirectory() + "fgbc-\(UUID().uuidString).json"
        return await MainActor.run { ConfigManager(configFilename: path, config: Config()) }
    }

    func testSettingTheSameManagerAgainDoesNotAddAnotherCallback() async {
        let builder = FrameGraphBuilder()
        let m = await manager()
        for _ in 0..<5 { await builder.set(configManager: m) }
        let count = await MainActor.run { m.updateCallbackCount }
        XCTAssertEqual(count, 1, "each call added another update callback")
    }

    func testAManagerTheBuilderHasMovedOnFromNoLongerDrivesIt() async throws {
        let builder = FrameGraphBuilder()
        let a = await manager(), b = await manager()
        await builder.set(configManager: a)
        await builder.set(configManager: b)

        var changed = await b.config()
        changed.resourceProfile = .light
        let b2 = changed
        let lightDepth = changed.pipelineDepth
        await MainActor.run { b.update(b2, save: false) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let depthAfterB = await builder.queue.maxConcurrentOperationCount
        XCTAssertEqual(depthAfterB, lightDepth)

        var stale = await a.config()
        stale.resourceProfile = .balanced
        let stale2 = stale
        await MainActor.run { a.update(stale2, save: false) }   // the old manager changes
        try await Task.sleep(nanoseconds: 100_000_000)
        let depthAfterA = await builder.queue.maxConcurrentOperationCount
        XCTAssertEqual(depthAfterA, lightDepth, "an old manager's change reached the builder")
    }

    func testTheCurrentManagersChangesStillReachTheBuilder() async throws {
        let builder = FrameGraphBuilder()
        let m = await manager()
        await builder.set(configManager: m)
        await builder.set(configManager: m)
        var changed = await m.config()
        changed.resourceProfile = .light
        let c = changed
        let expected = changed.pipelineDepth
        await MainActor.run { m.update(c, save: false) }
        try await Task.sleep(nanoseconds: 100_000_000)
        let depth = await builder.queue.maxConcurrentOperationCount
        XCTAssertEqual(depth, expected)
    }
}
