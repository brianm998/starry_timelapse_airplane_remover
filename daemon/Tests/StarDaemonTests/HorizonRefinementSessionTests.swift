import XCTest
import StarCore
import StarCppBridge
import StarDaemonMessages
@testable import stard

/// What a session does when a reference horizon is repainted: the frames that interpolate from it become pending, the
/// user is told what a re-run would touch, and "later" and "now" act on that record.  The rules themselves are
/// StarCore's `HorizonRefinementPlan` (tested there); this is the session's side of it: reading what is on disk, the
/// marks the client draws, and the cases where there is nothing to ask.
final class HorizonRefinementSessionTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("HorizonRefinementSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }

    /// A session over `frames` tiny frames, with the frame graph built.
    private func makeSession(frames count: Int) async throws -> Session {
        let dir = scratch.appendingPathComponent("seq")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let width = 8, height = 8
        for n in 0..<count {
            // Three channels, like a camera's frames: a horizon mask is made against the image, which has to load.
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
        // A moving camera: its references are per-frame.  A static one has a single reference that every
        // frame uses, so every frame counts as a reference and nothing interpolates.
        config.tripodHeadWasMoving = true
        // Where the originals are: the accessor finds the source frames from these two.
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

    /// Paint a reference horizon on `index`, the way `Horizon.SetReference` does.
    private func paintReference(_ session: Session, at index: Int) async throws {
        let first = await session.frame(at: index)
        let frame = try XCTUnwrap(first)
        try await frame.saveHorizonReferenceMask(paintedYPerColumn: [Int?](repeating: 4, count: 8), viewWidth: 8, viewHeight: 8)
    }

    func testARepaintMarksTheFramesThatInterpolateFromIt() async throws {
        let session = try await makeSession(frames: 5)
        try await paintReference(session, at: 2)

        let counts = await session.horizonReferenceUpdated(frameIndex: 2, applyToNearby: true)

        // The only reference: every other frame interpolates from it, and none has output to render again.
        XCTAssertEqual(counts, .init(frameCount: 4, renderCount: 0))
        for index in [0, 1, 3, 4] {
            let pending = await session.isRefinementPending(index)
            XCTAssertTrue(pending, "frame \(index) is not marked pending")
        }
        let referencePending = await session.isRefinementPending(2)
        XCTAssertFalse(referencePending, "a reference serves its own mask: it has nothing to refine")
        await session.close()
    }

    /// With "apply to nearby frames" off, nothing is recorded and nothing is asked.
    func testNothingIsRecordedWhenNearbyFramesAreNotToBeTouched() async throws {
        let session = try await makeSession(frames: 5)
        try await paintReference(session, at: 2)

        let counts = await session.horizonReferenceUpdated(frameIndex: 2, applyToNearby: false)

        XCTAssertNil(counts)
        for index in 0..<5 {
            let pending = await session.isRefinementPending(index)
            XCTAssertFalse(pending, "frame \(index) was marked")
        }
        await session.close()
    }

    /// A reference painted right beside another, in a sequence with no output: there is no span and nothing to
    /// render again, so there is nothing to ask.
    func testWithNothingToRedoNothingIsAsked() async throws {
        let session = try await makeSession(frames: 2)
        try await paintReference(session, at: 0)
        try await paintReference(session, at: 1)
        let counts = await session.horizonReferenceUpdated(frameIndex: 1, applyToNearby: true)
        XCTAssertNil(counts)
        let started = await session.runHorizonRefinement()
        XCTAssertFalse(started, "a run started with nothing in it")
        await session.close()
    }

    /// "Later" keeps the work pending: the marks stay.
    func testLaterKeepsTheMarks() async throws {
        let session = try await makeSession(frames: 5)
        try await paintReference(session, at: 2)
        _ = await session.horizonReferenceUpdated(frameIndex: 2, applyToNearby: true)

        await session.deferHorizonRefinement()

        let pending = await session.isRefinementPending(0)
        XCTAssertTrue(pending)
        await session.close()
    }

    /// The pending flag reaches the client on a frame's info.
    func testTheFlagIsOnTheFramesInfo() async throws {
        let session = try await makeSession(frames: 3)
        try await paintReference(session, at: 1)
        _ = await session.horizonReferenceUpdated(frameIndex: 1, applyToNearby: true)

        let first = await session.frame(at: 0)
        let frame = try XCTUnwrap(first)
        let info = await session.frameInfo(frame, outlierGroups: nil)
        XCTAssertTrue(info.refinementPending)
        let secondFrame = await session.frame(at: 1)
        let refInfo = await session.frameInfo(try XCTUnwrap(secondFrame), outlierGroups: nil)
        XCTAssertFalse(refInfo.refinementPending)
        await session.close()
    }

    /// What enables the "Re-run" button.
    func testTheStatusSaysWhetherAnythingIsWaiting() async throws {
        let session = try await makeSession(frames: 5)
        let before = await session.horizonRefinementStatus()
        XCTAssertFalse(before.pending)
        XCTAssertEqual(before.markedFrames, 0)

        try await paintReference(session, at: 2)
        _ = await session.horizonReferenceUpdated(frameIndex: 2, applyToNearby: true)

        let after = await session.horizonRefinementStatus()
        XCTAssertTrue(after.pending)
        XCTAssertEqual(after.markedFrames, 4)
        await session.close()
    }

    /// P10: a refinement run says "Clearing the renders…" while it prepares, and the line goes once its operations are queued, as the gui's
    /// does; it used to stay for the whole run, so the bars never showed what was happening.
    func testThePreparingLineGoesOnceTheRunIsQueued() async throws {
        let session = try await makeSession(frames: 2)
        await session.beginStepReports(generation: 7, types: [.mergedHorizon], status: "Clearing the renders")
        var status = await session.stepReportStatus
        XCTAssertEqual(status, "Clearing the renders")

        await session.stepsQueued(generation: 6)      // another run's
        status = await session.stepReportStatus
        XCTAssertEqual(status, "Clearing the renders", "a run that is not this one must not clear it")

        await session.stepsQueued(generation: 7)
        status = await session.stepReportStatus
        XCTAssertNil(status)
        await session.close()
    }
}
