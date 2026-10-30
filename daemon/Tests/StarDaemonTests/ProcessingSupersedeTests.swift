import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// L8 and L11 of the parity plan: what a start during a run does, and which runs reset the settings baseline.
final class ProcessingSupersedeTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ProcessingSupersedeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    private func makeSession(frames: Int = 4) async throws -> Session {
        let dir = scratch.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = 8, height = 8
        for n in 0..<frames {
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

    /// A start while a run is going stops it and starts this one: the stop and the start each take a generation, whether or not the first run
    /// had already finished on its own (so this does not depend on how quickly four tiny frames go through). Before, the start returned at
    /// once while a run was going and the generation stayed where it was (or moved by one, if that run had finished).
    func testAStartDuringARunSupersedesIt() async throws {
        let session = try await makeSession()
        await ProcessingHandlers.begin(session, startIndex: 0, endIndex: nil, force: false)
        let first = await session.runNumber

        await ProcessingHandlers.begin(session, startIndex: 1, endIndex: nil, force: false)
        let second = await session.runNumber
        XCTAssertEqual(second - first, 2, "the old run was stopped (+1) and this one started (+1)")
        await session.close()
    }

    /// The baseline "what changed since the last run" is compared against is taken by a run of the whole sequence, as the gui's Process All
    /// does, and not by a run of some of the frames.
    func testOnlyARunOfTheWholeSequenceResetsTheSettingsBaseline() async throws {
        let session = try await makeSession(frames: 4)
        func threshold() async -> Double? { await session.settingsSnapshot?.pixelThreshold }
        func change(to value: Double) async {
            var config = await session.config()
            config.pixelThreshold = value
            await session.configManager.update(config)
        }

        await change(to: 1.5)
        await ProcessingHandlers.begin(session, startIndex: 0, endIndex: nil, force: false)
        var seen = await threshold()
        XCTAssertEqual(seen, 1.5, "a run of the whole sequence takes the settings as they are")

        await change(to: 2.5)
        await ProcessingHandlers.begin(session, startIndex: 1, endIndex: nil, force: false)
        seen = await threshold()
        XCTAssertEqual(seen, 1.5, "from frame 1 to the end is not the whole sequence")
        await ProcessingHandlers.begin(session, startIndex: 0, endIndex: 1, force: false)
        seen = await threshold()
        XCTAssertEqual(seen, 1.5, "nor is the first two frames")
        await ProcessingHandlers.begin(session, startIndex: 2, endIndex: 2, force: false)
        seen = await threshold()
        XCTAssertEqual(seen, 1.5, "nor is one frame")

        await ProcessingHandlers.begin(session, startIndex: 0, endIndex: nil, force: false)
        seen = await threshold()
        XCTAssertEqual(seen, 2.5, "the next run of the whole sequence is the baseline again")
        await ProcessingHandlers.begin(session, startIndex: 0, endIndex: 3, force: false)
        await change(to: 3.5)
        await ProcessingHandlers.begin(session, startIndex: 0, endIndex: 99, force: false)
        seen = await threshold()
        XCTAssertEqual(seen, 3.5, "an end past the last frame is still the whole sequence")
        await session.close()
    }
}
