import XCTest
import Foundation
@testable import StarCore

/// Re-running a sequence that is mostly already processed used to cost roughly what
/// processing it cost in the first place, because each op established "already done" only
/// by fully reading the artifact it would have written — a keypoint YAML parse, a
/// full-res mask decode plus row scan, and the same again for the merged mask — and paid
/// for that read *inside* the memory gate, since `AsyncOperation` reserves before it
/// executes.
///
/// These tests pin the two halves of the fix: the ops answer `hasWorkToDo()` from a
/// `stat`, and `AsyncOperation` honours that answer before taking a slot or a
/// reservation.
final class ReRunSkipTests: FrameHarnessTestCase {

    // MARK: - the gate in AsyncOperation

    /// The op-under-test: records whether it got as far as reserving or executing.
    private final class SpyOp: AsyncOperation, @unchecked Sendable {
        let workToDo: Bool
        // Plain vars: both hooks run in order on the single task `start()` creates, and
        // the test only reads them once the op has finished.
        var didAcquireSlot = false
        var didExecute = false
        var didReleaseSlot = false

        init(workToDo: Bool, bytes: UInt64) {
            self.workToDo = workToDo
            super.init(for: .starKeypoints, rawImageBytes: bytes, memoryMultiplier: 1)
            self.name = "spy"
        }

        override func hasWorkToDo() async -> Bool { workToDo }
        override func acquireExecutionSlot() async { didAcquireSlot = true }
        override func releaseExecutionSlot() async { didReleaseSlot = true }
        override func asyncExecute() async { didExecute = true }
    }

    private func run(_ op: SpyOp) async {
        let queue = OperationQueue()
        queue.addOperation(op)
        // waitUntilAllOperationsAreFinished blocks the calling thread, which would
        // deadlock an async test; poll the op's own state instead.
        while !op.isFinished { await Task.yield() }
    }

    /// Also, transitively, the test that it reserves nothing: `start()` reserves on the
    /// line after `acquireExecutionSlot()`, with nothing between them, so a spy that never
    /// saw its slot acquired cannot have reached the reservation either.  Asserted this
    /// way round on purpose — reading the ledger would mean reading
    /// `MemoryMonitor.shared`, and these tests deliberately never touch the singleton
    /// other tests are also using.
    func testAnOpWithNothingToDoNeitherGatesNorExecutes() async throws {
        let op = SpyOp(workToDo: false, bytes: 1024 * 1024)
        XCTAssertGreaterThan(op.estimatedMemoryBytes, 0,
                             "an op with a zero estimate never reserves anyway, so it " +
                             "would make this test vacuous")

        await run(op)

        XCTAssertTrue(op.isFinished, "the op still has to finish, or the queue stalls")
        XCTAssertFalse(op.didExecute)
        XCTAssertFalse(op.didAcquireSlot,
                       "taking the keypoint limiter slot is the thing being avoided — a " +
                       "re-run's worth of no-op keypoint ops queueing for slots, each " +
                       "holding a reservation sized for real detection, is what " +
                       "serialised the discovery phase")
        XCTAssertFalse(op.didReleaseSlot,
                       "and nothing may be released that was never acquired")
    }

    func testAnOpWithWorkToDoStillGatesAndExecutes() async throws {
        let op = SpyOp(workToDo: true, bytes: 1024 * 1024)
        await run(op)

        XCTAssertTrue(op.didAcquireSlot)
        XCTAssertTrue(op.didExecute)
        XCTAssertTrue(op.didReleaseSlot)
    }

    /// The default has to stay "there is work", so every op that does not override this
    /// behaves precisely as it did before the gate existed.
    func testHasWorkToDoDefaultsToTrue() async throws {
        final class Plain: AsyncOperation, @unchecked Sendable {
            init() { super.init(for: .merge) }
            override func asyncExecute() async {}
        }
        let plain = Plain()
        let answer = await plain.hasWorkToDo()
        XCTAssertTrue(answer)
    }

    // MARK: - the predicates, against real files on disk

    func testHorizonMaskPredicateFollowsTheFileOnDisk() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "horizon-predicate")
        harness = h

        XCTAssertFalse(h.frame.horizonMaskExistsOnDisk(),
                       "nothing has been detected yet")

        _ = try await h.frame.loadOrCreateHorizonMask()

        XCTAssertTrue(h.frame.horizonMaskExistsOnDisk(),
                      "detection writes the mask, so the predicate must now see it — if " +
                      "this drifts, a re-run silently redoes every horizon")
    }

    /// The harness's synthetic frames yield no SIFT features at any size, so this plants
    /// the artifact rather than detecting it.  What matters is covered either way: the
    /// predicate has to look exactly where `Config.keypointPath` says, which is where
    /// `loadOrCreateOCVFeatures` both reads and writes.
    func testKeypointPredicateFollowsTheFileOnDisk() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "keypoint-predicate")
        harness = h
        let config = await h.configManager.config()

        XCTAssertFalse(h.frame.keypointsExistOnDisk(ofType: .starAligned, config: config))

        let path = try XCTUnwrap(config.keypointPath(frameIndex: 0, ofType: .starAligned))
        try Data("planted".utf8).write(to: URL(fileURLWithPath: path))

        XCTAssertTrue(h.frame.keypointsExistOnDisk(ofType: .starAligned, config: config),
                      "the predicate and the feature-file writer have to agree on that " +
                      "exact path, suffix included")
        XCTAssertFalse(h.frame.keypointsExistOnDisk(ofType: .earthAligned, config: config),
                       "and the two alignment types must not be confused for each other")
    }

    /// The predicate and the loader must resolve the same string, including the
    /// detection-scale suffix.  They are separate call sites, so nothing but a test
    /// stops one gaining a suffix the other does not: the failure mode is a re-run that
    /// skips detection and then cannot find what it skipped for.
    func testKeypointPathAgreesWithTheFilenameAndDirectory() {
        var config = Config()
        config.tempOutputPath = "/tmp/star-test"

        for type in [FrameViewMode.starAligned, .earthAligned] {
            let filename = config.keypointFilename(frameIndex: 7, ofType: type)
            let path = config.keypointPath(frameIndex: 7, ofType: type)
            XCTAssertNotNil(filename)
            XCTAssertEqual(path, "\(config.dirForKeypointData)/\(filename!)")
        }
    }

    func testKeypointPathIsNilForAModeThatHasNoFeatureFile() {
        let config = Config()
        XCTAssertNil(config.keypointPath(frameIndex: 0, ofType: .original))
    }

    /// A nil path means "no cache to consult", which must read as work to do rather than
    /// as already-done — otherwise a mode with no feature file would never detect.
    func testAKeypointOpWithNoPathHasWorkToDo() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "kp-nil-path")
        harness = h

        let op = KeypointOp(forStars: true,
                            frame: h.frame,
                            mode: .starAligned,
                            limiter: KeypointLimiter(max: 1),
                            keypointPath: nil) { _ in }
        let answer = await op.hasWorkToDo()
        XCTAssertTrue(answer)
    }

    func testAKeypointOpSkipsOnlyOnceItsFileExists() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "kp-op")
        harness = h
        let config = await h.configManager.config()
        let path = config.keypointPath(frameIndex: 0, ofType: .starAligned)
        XCTAssertNotNil(path)

        let op = KeypointOp(forStars: true,
                            frame: h.frame,
                            mode: .starAligned,
                            limiter: KeypointLimiter(max: 1),
                            keypointPath: path) { _ in }

        var answer = await op.hasWorkToDo()
        XCTAssertTrue(answer, "no file yet")

        try Data("planted".utf8).write(to: URL(fileURLWithPath: path!))

        answer = await op.hasWorkToDo()
        XCTAssertFalse(answer, "the feature set is on disk now")
    }

    // MARK: - the horizon detection op's accumulator exception

    /// Skipping a detection op whose mask is on disk is right only when nothing needs the
    /// mask in memory.  On the static path a `HorizonAccumulator` folds each mask in as
    /// its op completes, and whatever is left over is loaded by
    /// `ia_accumulate_from_files` — a serial loop of decodes inside one op.  Running them
    /// as parallel ops instead is the whole point of the accumulator, so an op that feeds
    /// one must never skip.
    func testADetectionOpFeedingTheAccumulatorNeverSkips() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "hz-accumulator")
        harness = h
        _ = try await h.frame.loadOrCreateHorizonMask()
        XCTAssertTrue(h.frame.horizonMaskExistsOnDisk(), "precondition: mask is on disk")

        let feeding = HorizonDetectionOp(frame: h.frame,
                                        feedsAccumulator: true) { _ in }
        let notFeeding = HorizonDetectionOp(frame: h.frame,
                                            feedsAccumulator: false) { _ in }

        let feedingAnswer = await feeding.hasWorkToDo()
        let notFeedingAnswer = await notFeeding.hasWorkToDo()

        XCTAssertTrue(feedingAnswer,
                      "the decode is the work when it is feeding an accumulator")
        XCTAssertFalse(notFeedingAnswer,
                       "and pure waste when it is not")
    }

    // MARK: - the merge op

    func testAMergeOpSkipsOnlyOnceTheFrameIsComplete() async throws {
        let h = try await FrameHarness.make(frameCount: 1, named: "merge-op")
        harness = h

        let op = MergeOp(frame: h.frame) { _ in }

        var answer = await op.hasWorkToDo()
        XCTAssertTrue(answer, "an unprocessed frame has a merge to do")

        await h.frame.set(state: .complete)

        answer = await op.hasWorkToDo()
        XCTAssertFalse(answer)
    }

    // MARK: - the retained mask

    /// `cachedFinalHorizonMask` is normally released by the `.complete` transition in
    /// `set(state:)`.  A frame that was *already* complete when the sequence loaded never
    /// makes that transition again, so on a re-run nothing released it: every mask an op
    /// loaded stayed resident for the life of the process — 24MB per frame at 6000×4000,
    /// ~31GB across a long sequence, none of it known to the MemoryMonitor ledger.  Once
    /// footprint crosses the budget the reality brake holds every reservation and the
    /// queue falls back to one forced admission per minute.
    func testAMergeOpOnAnAlreadyCompleteFrameLeavesNoCachedMask() async throws {
        let h = try await FrameHarness.make(frameCount: 3, named: "cached-mask")
        harness = h
        let frame = h.frames[1]

        // stand in for "was already complete when the sequence loaded": the state is set
        // from the final image existing at init, long before any op runs
        await frame.set(state: .complete)

        let op = HorizonMergeOp(frame: frame) { _ in }
        await op.asyncExecute()

        let cached = await frame.cachedFinalHorizonMaskForTesting()
        XCTAssertNil(cached,
                     "the op has to drop what it cached, since no later .complete " +
                     "transition will come along to do it")
    }

    func testAMergeOpOnAnIncompleteFrameKeepsTheCachedMask() async throws {
        let h = try await FrameHarness.make(frameCount: 3, named: "cached-mask-kept")
        harness = h
        let frame = h.frames[1]

        let op = HorizonMergeOp(frame: frame) { _ in }
        await op.asyncExecute()

        let cached = await frame.cachedFinalHorizonMaskForTesting()
        XCTAssertNotNil(cached,
                        "a frame still being processed wants the cache — the release is " +
                        "specifically for frames nothing will revisit")
    }
}
