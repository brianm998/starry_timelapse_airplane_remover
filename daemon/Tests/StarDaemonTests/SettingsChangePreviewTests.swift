import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// What a settings change would do to work already on disk, asked before it is applied (the settings sheet's red line, and Process Now turning
/// into Update).  The rules are StarCore's (`ArtifactInputs`, `SettingsChangeState`); this is the session's side of it: what it compares
/// against, and what it counts.
final class SettingsChangePreviewTests: XCTestCase {

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

    /// The config as it stands, as a client would send it back with one setting changed.
    private func proposal(of session: Session, change: (inout Star_V1_Config) -> Void) async -> Star_V1_Config {
        var proto = Mapping.protoConfig(await session.config())
        change(&proto)
        return proto
    }

    func testAChangeThatMovesNoStageIsNotStale() async throws {
        let session = try await makeSession()
        await session.setOpened(untouched: false)
        // Concurrency changes how the work is done, not what comes out of it.
        let concurrency = await proposal(of: session) { $0.numberOfFramesToProcessConcurrently = 3 }

        let preview = await session.previewConfigChange(concurrency)

        XCTAssertTrue(preview.staleStages.isEmpty)
        XCTAssertFalse(preview.contradictsFinishedWork, "nothing it would invalidate, so nothing to warn about, whatever is on disk")
    }

    func testAnOutputSettingIsStaleDownstreamOfWhatItFeeds() async throws {
        let session = try await makeSession()
        await session.setOpened(untouched: true)
        let more = await proposal(of: session) { $0.alignmentMaxKeypoints += 1000 }

        let preview = await session.previewConfigChange(more)

        XCTAssertTrue(preview.staleStages.contains("keypoints"), "\(preview.staleStages)")
        XCTAssertTrue(preview.staleStages.contains("output"), "everything that consumes keypoints is stale too: \(preview.staleStages)")
        XCTAssertFalse(preview.staleStages.contains("horizon"), "upstream of the change is untouched")
    }

    /// The cloud-aware merge changes the star aligned image the alignment stage writes, so turning it on over a sequence that has been
    /// processed says so (alignment and everything after it is stale), and leaves what is upstream of alignment alone.
    func testTurningTheCloudAwareMergeOnIsStaleFromAlignmentOn() async throws {
        let session = try await makeSession()
        await session.setOpened(untouched: false)
        let on = await proposal(of: session) { $0.cloudAwareMerge = true }

        let preview = await session.previewConfigChange(on)

        XCTAssertTrue(preview.staleStages.contains("alignment"), "\(preview.staleStages)")
        XCTAssertTrue(preview.staleStages.contains("output"), "\(preview.staleStages)")
        XCTAssertFalse(preview.staleStages.contains("keypoints"), "upstream of alignment is untouched: \(preview.staleStages)")
        XCTAssertTrue(preview.contradictsFinishedWork)
    }

    /// The ordinary case this whole flow was built for: a sequence nothing has been done to, being set up.  Silent.
    func testStaleOverAnUntouchedSequenceDoesNotContradictAnything() async throws {
        let session = try await makeSession()
        await session.setOpened(untouched: true)
        let more = await proposal(of: session) { $0.alignmentMaxKeypoints += 1000 }
        let preview = await session.previewConfigChange(more)
        XCTAssertFalse(preview.staleStages.isEmpty)
        XCTAssertFalse(preview.contradictsFinishedWork)
    }

    /// A sequence reopened with work on disk, and a change to what that work was built with.
    func testStaleOverAReopenedSequenceWithWorkOnDiskContradictsIt() async throws {
        let session = try await makeSession()
        await session.setOpened(untouched: false)
        let more = await proposal(of: session) { $0.alignmentMaxKeypoints += 1000 }
        let preview = await session.previewConfigChange(more)
        XCTAssertTrue(preview.contradictsFinishedWork)
    }

    /// A change the user made and put off is still a change the frames on disk do not have: the baseline is what the last run began with,
    /// not what was asked a moment ago.
    func testTheBaselineIsNotMovedByApplyingTheChange() async throws {
        let session = try await makeSession()
        await session.setOpened(untouched: false)
        let more = await proposal(of: session) { $0.alignmentMaxKeypoints += 1000 }
        _ = await session.previewConfigChange(more)          // the first question takes the baseline
        _ = await session.updateConfig(from: more)           // the change is applied, and the dialog closed

        let again = await session.previewConfigChange(more)  // asked again, with the config now equal to the proposal

        XCTAssertFalse(again.staleStages.isEmpty, "the frames on disk were built before this change")
        XCTAssertTrue(again.contradictsFinishedWork)
    }

    func testAskingChangesNothing() async throws {
        let session = try await makeSession()
        let before = await session.config().alignmentMaxKeypoints
        let more = await proposal(of: session) { $0.alignmentMaxKeypoints += 1000 }
        _ = await session.previewConfigChange(more)
        let after = await session.config().alignmentMaxKeypoints
        XCTAssertEqual(before, after, "a preview is not an update")
    }

    func testAnUnknownOpenSurveyIsTreatedAsNoWorkBefore() async throws {
        let session = try await makeSession()   // no survey taken: nil
        let more = await proposal(of: session) { $0.alignmentMaxKeypoints += 1000 }
        let preview = await session.previewConfigChange(more)
        XCTAssertFalse(preview.contradictsFinishedWork, "nothing complete, nothing modified, no survey: no finished work to contradict")
    }

    // MARK: - the flag the answer sets

    func testReprocessOnSettingsChangeTravelsBothWays() {
        var proto = Star_V1_Config()
        proto.reprocessOnSettingsChange = false
        var config = Config()
        XCTAssertTrue(config.reprocessOnSettingsChange, "on by default")
        Mapping.applyExpertConfig(&config, from: proto)
        XCTAssertFalse(config.reprocessOnSettingsChange)
        XCTAssertFalse(Mapping.protoConfig(config).reprocessOnSettingsChange)

        var back = Config()
        back.reprocessOnSettingsChange = true
        Mapping.applyExpertConfig(&back, from: Star_V1_Config())
        XCTAssertTrue(back.reprocessOnSettingsChange, "a client that never mentions it leaves it alone")
    }

    func testAConfigMacOSSavedWithTheFlagOffStaysOffAcrossAnUpdate() async throws {
        let session = try await makeSession()
        var off = await proposal(of: session) { $0.reprocessOnSettingsChange = false }
        _ = await session.updateConfig(from: off)
        // An update that does not mention the flag (an older client) must not turn it back on.
        off.clearReprocessOnSettingsChange()
        _ = await session.updateConfig(from: off)
        let kept = await session.config().reprocessOnSettingsChange
        XCTAssertFalse(kept)
    }
}
