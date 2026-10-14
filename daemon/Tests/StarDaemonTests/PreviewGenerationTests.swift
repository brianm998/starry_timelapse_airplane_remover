import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// Previews and thumbnails are made through the frame graph's memory-gated preview queue, once however many ask, and a background pre-warm
/// makes the ones a client is about to ask for.
final class PreviewGenerationTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("PreviewGenerationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A session over `count` frames of 64x48, with previews configured smaller than that so there is something to scale down to.
    private func makeSession(frames count: Int) async throws -> Session {
        let dir = scratch.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = 64, height = 48
        for n in 0..<count {
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
        config.previewWidth = 32
        config.previewHeight = 24
        config.thumbnailWidth = 16
        config.thumbnailHeight = 12
        config.set(imageInfo: info)
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

    /// Every preview operation the frame graph has seen, in any state: what moves when one is made through the queue.
    private func previewOperations() async -> UInt {
        await MainActor.run {
            (frameGraphViewModel.operations[.preview] ?? [:]).values.reduce(0, +)
        }
    }

    private func frame(_ index: Int, of session: Session) async throws -> FrameAirplaneRemover {
        let found = await session.frame(at: index)
        return try XCTUnwrap(found)
    }

    private func frames(of session: Session) async -> [FrameAirplaneRemover] {
        await session.frames
    }

    func testAnOnDemandPreviewIsMadeThroughThePreviewQueue() async throws {
        let session = try await makeSession(frames: 2)
        let frame = try await frame(0, of: session)
        let before = await previewOperations()

        let ref = await PreviewFiles.ref(for: frame, mode: .original)

        let made = try XCTUnwrap(ref)
        XCTAssertTrue(FileManager.default.fileExists(atPath: made.path), "the preview is on disk")
        let after = await previewOperations()
        XCTAssertEqual(after, before + 1, "made by an operation on the queue, not inline")
    }

    func testAThumbnailIsMadeThroughTheQueueToo() async throws {
        let session = try await makeSession(frames: 1)
        let frame = try await frame(0, of: session)
        let ref = await PreviewFiles.ref(for: frame, mode: .original, size: .thumbnail)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(ref).path))
    }

    /// A grid scrolled quickly asks for the same image from several places; it is made once.
    func testSeveralRequestsForOneImageMakeItOnce() async throws {
        let session = try await makeSession(frames: 1)
        let frame = try await frame(0, of: session)
        let unit = await frame.configManager.config().workingFrameBytes
        let before = await previewOperations()

        let results = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 {
                group.addTask {
                    await PreviewGeneration.shared.make(imageAccessor: frame.imageAccessor, frameIndex: 0, mode: .original, size: .preview,
                                                        workingFrameBytes: unit, urgency: .now)
                }
            }
            return await group.reduce(into: [Bool]()) { $0.append($1) }
        }

        XCTAssertEqual(results, [Bool](repeating: true, count: 6))
        let after = await previewOperations()
        XCTAssertEqual(after, before + 1, "one operation served all six callers")
    }

    /// What lets the memory gate gate: an op with no size reserves nothing.
    func testAPreviewOperationReservesTheFullSizeFrameItLoads() async throws {
        let session = try await makeSession(frames: 1)
        let frame = try await frame(0, of: session)
        let unit = await frame.configManager.config().workingFrameBytes
        XCTAssertGreaterThan(unit, 0)
        let op = PreviewGenerationOp(imageAccessor: frame.imageAccessor, frameIndex: 0, mode: .original, size: .preview,
                                     workingFrameBytes: unit) { _ in }
        XCTAssertEqual(op.estimatedMemoryBytes, unit * 2, "the preview multiplier on the working frame")
        op.cancel()
        op.start()   // never ran: finishing it is what reports the cancel
    }

    /// An image with nothing to make it from is reported as not made rather than waited on.
    func testAnImageWithoutASourceIsNotMade() async throws {
        let session = try await makeSession(frames: 1)
        let frame = try await frame(0, of: session)
        let unit = await frame.configManager.config().workingFrameBytes
        let made = await PreviewGeneration.shared.make(imageAccessor: frame.imageAccessor, frameIndex: 0, mode: .final, size: .preview,
                                                       workingFrameBytes: unit, urgency: .now)
        XCTAssertFalse(made, "a frame that has not been processed has no final image to scale")
    }

    func testACancelledRequestReturnsInsteadOfHanging() async throws {
        let session = try await makeSession(frames: 1)
        let frame = try await frame(0, of: session)
        let unit = await frame.configManager.config().workingFrameBytes
        let task = Task {
            await PreviewGeneration.shared.make(imageAccessor: frame.imageAccessor, frameIndex: 0, mode: .original, size: .preview,
                                                workingFrameBytes: unit, urgency: .background)
        }
        task.cancel()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { _ = await task.value; return true }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        XCTAssertTrue(finished, "a cancelled request must finish")
    }

    // MARK: - the pre-warm

    func testThePrewarmListsThumbnailsBeforePreviews() async throws {
        let session = try await makeSession(frames: 3)
        let jobs = PreviewPrewarm.jobs(for: await frames(of: session))

        XCTAssertEqual(jobs.count, 6, "a thumbnail and a preview of each frame's original; nothing else has an original yet")
        let sizes = jobs.map { "\($0.size)" }
        XCTAssertEqual(sizes, ["thumbnail", "thumbnail", "thumbnail", "preview", "preview", "preview"])
        XCTAssertEqual(jobs.prefix(3).map(\.frameIndex), [0, 1, 2])
    }

    func testThePrewarmMakesWhatIsMissingAndThenHasNothingLeftToMake() async throws {
        let session = try await makeSession(frames: 3)
        let all = await frames(of: session)

        await PreviewPrewarm.run(frames: all)

        for frame in all {
            XCTAssertNotNil(frame.imageAccessor.urlForImage(frameIndex: frame.frameIndex, ofType: .original, atSize: .thumbnail))
            XCTAssertNotNil(frame.imageAccessor.urlForImage(frameIndex: frame.frameIndex, ofType: .original, atSize: .preview))
        }
        XCTAssertTrue(PreviewPrewarm.jobs(for: all).isEmpty)
    }

    func testAnImageThatIsAlreadyThereIsNotQueuedAgain() async throws {
        let session = try await makeSession(frames: 2)
        let frame = try await frame(0, of: session)
        _ = await PreviewFiles.ref(for: frame, mode: .original)

        let jobs = PreviewPrewarm.jobs(for: await frames(of: session))
        XCTAssertFalse(jobs.contains { $0.frameIndex == 0 && "\($0.size)" == "preview" })
        XCTAssertTrue(jobs.contains { $0.frameIndex == 1 && "\($0.size)" == "preview" })
    }

    func testClosingASessionStopsItsPrewarm() async throws {
        let session = try await makeSession(frames: 4)
        await session.startPreviewPrewarm()
        await session.close()
        // Not a hang, and a second start after close does nothing.
        await session.startPreviewPrewarm()
    }
}
