import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// Issue #7: after an edit with the selective tools the finished image is rewritten by the save queue some seconds later, and a client
/// showing that frame has to be told, or it keeps the old picture.  `ImageAccessor` announces only preview-size writes, which exist only
/// when `writeFramePreviewFiles` is on (the default is off), so the session announces the final image itself when a save ends.
final class FinalImageSavedEventTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SettingsChangePreviewTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeSession() async throws -> Session {
        let dir = scratch.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = 8, height = 8
        for n in 0..<3 {
            let data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height * 3)
            for i in 0..<(width * height * 3) { data[i] = UInt8((i * 7 + n) % 256) }
            let mat = MatWrapper(width: width, height: height,
                                 cvType: MatWrapper.cvType(forBitsPerComponent: 8, componentsPerPixel: 3),
                                 bytesPerRow: width * 3,
                                 data: UnsafeMutableRawPointer(data),
                                 takeOwnership: true)
            mat.write(to: dir.appendingPathComponent("frame\(n).tif").path)
        }
        let sequence = try ImageSequence(dirname: dir.path, supportedImageFileTypes: [".tif", ".tiff"])
        let info = try await sequence.getImageInfo()
        let sessionDir = scratch.appendingPathComponent("session").path
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)
        var config = Config()
        config.outputPath = scratch.appendingPathComponent("output").path
        config.tempOutputPath = scratch.appendingPathComponent("temp").path
        config.imageSequencePath = scratch.path
        config.imageSequenceDirname = "seq"
        let finalConfig = config
        let configManager = await MainActor.run {
            ConfigManager(configFilename: "\(sessionDir)/config.json", config: finalConfig)
        }
        let session = Session(sessionID: "s", scratchSessionDir: sessionDir,
                              configJsonPath: "\(sessionDir)/config.json",
                              configManager: configManager, imageSequence: sequence, imageInfo: info)
        try await session.buildFrameGraph()
        return session
    }

    private func finalImageEvents(from session: Session, whileRunning body: () async -> Void) async -> [Star_V1_ImageSaved] {
        let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
        let token = await session.addProgressSubscriber(cont)
        await body()
        // Callbacks hop through unstructured tasks; give them time to land before closing the stream.
        try? await Task.sleep(nanoseconds: 500_000_000)
        await session.removeProgressSubscriber(token)
        cont.finish()
        var found: [Star_V1_ImageSaved] = []
        for await ev in stream {
            if case .imageSaved(let saved) = ev.kind, saved.viewMode == .viewProcessed { found.append(saved) }
        }
        return found
    }

    func testAFinishedSaveAnnouncesTheFinalImageEvenWithoutPreviews() async throws {
        let session = try await makeSession()
        let writesPreviews = await session.config().writeFramePreviewFiles
        XCTAssertFalse(writesPreviews, "the default is what makes this matter: no preview write, so no announcement from ImageAccessor")
        let found = await session.frame(at: 1)
        let frame = try XCTUnwrap(found)

        let events = await finalImageEvents(from: session) {
            await frame.set(frameSavingState: .saving)
            await frame.set(frameSavingState: .notSaving)
        }

        XCTAssertEqual(events.map { Int($0.frameIndex) }, [1], "a finished save must announce that frame's final image")
    }

    func testAStateChangeThatIsNotTheEndOfASaveAnnouncesNothing() async throws {
        let session = try await makeSession()
        let found = await session.frame(at: 0)
        let frame = try XCTUnwrap(found)

        let events = await finalImageEvents(from: session) {
            await frame.set(frameSavingState: .inPurgatory)
            await frame.set(frameSavingState: .savePending)
            await frame.set(frameSavingState: .saving)
        }

        XCTAssertTrue(events.isEmpty, "nothing has been written until the save ends: \(events)")
    }

    // MARK: - A frame's own clean method (parity plan L10)

    private func plant(_ frame: FrameAirplaneRemover, _ type: FrameViewMode) throws -> String {
        let path = try XCTUnwrap(frame.imageAccessor.nameForImage(frameIndex: frame.frameIndex, ofType: type, atSize: .original))
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data([1, 2, 3]))
        return path
    }

    private func inode(_ path: String) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try XCTUnwrap(attributes[.systemFileNumber] as? UInt64)
    }

    /// The daemon's frames have no `FrameObserver`, and StarCore linked the new final only for a frame that had one: the method was
    /// recorded and the old picture stayed until the frame's save timer fired, with the frame "user modified" meanwhile.  Now the new
    /// method's image is the final at once, the client is told, and the frame is not marked as changed.
    func testANewCleanMethodLinksItsImageAndTellsTheClient() async throws {
        let session = try await makeSession()
        let found = await session.frame(at: 1)
        let frame = try XCTUnwrap(found)
        let selective = try plant(frame, .selectiveProcessed)
        await frame.set(state: .complete)

        let events = await finalImageEvents(from: session) {
            await session.setCleanMethod(.selective, of: frame)
        }

        let final = try XCTUnwrap(frame.imageAccessor.nameForImage(frameIndex: 1, ofType: .final, atSize: .original))
        XCTAssertEqual(try inode(final), try inode(selective), "the final is the selective image")
        XCTAssertEqual(events.map { Int($0.frameIndex) }, [1])
        let state = await frame.processingState()
        XCTAssertEqual(state, .complete, "a method change is not an edit that needs the frame rendered again")
        let saving = await frame.savingState()
        XCTAssertEqual(saving, .notSaving, "nothing was queued for the save timer")
        let config = await session.config()
        XCTAssertEqual(config.pixelReplacementOverrides[1], .selective)
        await session.close()
    }

    /// A frame no step has reached has nothing to link; the method is only recorded, and the run that gets to the frame reads it.
    func testAFrameNoRunHasReachedOnlyRecordsItsNewCleanMethod() async throws {
        let session = try await makeSession()
        let found = await session.frame(at: 2)
        let frame = try XCTUnwrap(found)
        let state = await frame.processingState()
        XCTAssertEqual(state, .unprocessed)

        let events = await finalImageEvents(from: session) {
            await session.setCleanMethod(.selective, of: frame)
        }

        let final = try XCTUnwrap(frame.imageAccessor.nameForImage(frameIndex: 2, ofType: .final, atSize: .original))
        XCTAssertFalse(FileManager.default.fileExists(atPath: final))
        XCTAssertTrue(events.isEmpty)
        let after = await frame.processingState()
        XCTAssertEqual(after, .unprocessed)
        let config = await session.config()
        XCTAssertEqual(config.pixelReplacementOverrides[2], .selective)
        await session.close()
    }
}
