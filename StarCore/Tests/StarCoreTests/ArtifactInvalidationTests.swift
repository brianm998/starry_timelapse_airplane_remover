import XCTest
import Foundation
@testable import StarCore

/// `ArtifactInputs` decides *which* stages a settings change made stale;
/// `FrameGraphBuilder.invalidateStaleArtifacts` is what acts on that, and the two halves
/// can disagree silently.  A stage that records a setting and deletes nothing when it moves
/// leaves the setting doing nothing on an already-processed sequence — the original bug,
/// one level further down.  A stage that deletes more than it owns throws away the
/// expensive half of a run for a setting that could not have affected it.
///
/// So these plant real artifacts on real frames and check what survives.  Files, not
/// reasoning: everything here is a `stat`, and what the pipeline reuses is exactly what a
/// `stat` finds.
final class ArtifactInvalidationTests: FrameHarnessTestCase {

    private func makeHarness() async throws -> FrameHarness {
        let harness = try await FrameHarness.make(frameCount: 3, named: "invalidation")
        self.harness = harness
        return harness
    }

    /// Every stage's artifact, on every frame, so that whatever is deleted can be told from
    /// whatever was never there.
    private func plantEveryArtifact(in harness: FrameHarness) async throws {
        let config = harness.config
        for frame in harness.frames {
            let index = frame.frameIndex
            let image = try await harness.imageSequence.getImage(withName:
                          await harness.imageSequence.filenames[index]).image()

            for type in [FrameViewMode.horizon, .mergedHorizon, .starAligned,
                         .earthAligned, .subtraction, .final]
            {
                try await harness.imageAccessor.save(image,
                                                     frameIndex: index,
                                                     as: type,
                                                     atSize: .original,
                                                     overwrite: true)
            }

            for type in [FrameViewMode.starAligned, .earthAligned] {
                guard let path = config.keypointPath(frameIndex: index, ofType: type)
                else { continue }
                StarCore.mkdir((path as NSString).deletingLastPathComponent)
                try Data("keypoints".utf8).write(to: URL(fileURLWithPath: path))
            }

            let outlierDir = "\(config.outlierOutputDirname)/\(index)"
            StarCore.mkdir(outlierDir)
            try Data("outliers".utf8).write(
              to: URL(fileURLWithPath:
                        "\(outlierDir)/\(BlobBinarySaver.outlierBinaryFilename)"))
        }
    }

    /// What is still on disk, per stage, over the whole harness.
    private func present(in harness: FrameHarness) -> [ArtifactStage: Int] {
        let config = harness.config
        var out: [ArtifactStage: Int] = [:]
        for frame in harness.frames {
            if frame.horizonMaskExistsOnDisk() { out[.horizon, default: 0] += 1 }
            if frame.mergedHorizonMaskExistsOnDisk() { out[.mergedHorizon, default: 0] += 1 }
            if frame.keypointsExistOnDisk(ofType: .starAligned, config: config) {
                out[.keypoints, default: 0] += 1
            }
            if harness.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                                 ofType: .starAligned,
                                                 atSize: .original)
            {
                out[.alignment, default: 0] += 1
            }
            if frame.outliersExistOnDisk(config: config) { out[.outliers, default: 0] += 1 }
            if frame.outputFileExistsOnDisk() { out[.output, default: 0] += 1 }
        }
        return out
    }

    private func wholeSequence(_ harness: FrameHarness) -> (FrameGraphRange, [Int: FrameAirplaneRemover]) {
        let indices = harness.frames.map(\.frameIndex)
        let range = FrameGraphRange(sequenceIndices: indices,
                                    startIndex: 0,
                                    endIndex: nil,
                                    alignmentNeighbours: [:],
                                    horizonMergeNeighbours: [:])
        var byIndex: [Int: FrameAirplaneRemover] = [:]
        for frame in harness.frames { byIndex[frame.frameIndex] = frame }
        return (range, byIndex)
    }

    /// Record `stored` as what the artifacts were built with, then run the invalidation
    /// under `now`.  What the pipeline does at the start of every run.
    private func invalidate(
      _ harness: FrameHarness,
      builtWith stored: Config,
      nowUsing now: Config
    ) async throws {
        try ArtifactInputs.current(from: stored)
          .save(toTempOutputPath: stored.tempOutputPath)

        let (range, byIndex) = wholeSequence(harness)
        await frameGraphBuilder.invalidateStaleArtifacts(
          frames: harness.frames,
          range: range,
          framesByIndex: byIndex,
          config: now
        )
    }

    // MARK: - each stage takes only what it owns

    /// A setting read while the finished frame is painted, and nowhere earlier.  The
    /// alignment is the expensive half of a run and has to survive it.
    func testAPaintSettingRedoesTheMergeAndKeepsEverythingThatFedIt() async throws {
        let harness = try await makeHarness()
        try await plantEveryArtifact(in: harness)
        XCTAssertEqual(present(in: harness)[.output], 3, "the harness planted nothing")

        var changed = harness.config
        changed.outlierGroupPaintBorderPixels += 17

        try await invalidate(harness, builtWith: harness.config, nowUsing: changed)

        let left = present(in: harness)
        XCTAssertNil(left[.output], "the output is painted with this and must be redone")
        XCTAssertEqual(left[.alignment], 3, "nothing upstream of the paint can have changed")
        XCTAssertEqual(left[.outliers], 3)
        XCTAssertEqual(left[.keypoints], 3)
        XCTAssertEqual(left[.horizon], 3)
        XCTAssertEqual(left[.mergedHorizon], 3)
    }

    /// Read while outliers are classified, after the frames are aligned.
    func testAnOutlierSettingRedoesTheOutliersAndTheOutputOnly() async throws {
        let harness = try await makeHarness()
        var before = harness.config
        before.cleanMethod = .selective
        await harness.updateConfig { $0.cleanMethod = .selective }
        try await plantEveryArtifact(in: harness)

        var changed = before
        changed.ignoreLowerPixels = 250

        try await invalidate(harness, builtWith: before, nowUsing: changed)

        let left = present(in: harness)
        XCTAssertNil(left[.outliers])
        XCTAssertNil(left[.output], "the removal is painted from the outlier groups")
        XCTAssertEqual(left[.alignment], 3,
                       "re-aligning for an outlier setting would throw away the expensive " +
                       "half of the run for nothing")
        XCTAssertEqual(left[.keypoints], 3)
    }

    /// Read while the homographies are fitted.  Everything after it was built from them.
    func testAnAlignmentSettingRedoesTheAlignmentAndEverythingAfterIt() async throws {
        let harness = try await makeHarness()
        try await plantEveryArtifact(in: harness)

        var changed = harness.config
        changed.homographySmoothingEpsilon += 0.5

        try await invalidate(harness, builtWith: harness.config, nowUsing: changed)

        let left = present(in: harness)
        XCTAssertNil(left[.alignment])
        XCTAssertNil(left[.outliers])
        XCTAssertNil(left[.output])
        XCTAssertEqual(left[.keypoints], 3, "the keypoints were not fitted, they were detected")
        XCTAssertEqual(left[.horizon], 3)
    }

    /// The motivating case, now with the whole chain behind it.
    func testAKeypointSettingRedoesEverythingFromDetectionOnwards() async throws {
        let harness = try await makeHarness()
        try await plantEveryArtifact(in: harness)

        var changed = harness.config
        changed.alignmentMaxKeypoints += 1000

        try await invalidate(harness, builtWith: harness.config, nowUsing: changed)

        let left = present(in: harness)
        XCTAssertNil(left[.keypoints])
        XCTAssertNil(left[.alignment])
        XCTAssertNil(left[.outliers])
        XCTAssertNil(left[.output])
        XCTAssertEqual(left[.horizon], 3, "detection is masked with the horizon, not the " +
                                          "other way round")
        XCTAssertEqual(left[.mergedHorizon], 3)
    }

    // MARK: - settings that change nothing on disk

    /// The other failure mode, and the worse one: this must never delete anything.
    func testAConcurrencyChangeDeletesNothing() async throws {
        let harness = try await makeHarness()
        try await plantEveryArtifact(in: harness)

        var changed = harness.config
        changed.numberOfFramesToProcessConcurrently = 2
        changed.keypointMemoryMultiplier += 5
        changed.alignmentWriteDebugImages = !changed.alignmentWriteDebugImages

        try await invalidate(harness, builtWith: harness.config, nowUsing: changed)

        XCTAssertEqual(present(in: harness),
                       [.horizon: 3, .mergedHorizon: 3, .keypoints: 3,
                        .alignment: 3, .outliers: 3, .output: 3])
    }

    // MARK: - the answer to the confirmation

    /// "No": keep what is already written, and let the new settings apply to the frames
    /// that are left.  Nothing is deleted, and the record is written all the same so the
    /// question is not asked again at the start of every subsequent run.
    func testKeepingTheOldOutputDeletesNothingAndStillRecordsTheNewSettings() async throws {
        let harness = try await makeHarness()
        try await plantEveryArtifact(in: harness)

        var changed = harness.config
        changed.alignmentMaxKeypoints += 1000
        changed.reprocessOnSettingsChange = false

        try await invalidate(harness, builtWith: harness.config, nowUsing: changed)

        XCTAssertEqual(present(in: harness),
                       [.horizon: 3, .mergedHorizon: 3, .keypoints: 3,
                        .alignment: 3, .outliers: 3, .output: 3])

        let recorded = ArtifactInputs.load(fromTempOutputPath: harness.config.tempOutputPath)
        XCTAssertEqual(recorded?.staleStages(comparedTo: ArtifactInputs.current(from: changed)),
                       [],
                       "the run adopted the new settings, so the next one has nothing " +
                       "left to ask about")
    }

    /// And the same change with the default answer, so the test above is not passing
    /// because the change was never detected in the first place.
    func testTheSameChangeWithTheDefaultAnswerDoesDelete() async throws {
        let harness = try await makeHarness()
        try await plantEveryArtifact(in: harness)

        var changed = harness.config
        changed.alignmentMaxKeypoints += 1000
        XCTAssertTrue(changed.reprocessOnSettingsChange, "the default is to rebuild")

        try await invalidate(harness, builtWith: harness.config, nowUsing: changed)

        XCTAssertNil(present(in: harness)[.keypoints])
    }

    // MARK: - no record at all

    /// Every sequence anyone already has temp files for.  Treating "I cannot tell" as
    /// "everything is stale" would make upgrading star reprocess all of them.
    func testASequenceWithNoRecordKeepsEverythingAndAdoptsTheCurrentSettings() async throws {
        let harness = try await makeHarness()
        try await plantEveryArtifact(in: harness)

        var changed = harness.config
        changed.alignmentMaxKeypoints += 1000

        let (range, byIndex) = wholeSequence(harness)
        await frameGraphBuilder.invalidateStaleArtifacts(
          frames: harness.frames,
          range: range,
          framesByIndex: byIndex,
          config: changed
        )

        XCTAssertEqual(present(in: harness)[.keypoints], 3)
        XCTAssertNotNil(ArtifactInputs.load(fromTempOutputPath: harness.config.tempOutputPath),
                        "the run should have recorded what it ran with")
    }
}

/// `FrameOutlierProcessor.deleteOutliers()` used to go through `outlierGroups?`, so it
/// deleted nothing at all for a frame whose outliers had never been loaded into memory —
/// and the next run then loaded the stale binary it left behind.
///
/// Reached by every path that means "redo the outliers": the right panel's Redo picker, and
/// the invalidation an outlier-detection settings change triggers.  Both of those act on
/// frames the user has not necessarily looked at, which is exactly the case that did
/// nothing.
final class DeleteOutliersTests: FrameHarnessTestCase {

    func testOutliersAreDeletedForAFrameWhoseGroupsWereNeverLoaded() async throws {
        let harness = try await FrameHarness.make(frameCount: 1, named: "delete-outliers")
        self.harness = harness

        let frame = harness.frame
        let dir = "\(harness.config.outlierOutputDirname)/\(frame.frameIndex)"
        StarCore.mkdir(dir)
        try Data("outliers".utf8).write(
          to: URL(fileURLWithPath: "\(dir)/\(BlobBinarySaver.outlierBinaryFilename)"))
        XCTAssertTrue(frame.outliersExistOnDisk(config: harness.config),
                      "the test planted nothing")

        try await frame.deleteOutliers()

        XCTAssertFalse(frame.outliersExistOnDisk(config: harness.config))
    }

    /// And the trash beside them, which is stored in the same directory and is just as
    /// stale once the groups it came from are gone.
    func testTheTrashGoesWithThem() async throws {
        let harness = try await FrameHarness.make(frameCount: 1, named: "delete-trash")
        self.harness = harness

        let frame = harness.frame
        let dir = "\(harness.config.outlierOutputDirname)/\(frame.frameIndex)"
        StarCore.mkdir(dir)
        let trash = "\(dir)/\(BlobBinarySaver.trashBinaryFilename)"
        try Data("trash".utf8).write(to: URL(fileURLWithPath: trash))

        try await frame.deleteOutliers()

        XCTAssertFalse(FileManager.default.fileExists(atPath: trash))
    }

    /// Deleting what is not there is not an error: the invalidation runs over every frame
    /// in range, most of which have nothing.
    func testDeletingNothingSucceeds() async throws {
        let harness = try await FrameHarness.make(frameCount: 1, named: "delete-nothing")
        self.harness = harness
        try await harness.frame.deleteOutliers()
    }
}
