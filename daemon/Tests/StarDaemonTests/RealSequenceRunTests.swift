import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// Runs the daemon's whole pipeline over a few frames of a REAL sequence, which no other daemon test can (they use 8x8 frames that stop before
/// the horizon).  Off unless `STAR_REAL_SEQUENCE_DIR` names a folder of full-size frames (`image_0001.tiff`, ...), plus, optionally,
/// `STAR_REAL_SEQUENCE_CONFIG`, the `config.json` of a run of it, whose settings (scene, camera motion, detection) are used with the paths and
/// the clean method replaced.  The frames are linked, not copied, and the work goes into a scratch folder beside the sequence (the volume the
/// owner keeps the footage on has the room), removed afterwards.  A run of six 42 MP frames takes a few minutes.
final class RealSequenceRunTests: XCTestCase {

    private var scratch: URL!

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func environment() throws -> (dir: String, config: String?) {
        guard let dir = ProcessInfo.processInfo.environment["STAR_REAL_SEQUENCE_DIR"], !dir.isEmpty,
              FileManager.default.fileExists(atPath: dir)
        else { throw XCTSkip("STAR_REAL_SEQUENCE_DIR is not set to a folder of frames") }
        let config = ProcessInfo.processInfo.environment["STAR_REAL_SEQUENCE_CONFIG"].flatMap { $0.isEmpty ? nil : $0 }
        return (dir, config)
    }

    /// A session over `count` consecutive frames of the sequence starting at `first` (1-based, as the file names are).
    private func makeSession(from dir: String, configPath: String?, first: Int, count: Int, cleanMethod: CleanMethod) async throws -> Session {
        let parent = URL(fileURLWithPath: dir).deletingLastPathComponent()
        scratch = parent.appendingPathComponent("star-test-\(UUID().uuidString)")
        let seq = scratch.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: seq, withIntermediateDirectories: true)
        for n in first..<(first + count) {
            let name = String(format: "image_%04d.tiff", n)
            try FileManager.default.createSymbolicLink(atPath: seq.appendingPathComponent(name).path, withDestinationPath: "\(dir)/\(name)")
        }
        let sequence = try ImageSequence(dirname: seq.path, supportedImageFileTypes: [".tif", ".tiff"])
        let info = try await sequence.getImageInfo()
        let sessionDir = scratch.appendingPathComponent("session").path
        try FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

        var config = Config()
        if let configPath {
            config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: configPath)))
        }
        config.outputPath = scratch.appendingPathComponent("output").path
        config.tempOutputPath = scratch.appendingPathComponent("temp").path
        config.imageSequencePath = scratch.path
        config.imageSequenceDirname = "seq"
        config.cleanMethod = cleanMethod
        config.writeFramePreviewFiles = false
        config.set(imageInfo: info)
        let finalConfig = config
        let configManager = await MainActor.run {
            ConfigManager(configFilename: "\(sessionDir)/config.json", config: finalConfig)
        }
        let session = Session(sessionID: "real", scratchSessionDir: sessionDir,
                              configJsonPath: "\(sessionDir)/config.json",
                              configManager: configManager, imageSequence: sequence, imageInfo: info)
        try await session.buildFrameGraph()
        return session
    }

    /// Run to the end and say how each frame ended: its state, and which of the images the clean methods make are on disk.
    private func runAndReport(_ session: Session, count: Int, label: String) async throws -> [(state: FrameProcessingState, final: Bool, auto: Bool, autoSelective: Bool, selective: Bool)] {
        let (stream, cont) = AsyncStream<Star_V1_ProgressEvent>.makeStream()
        let token = await session.addProgressSubscriber(cont)
        await ProcessingHandlers.begin(session, startIndex: 0, endIndex: nil, force: false)
        var ended: String?
        let deadline = Date().addingTimeInterval(25 * 60)
        loop: for await event in stream {
            if case .sequenceState(let s) = event.kind, ["done", "error", "cancelled"].contains(s.state) {
                ended = s.state
                break loop
            }
            if Date() > deadline { break loop }
        }
        await session.removeProgressSubscriber(token)
        cont.finish()
        XCTAssertEqual(ended, "done", "\(label): the run did not end cleanly")

        var out: [(FrameProcessingState, Bool, Bool, Bool, Bool)] = []
        for i in 0..<count {
            let found = await session.frame(at: i)
            let frame = try XCTUnwrap(found)
            func has(_ type: FrameViewMode) -> Bool { frame.imageAccessor.imageExists(frameIndex: i, ofType: type, atSize: .original) }
            let state = await frame.processingState()
            out.append((state, has(.final), has(.autoProcessed), has(.autoSelectiveProcessed), has(.selectiveProcessed)))
            print("REAL-RUN \(label) frame \(i): state=\(state) final=\(has(.final)) auto=\(has(.autoProcessed)) autoSelective=\(has(.autoSelectiveProcessed)) selective=\(has(.selectiveProcessed))")
        }
        return out
    }

    /// L5: where does an auto selective run leave its frames?
    func testAnAutoSelectiveRunEndsEveryFrameComplete() async throws {
        let env = try environment()
        let count = 6
        let session = try await makeSession(from: env.dir, configPath: env.config, first: 600, count: count, cleanMethod: .automatic(true))
        let ends = try await runAndReport(session, count: count, label: "auto selective")
        await session.close()
        for (i, end) in ends.enumerated() {
            XCTAssertEqual(end.state, .complete, "frame \(i)")
            XCTAssertTrue(end.final, "frame \(i) has its final")
            XCTAssertTrue(end.autoSelective, "frame \(i) has the auto selective image")
        }
    }
}
