import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// `Session.Close` used to remove the registry entry and nothing else: a run kept going against the
/// shared frame-graph builder, the progress streams stayed open, and a pending config write was left
/// to chance.  Closing now stops the run, writes out what is pending, ends every progress stream,
/// and leaves the session unable to start anything.
final class SessionCloseTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SessionCloseTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeSession() async throws -> Session {
        let dir = scratch.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = 4, height = 4
        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        for i in 0..<(width * height) { data[i] = UInt8(i * 7 % 256) }
        let mat = MatWrapper(width: width, height: height,
                             cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 1),
                             bytesPerRow: width,
                             data: UnsafeMutableRawPointer(data),
                             takeOwnership: true)
        mat.write(to: dir.appendingPathComponent("frame0.tif").path)

        let sequence = try ImageSequence(dirname: dir.path, supportedImageFileTypes: [".tif", ".tiff"])
        let info = try await sequence.getImageInfo()
        let sessionDir = scratch.appendingPathComponent("session").path
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        // Paths of its own: a frame graph creates its output directories from these, and with the
        // default (empty) ones they land in the current directory.
        var config = Config()
        config.outputPath = scratch.appendingPathComponent("output").path
        config.tempOutputPath = scratch.appendingPathComponent("temp").path
        let finalConfig = config
        let configManager = await MainActor.run {
            ConfigManager(configFilename: "\(sessionDir)/config.json", config: finalConfig)
        }
        return Session(sessionID: "s", scratchSessionDir: sessionDir,
                       configJsonPath: "\(sessionDir)/config.json",
                       configManager: configManager, imageSequence: sequence, imageInfo: info)
    }

    /// True once `stream` has ended, false if it is still open after `seconds`.
    private func ends(_ stream: AsyncStream<Star_V1_ProgressEvent>, within seconds: Double) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream {}
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    func testClosingEndsEveryProgressStream() async throws {
        let session = try await makeSession()
        let (a, ca) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
        let (b, cb) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
        _ = await session.addProgressSubscriber(ca)
        _ = await session.addProgressSubscriber(cb)

        await session.close()

        let aEnded = await ends(a, within: 5)
        let bEnded = await ends(b, within: 5)
        XCTAssertTrue(aEnded, "a progress stream was left open by Close")
        XCTAssertTrue(bEnded, "a progress stream was left open by Close")
    }

    func testAStreamThatAttachesAfterTheCloseEndsAtOnce() async throws {
        let session = try await makeSession()
        await session.close()

        let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
        _ = await session.addProgressSubscriber(cont)
        let ended = await ends(stream, within: 5)
        XCTAssertTrue(ended, "a stream attached to a closed session would wait forever")
    }

    func testAClosedSessionStartsNothing() async throws {
        let session = try await makeSession()
        let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
        _ = await session.addProgressSubscriber(cont)
        await session.close()

        await session.startProcessing()
        await session.forceReprocess(startIndex: 0, endIndex: nil)
        await session.reprocessFrames(indices: [0], type: .everything)

        var events = 0
        for await _ in stream { events += 1 }
        XCTAssertEqual(events, 0, "a closed session reported a run")
    }

    /// A render asked of a closed session has nothing to save into: false at once, and a cancelled
    /// caller likewise, instead of waiting out the timeout on a queue nobody will run.
    func testRenderNowOnAClosedSessionReturnsFalseAtOnce() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let maybeFrame = await session.frame(at: 0)
        let frame = try XCTUnwrap(maybeFrame)
        await session.close()
        let started = Date()
        let rendered = await session.renderNow(frame)
        XCTAssertFalse(rendered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testRenderNowForACancelledCallerReturnsFalseAtOnce() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let maybeFrame = await session.frame(at: 0)
        let frame = try XCTUnwrap(maybeFrame)
        let task = Task { await session.renderNow(frame) }
        task.cancel()
        let started = Date()
        let rendered = await task.value
        XCTAssertFalse(rendered)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testClosingTwiceIsHarmless() async throws {
        let session = try await makeSession()
        await session.close()
        await session.close()
    }

    func testClosingWritesTheConfigOut() async throws {
        let session = try await makeSession()
        var cfg = await session.config()
        cfg.startupHorizonFramePosition = 3
        await session.configManager.update(cfg)

        await session.close()

        let path = await session.configJsonPath
        let onDisk = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(onDisk.startupHorizonFramePosition, 3, "the pending config write was not flushed")
    }

    /// An edit is saved ten seconds after it is made.  Closing the session cannot wait for that:
    /// it has to save the frame there and then, and not return until it is written.
    func testClosingSavesAnEditedFrameInsteadOfWaitingForItsTimer() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)

        await session.frameEdited(frame)
        var inPurgatory = false
        for _ in 0..<100 {   // the queue puts the frame there from a task of its own
            if await frame.savingState() == .inPurgatory { inPurgatory = true; break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(inPurgatory, "an edit did not queue the frame for saving")

        let started = Date()
        await session.close()

        let state = await frame.savingState()
        XCTAssertEqual(state, .notSaving, "Close returned with the frame still waiting to be saved")
        XCTAssertLessThan(Date().timeIntervalSince(started), 8,
                          "Close waited for the save timer instead of saving at once")
    }

    func testAnEditAfterTheCloseIsNotQueued() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)
        await session.close()

        await session.frameEdited(frame)
        try await Task.sleep(nanoseconds: 300_000_000)
        let state = await frame.savingState()
        XCTAssertEqual(state, .notSaving, "a closed session queued a save")
    }

    // MARK: - FrameInfo.outliers_loaded

    /// A frame whose groups are still on disk reports 0/0/0, the same as a frame with none; the flag is
    /// what tells a client the zeroes are not a fact yet.
    func testFrameInfoSaysWhetherTheOutliersAreLoaded() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)

        let unloaded = await Mapping.frameInfo(frame: frame, outlierGroups: nil)
        XCTAssertFalse(unloaded.outliersLoaded, "unloaded outliers were reported as loaded")

        let config = await session.config()
        let groups = OutlierGroups(frameIndex: 0, config: config)
        let loaded = await Mapping.frameInfo(frame: frame, outlierGroups: groups)
        XCTAssertTrue(loaded.outliersLoaded, "loaded outliers (even none) were reported as unloaded")
        XCTAssertEqual(loaded.numPositiveOutliers + loaded.numNegativeOutliers + loaded.numUndecidedOutliers, 0)
        await session.close()
    }

    // MARK: - FrameInfo.available_modes

    /// A frame nothing has been done to has only its source image; the picker greys out the rest.
    func testFrameInfoListsTheImagesTheFrameHas() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)

        let info = await Mapping.frameInfo(frame: frame, outlierGroups: nil)
        XCTAssertEqual(info.availableModes, [.viewOriginal])
        XCTAssertEqual(info.filename, "frame0.tif", "the grid's frame panel names the file")
        await session.close()
    }

    // MARK: - Aligned views built on demand (Q3)

    /// The default mode never writes a frame's aligned images, so a processed frame has them only as something it can build from its
    /// homographies; the picker offers them as the macOS gui's does (`FrameViewModel.hasImage`), the star one and the earth one apart.
    func testAFrameOffersTheAlignedImagesItCanBuild() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)
        let database = await session.configManager.homographyDatabase

        let before = await Mapping.frameInfo(frame: frame, outlierGroups: nil)
        XCTAssertEqual(before.availableModes, [.viewOriginal], "no homographies, nothing to build from")

        try await database.write(frameIndex: 0, type: .star, results: HomographyResultsCodable(for: 0, with: []))
        let star = await Mapping.frameInfo(frame: frame, outlierGroups: nil)
        XCTAssertEqual(star.availableModes, [.viewOriginal, .viewStarAligned])

        try await database.write(frameIndex: 0, type: .earth, results: HomographyResultsCodable(for: 0, with: []))
        let both = await Mapping.frameInfo(frame: frame, outlierGroups: nil)
        XCTAssertEqual(Set(both.availableModes), [.viewOriginal, .viewStarAligned, .viewEarthAligned])
        await session.close()
    }

    /// A build is asked for only when the image is one of the two the default mode skips, is not there, and the frame can make it:
    /// anything else is the preview's own business, and a frame with nothing to build from has nothing to start.
    func testOnlyAMissingAlignedImageThatCanBeBuiltNeedsBuilding() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)
        let database = await session.configManager.homographyDatabase

        let originalNeeds = await PreviewFiles.alignedImageNeedsBuilding(for: frame, mode: .original)
        XCTAssertFalse(originalNeeds, "the original is a file of its own")
        let withoutHomographies = await PreviewFiles.alignedImageNeedsBuilding(for: frame, mode: .starAligned)
        XCTAssertFalse(withoutHomographies, "nothing to build it from")

        try await database.write(frameIndex: 0, type: .star, results: HomographyResultsCodable(for: 0, with: []))
        let withHomographies = await PreviewFiles.alignedImageNeedsBuilding(for: frame, mode: .starAligned)
        XCTAssertTrue(withHomographies)
        let otherKind = await PreviewFiles.alignedImageNeedsBuilding(for: frame, mode: .earthAligned)
        XCTAssertFalse(otherKind, "only the star homographies are stored")
        let notACache = await PreviewFiles.alignedImageNeedsBuilding(for: frame, mode: .final)
        XCTAssertFalse(notACache)

        // Once the full-size file is there it is not built again.
        let path = try XCTUnwrap(frame.imageAccessor.nameForImage(frameIndex: 0, ofType: .starAligned, atSize: .original))
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data([0]))
        let built = await PreviewFiles.alignedImageNeedsBuilding(for: frame, mode: .starAligned)
        XCTAssertFalse(built)
        await session.close()
    }

    // MARK: - Per-frame settings (E4)

    /// A frame's own clean method is an override in the config, so it is still there when the session is opened again; and the frame's
    /// info says it is the frame's own.
    func testACleanMethodSetForAFrameIsKeptInTheConfig() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)

        let before = await session.frameInfo(frame, outlierGroups: nil)
        XCTAssertFalse(before.cleanMethodOverridden)

        await session.setCleanMethod(.selective, of: frame)

        let config = await session.config()
        XCTAssertEqual(config.pixelReplacementOverrides[0], .selective)
        let after = await session.frameInfo(frame, outlierGroups: nil)
        XCTAssertTrue(after.cleanMethodOverridden)
        // ...and on disk, which is what a reopened session reads
        let path = await session.configJsonPath
        let onDisk = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertEqual(onDisk.pixelReplacementOverrides[0], .selective)
        await session.close()
    }

    func testAStaticNeighbourCountIsSetAndTakenAway() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)
        let global = await session.config().numberStaticNeighborFrames

        let before = await session.frameInfo(frame, outlierGroups: nil)
        XCTAssertEqual(before.staticNeighborCount, Int32(global))
        XCTAssertFalse(before.staticNeighborOverridden)

        let started = await session.setNeighborOverride(of: frame, kind: .static, count: 5)
        XCTAssertFalse(started, "a static count does not start a run")
        let set = await session.frameInfo(frame, outlierGroups: nil)
        XCTAssertEqual(set.staticNeighborCount, 5)
        XCTAssertTrue(set.staticNeighborOverridden)
        let stored = await session.config()
        XCTAssertEqual(stored.staticNeighborFrameOverrides[0], 5)

        _ = await session.setNeighborOverride(of: frame, kind: .static, count: nil)
        let cleared = await session.frameInfo(frame, outlierGroups: nil)
        XCTAssertEqual(cleared.staticNeighborCount, Int32(global))
        XCTAssertFalse(cleared.staticNeighborOverridden)
        await session.close()
    }

    /// A new aligned count throws the frame's alignment away (whether or not it had one: StarCore says it did) and processes the frame
    /// again, as macOS does.
    func testAnAlignedNeighbourCountProcessesTheFrameAgain() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)

        let started = await session.setNeighborOverride(of: frame, kind: .aligned, count: 3)
        XCTAssertTrue(started)
        let info = await session.frameInfo(frame, outlierGroups: nil)
        XCTAssertEqual(info.alignedNeighborCount, 3)
        XCTAssertTrue(info.alignedNeighborOverridden)
        await session.close()
    }

    func testTheOverridesReachTheClientInTheConfig() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)
        await session.setCleanMethod(.automatic(true), of: frame)
        _ = await session.setNeighborOverride(of: frame, kind: .static, count: 7)
        _ = await session.setNeighborOverride(of: frame, kind: .aligned, count: 2)

        let proto = Mapping.protoConfig(await session.config())
        XCTAssertEqual(proto.pixelReplacementOverrides[0], .cleanAutomaticTrue)
        XCTAssertEqual(proto.staticNeighborFrameOverrides[0], 7)
        XCTAssertEqual(proto.alignedNeighborFrameOverrides[0], 2)
        await session.close()
    }

    /// A client that sends back a config it read before the override was set must not undo the override.
    func testUpdatingTheConfigLeavesTheFramesOwnSettingsAlone() async throws {
        let session = try await makeSession()
        try await session.buildFrameGraph()
        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)
        let stale = Mapping.protoConfig(await session.config())   // read before the override

        _ = await session.setNeighborOverride(of: frame, kind: .static, count: 9)
        _ = await session.updateConfig(from: stale)

        let config = await session.config()
        XCTAssertEqual(config.staticNeighborFrameOverrides[0], 9)
        await session.close()
    }
}
