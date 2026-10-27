import XCTest
import StarCore
import StarDaemonMessages
@testable import stard

/// A session opened on a video whose frames are still being extracted: it opens once the first frame is out, tells its progress
/// subscribers which frames are there, moves the extractor when asked, and stops it when it closes.
final class BackgroundExtractionSessionTests: XCTestCase {

    private var scratch: URL!
    private var previousOverride: String?

    private var shippedToolsDirectory: URL {
        URL(fileURLWithPath: #filePath)
          .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
          .appendingPathComponent("external_binaries").appendingPathComponent("bin")
    }

    override func setUpWithError() throws {
        let directory = shippedToolsDirectory
        for tool in ["ffmpeg", "ffprobe"] {
            try XCTSkipUnless(FileManager.default.fileExists(atPath: directory.appendingPathComponent(tool).path),
                              "ffmpeg is not built here; run ffmpeg/build.sh --install")
        }
        previousOverride = ProcessInfo.processInfo.environment[ToolPaths.directoryOverrideVariable]
        setenv(ToolPaths.directoryOverrideVariable, directory.path, 1)
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("BackgroundExtraction-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let previousOverride { setenv(ToolPaths.directoryOverrideVariable, previousOverride, 1) }
        else { unsetenv(ToolPaths.directoryOverrideVariable) }
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A ProRes video, which any frame can be had from on its own: long enough that its frames are still arriving when the session is up.
    private func makeProRes(frames: Int = 900) throws -> String {
        let folder = scratch.appendingPathComponent("video")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let path = folder.appendingPathComponent("clip.mov").path
        let process = Process()
        process.executableURL = shippedToolsDirectory.appendingPathComponent("ffmpeg")
        process.arguments = [
          "-hide_banner", "-nostdin", "-loglevel", "error", "-y", "-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=24",
          "-frames:v", "\(frames)", "-c:v", "prores_ks", "-profile:v", "0", "-pix_fmt", "yuv422p10le", path]
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return path
    }

    private func open(_ path: String, background: Bool = true) async throws -> Session {
        let sessionDir = scratch.appendingPathComponent("session").path
        return try await Session.openVideo(
          sessionID: "s", scratchSessionDir: sessionDir, videoPath: path, protoConfig: Star_V1_Config(),
          extractInBackground: background)
    }

    private func waitUntil(_ timeout: TimeInterval = 60, _ condition: () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testTheSessionIsOpenWhileFramesAreStillBeingExtracted() async throws {
        let session = try await open(try makeProRes())
        defer { Task { await session.close() } }
        let source = try XCTUnwrap(session.extractionSource, "the frames were all there already")
        XCTAssertEqual(source.frameCount, 900)
        let count = await session.frameCount
        XCTAssertEqual(count, 900)
        XCTAssertTrue(source.isAvailable(0))

        let config = await session.configManager.config()
        let info = Mapping.sessionInfo(session: session, config: config, imageInfo: await session.imageInfo, frameCount: 900)
        XCTAssertEqual(info.frameCount, 900)
        XCTAssertTrue(info.extraction.active)
        XCTAssertTrue(info.extraction.seekable)
        XCTAssertEqual(info.extraction.total, 900)
        XCTAssertFalse(info.extraction.available.isEmpty, "the snapshot lists what is there")
    }

    func testASubscriberIsSeededWithAFullSnapshotThenGetsDeltas() async throws {
        let session = try await open(try makeProRes())
        defer { Task { await session.close() } }
        await session.didOpen()
        let (stream, continuation) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
        _ = await session.addProgressSubscriber(continuation)
        await session.seedFrameStates(to: continuation)

        var first: Star_V1_FrameExtraction?
        var sawAvailable = false
        let deadline = Date().addingTimeInterval(30)
        for await event in stream {
            switch event.kind {
            case .frameExtraction(let extraction)? where first == nil: first = extraction
            case .framesAvailable? : sawAvailable = true
            default: break
            }
            if first != nil && sawAvailable { break }
            if Date() > deadline { break }
        }
        XCTAssertNotNil(first, "the first thing a subscriber learns is how far the extraction has got")
        XCTAssertTrue(first?.active ?? false)
        XCTAssertFalse(first?.available.isEmpty ?? true)
        XCTAssertTrue(sawAvailable, "frames that arrive afterwards are announced")
    }

    func testPrioritizingMovesTheExtractorAndAPendingFrameIsMarkedNotExtracted() async throws {
        let session = try await open(try makeProRes())
        defer { Task { await session.close() } }
        let source = try XCTUnwrap(session.extractionSource)

        let late = 880
        let pending = await session.frame(at: late)
        let frame = try XCTUnwrap(pending)
        let before = await Mapping.frameInfo(frame: frame, outlierGroups: nil)
        XCTAssertTrue(before.notExtracted)
        let eta = await session.frameEta(late)
        XCTAssertFalse(eta.available)

        await session.prioritizeFrames(viewing: late, nearby: Array((late - 4)..<late))
        let arrived = await waitUntil { source.isAvailable(late) }
        XCTAssertTrue(arrived)
        XCTAssertLessThan(source.progress.extracted, 850, "the frame came from a jump, not from the sweep reaching it")
        let after = await Mapping.frameInfo(frame: frame, outlierGroups: nil)
        XCTAssertFalse(after.notExtracted)
        let done = await session.frameEta(late)
        XCTAssertTrue(done.available)
    }

    func testClosingStopsTheExtractionAndKeepsWhatIsThere() async throws {
        let session = try await open(try makeProRes())
        let source = try XCTUnwrap(session.extractionSource)
        let folder = (source as? VideoFrameSource)?.outputFolder
        await session.close()
        try await Task.sleep(nanoseconds: 500_000_000)
        let extracted = source.progress.extracted
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(source.progress.extracted, extracted, "nothing is extracted after the session is closed")
        let sidecar = FrameExtractionSidecar.read(inFolder: try XCTUnwrap(folder))
        if !source.progress.isComplete { XCTAssertEqual(sidecar?.complete, false, "a reopen carries on") }
    }

    func testWithoutTheFlagTheOpenWaitsForEveryFrame() async throws {
        let session = try await open(try makeProRes(frames: 48), background: false)
        defer { Task { await session.close() } }
        XCTAssertNil(session.extractionSource)
        let count = await session.frameCount
        XCTAssertEqual(count, 48)
    }
}
