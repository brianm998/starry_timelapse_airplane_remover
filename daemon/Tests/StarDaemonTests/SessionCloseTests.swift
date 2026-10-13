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
        let configManager = await MainActor.run {
            ConfigManager(configFilename: "\(sessionDir)/config.json", config: Config())
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
}
