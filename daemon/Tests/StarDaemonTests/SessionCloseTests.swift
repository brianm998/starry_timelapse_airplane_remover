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
}
