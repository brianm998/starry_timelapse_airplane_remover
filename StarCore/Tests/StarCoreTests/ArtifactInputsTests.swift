import XCTest
import Foundation
@testable import StarCore

/// The skip predicates that let a re-run reuse cached artifacts ask only whether the file
/// exists, which meant a settings change had no effect on an already-processed sequence.
/// `ArtifactInputs` is what closes that: it records what each stage was built with so a
/// later run can tell.
///
/// Two ways for this to be wrong, and both are worse than the bug it fixes. Recording too
/// little means a changed setting still silently does nothing. Recording too much means a
/// harmless setting throws away hours of alignment — so the tests below pin the specific
/// settings that must and must not invalidate, not just the mechanism.
final class ArtifactInputsTests: XCTestCase {

    private func config() -> Config {
        var c = Config()
        c.tempOutputPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("ArtifactInputs-\(UUID().uuidString)").path
        return c
    }

    private func tearDownPath(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: - the dependency chain

    /// Each stage consumes the one before it, so a change never invalidates only itself.
    func testStagesAreDeclaredInDependencyOrder() {
        XCTAssertEqual(ArtifactStage.allCases, [.horizon, .mergedHorizon, .keypoints],
                       "andDownstream slices allCases, so the declaration order IS the " +
                       "dependency order — reordering these silently breaks the cascade")
    }

    func testDownstreamOfAStageIncludesItselfAndEverythingAfter() {
        XCTAssertEqual(ArtifactStage.horizon.andDownstream,
                       [.horizon, .mergedHorizon, .keypoints])
        XCTAssertEqual(ArtifactStage.mergedHorizon.andDownstream,
                       [.mergedHorizon, .keypoints])
        XCTAssertEqual(ArtifactStage.keypoints.andDownstream, [.keypoints])
    }

    /// The merged horizon masks keypoint detection, so a horizon-detection change reaches
    /// the keypoints even though no keypoint setting moved.
    func testAHorizonChangeInvalidatesEverythingDownstream() {
        var before = config()
        before.useCombinedHorizonDetection = true
        var after = before
        after.useCombinedHorizonDetection = false

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: before))

        XCTAssertEqual(stale, [.horizon, .mergedHorizon, .keypoints])
    }

    func testAKeypointChangeInvalidatesOnlyKeypoints() {
        var before = config()
        before.alignmentMaxKeypoints = 2000
        var after = before
        after.alignmentMaxKeypoints = 3000

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: before))

        XCTAssertEqual(stale, [.keypoints],
                       "nothing recorded here feeds back into the horizon masks")
    }

    // MARK: - settings that must invalidate

    /// The motivating case. Raising the keypoint cap used to leave every frame with its
    /// old feature file, so the setting did nothing on an already-processed sequence.
    func testEverySettingFedToFindFeaturesInvalidatesTheKeypoints() {
        let base = config()
        let mutations: [(String, (inout Config) -> Void)] = [
            ("alignmentMaxKeypoints",            { $0.alignmentMaxKeypoints = 4000 }),
            ("alignmentGroundHorizonExtension",  { $0.alignmentGroundHorizonExtension = 250 }),
            ("alignmentSkyHorizonExtension",     { $0.alignmentSkyHorizonExtension = 0 }),
            ("alignmentBaseImageDilateSize",     { $0.alignmentBaseImageDilateSize = 33 }),
            ("alignmentBaseImageThresholdValue", { $0.alignmentBaseImageThresholdValue = 55 }),
            ("alignmentKeypointDetectionDivisor", { $0.alignmentKeypointDetectionDivisor = 2.0 }),
            ("horizonDetectionEnabled",          { $0.horizonDetectionEnabled = false }),
        ]
        for (name, mutate) in mutations {
            var after = base
            mutate(&after)
            let stale = ArtifactInputs.current(from: after)
                .staleStages(comparedTo: ArtifactInputs.current(from: base))
            XCTAssertTrue(stale.contains(.keypoints),
                          "changing \(name) must invalidate the keypoints — it is passed " +
                          "to ImageAligner.findFeatures, so the cached features were " +
                          "detected with a different value")
        }
    }

    func testSettingsFedToTheMergeInvalidateTheMergedHorizon() {
        var base = config()
        base.tripodHeadWasMoving = true
        let mutations: [(String, (inout Config) -> Void)] = [
            ("pixelThreshold",               { $0.pixelThreshold = 2.5 }),
            ("numberAlignedNeighborFrames",  { $0.numberAlignedNeighborFrames = 12 }),
            ("numberStaticNeighborFrames",   { $0.numberStaticNeighborFrames = 20 }),
            ("alignedNeighborFrameOverrides", { $0.alignedNeighborFrameOverrides = [3: 4] }),
            ("staticNeighborFrameOverrides", { $0.staticNeighborFrameOverrides = [3: 4] }),
            ("useReferenceHorizonSmoothing", { $0.useReferenceHorizonSmoothing = false }),
            ("referenceHorizonNeighborhoodSize", { $0.referenceHorizonNeighborhoodSize = 9 }),
        ]
        for (name, mutate) in mutations {
            var after = base
            mutate(&after)
            let stale = ArtifactInputs.current(from: after)
                .staleStages(comparedTo: ArtifactInputs.current(from: base))
            XCTAssertTrue(stale.contains(.mergedHorizon),
                          "changing \(name) must invalidate the merged horizon")
            XCTAssertTrue(stale.contains(.keypoints),
                          "and the keypoints with it, since the merged mask is what " +
                          "detection is masked with")
        }
    }

    // MARK: - settings that must NOT invalidate

    /// Invalidating on these would discard good artifacts — and, through the keypoint
    /// cascade, hours of alignment — for a setting that cannot change what was produced.
    func testPerformanceAndDebugSettingsInvalidateNothing() {
        let base = config()
        let mutations: [(String, (inout Config) -> Void)] = [
            ("alignmentWriteDebugImages",  { $0.alignmentWriteDebugImages = true }),
            ("mergeStreamingThresholdMB",  { $0.mergeStreamingThresholdMB = 512 }),
            ("numberOfFramesToProcessConcurrently", { $0.numberOfFramesToProcessConcurrently = 4 }),
            ("maxConcurrentKeypointOps",   { $0.maxConcurrentKeypointOps = 2 }),
            ("keypointCacheMaxMB",         { $0.keypointCacheMaxMB = 64 }),
            ("maxMatMemoryFraction",       { $0.maxMatMemoryFraction = 0.5 }),
            ("keypointMemoryMultiplier",   { $0.keypointMemoryMultiplier = 12 }),
            ("writeFramePreviewFiles",     { $0.writeFramePreviewFiles = false }),
        ]
        for (name, mutate) in mutations {
            var after = base
            mutate(&after)
            let stale = ArtifactInputs.current(from: after)
                .staleStages(comparedTo: ArtifactInputs.current(from: base))
            XCTAssertTrue(stale.isEmpty,
                          "changing \(name) must not invalidate anything — it changes how " +
                          "the work is done or what it costs, not what comes out, and " +
                          "invalidating would throw away good artifacts (got \(stale))")
        }
    }

    /// The horizon inputs branch on the detection mode, so a setting the current mode
    /// never reads cannot invalidate. Without that, tuning a legacy parameter would
    /// rebuild every mask in combined mode, where nothing reads it.
    func testLegacySearchSettingsDoNotInvalidateInCombinedMode() {
        var base = config()
        base.useCombinedHorizonDetection = true
        var after = base
        after.cannyMinThreshold = 99
        after.horizonSearchCropCount1 = 3
        after.horizonSearchSize = [256, 256]

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: base))
        XCTAssertTrue(stale.isEmpty,
                      "CombinedHorizonDetector.detect reads no config at all, so none of " +
                      "these can have affected the masks on disk (got \(stale))")
    }

    func testTheSameLegacySettingsDoInvalidateWhenTheLegacyPathIsActive() {
        var base = config()
        base.useCombinedHorizonDetection = false
        var after = base
        after.cannyMinThreshold = 99

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: base))
        XCTAssertTrue(stale.contains(.horizon))
    }

    /// The reference-horizon passes are moving-sequence only.
    func testReferenceHorizonSettingsDoNotInvalidateAStaticSequence() {
        var base = config()
        base.tripodHeadWasMoving = false
        var after = base
        after.referenceHorizonBrightnessRefinementSearchRadius = 250
        after.horizonSpikeMaxWidth = 99

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: base))
        XCTAssertTrue(stale.isEmpty, "got \(stale)")
    }

    // MARK: - what a missing or foreign record means

    /// Every sequence anyone already has temp files for is in this state. Treating "I
    /// cannot tell" as "everything is stale" would make upgrading star reprocess all of
    /// them, which is far worse than continuing to behave as it does today.
    func testNoStoredRecordInvalidatesNothing() {
        let stale = ArtifactInputs.current(from: config()).staleStages(comparedTo: nil)
        XCTAssertTrue(stale.isEmpty)
    }

    func testARecordFromADifferentVersionInvalidatesNothing() {
        let c = config()
        let current = ArtifactInputs.current(from: c)
        var changed = c
        changed.alignmentMaxKeypoints = 9999
        let foreign = ArtifactInputs(version: ArtifactInputs.currentVersion + 1,
                                     stages: ArtifactInputs.current(from: changed).stages)

        XCTAssertTrue(current.staleStages(comparedTo: foreign).isEmpty,
                      "a format difference is not evidence of a settings change")
    }

    /// A stage absent from an older record is not evidence of a change either.
    func testAStageMissingFromTheStoredRecordInvalidatesNothing() {
        let c = config()
        let current = ArtifactInputs.current(from: c)
        let partial = ArtifactInputs(stages: [
            ArtifactStage.horizon.rawValue: current.stages[ArtifactStage.horizon.rawValue]!
        ])
        XCTAssertTrue(current.staleStages(comparedTo: partial).isEmpty)
    }

    func testAnUnchangedConfigInvalidatesNothing() {
        let c = config()
        let a = ArtifactInputs.current(from: c)
        let b = ArtifactInputs.current(from: c)
        XCTAssertEqual(a, b)
        XCTAssertTrue(a.staleStages(comparedTo: b).isEmpty)
    }

    // MARK: - reporting

    /// A run about to discard alignment should be able to say which setting caused it,
    /// which is the whole reason this records values rather than a hash.
    func testDifferencesNameTheSettingAndBothValues() {
        var before = config()
        before.alignmentMaxKeypoints = 2000
        var after = before
        after.alignmentMaxKeypoints = 3000

        let differences = ArtifactInputs.current(from: after)
            .differences(from: ArtifactInputs.current(from: before))

        XCTAssertEqual(differences[.keypoints], ["alignmentMaxKeypoints 2000 -> 3000"])
    }

    /// Because the input sets branch on mode, flipping one mode flag brings a dozen
    /// settings into the record at once — and the flag is the only one of them that
    /// explains anything. It has to be reported before the passengers, since the caller
    /// truncates the list.
    func testTheSettingThatMovedIsReportedBeforeTheOnesThatMerelyAppeared() {
        var before = config()
        before.useCombinedHorizonDetection = true
        var after = before
        after.useCombinedHorizonDetection = false

        let changes = try? XCTUnwrap(ArtifactInputs.current(from: after)
                                       .differences(from: ArtifactInputs.current(from: before))[.horizon])
        let changes2 = changes ?? []

        XCTAssertGreaterThan(changes2.count, 1,
                             "precondition: leaving combined mode brings the legacy " +
                             "search settings into the record")
        XCTAssertEqual(changes2.first, "useCombinedHorizonDetection true -> false",
                       "the mode flag is the cause and must lead; everything after it " +
                       "only appeared because of it (got \(changes2))")
        for change in changes2.dropFirst() {
            XCTAssertTrue(change.contains("<unset> ->"),
                          "only newly-recorded settings should follow the cause: \(change)")
        }
    }

    // MARK: - persistence

    func testARecordRoundTripsThroughDisk() throws {
        let c = config()
        defer { tearDownPath(c.tempOutputPath) }

        let written = ArtifactInputs.current(from: c)
        try written.save(toTempOutputPath: c.tempOutputPath)

        let read = try XCTUnwrap(ArtifactInputs.load(fromTempOutputPath: c.tempOutputPath))
        XCTAssertEqual(read, written)
        XCTAssertTrue(written.staleStages(comparedTo: read).isEmpty)
    }

    func testSavingCreatesTheTempDirectoryIfItIsNotThereYet() throws {
        let c = config()
        defer { tearDownPath(c.tempOutputPath) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.tempOutputPath))

        try ArtifactInputs.current(from: c).save(toTempOutputPath: c.tempOutputPath)

        XCTAssertTrue(FileManager.default.fileExists(
                        atPath: ArtifactInputs.filename(inTempOutputPath: c.tempOutputPath)))
    }

    func testLoadingReturnsNilRatherThanThrowingOnGarbage() throws {
        let c = config()
        defer { tearDownPath(c.tempOutputPath) }
        StarCore.mkdir(c.tempOutputPath)
        try Data("not json".utf8).write(
          to: URL(fileURLWithPath: ArtifactInputs.filename(inTempOutputPath: c.tempOutputPath)))

        XCTAssertNil(ArtifactInputs.load(fromTempOutputPath: c.tempOutputPath),
                     "an unreadable record means the same as an absent one; failing the " +
                     "run over it would be worse than not invalidating")
    }

    func testLoadingReturnsNilWhenThereIsNoFile() {
        XCTAssertNil(ArtifactInputs.load(fromTempOutputPath: config().tempOutputPath))
    }

    /// Saving twice must replace rather than append or fail.
    func testSavingOverAnExistingRecordReplacesIt() throws {
        let c = config()
        defer { tearDownPath(c.tempOutputPath) }
        try ArtifactInputs.current(from: c).save(toTempOutputPath: c.tempOutputPath)

        var changed = c
        changed.alignmentMaxKeypoints = 4321
        let second = ArtifactInputs.current(from: changed)
        try second.save(toTempOutputPath: c.tempOutputPath)

        XCTAssertEqual(ArtifactInputs.load(fromTempOutputPath: c.tempOutputPath), second)
    }

    // MARK: - value formatting

    /// Values are compared as strings, so a Double that arrives via different arithmetic
    /// must not record two ways. This is the pattern `quantizedKeypointDivisor` exists to
    /// avoid in the keypoint filename, for the same reason.
    func testADoubleThatArrivesByDifferentArithmeticRecordsIdentically() {
        var a = config()
        a.pixelThreshold = 1.2
        var b = a
        b.pixelThreshold = 0.4 + 0.8   // 1.2000000000000002 in binary floating point

        XCTAssertNotEqual(0.4 + 0.8, 1.2, "precondition: these really do differ as Doubles")
        XCTAssertTrue(ArtifactInputs.current(from: b)
                        .staleStages(comparedTo: ArtifactInputs.current(from: a)).isEmpty,
                      "recording at %.10g means float representation noise cannot look " +
                      "like a settings change and rebuild the whole sequence")
    }

    /// Dictionaries have no order, so the recorded form has to impose one.
    func testOverrideMapsRecordTheSameWhateverTheInsertionOrder() {
        var a = config()
        a.staticNeighborFrameOverrides = [:]
        a.staticNeighborFrameOverrides[7] = 2
        a.staticNeighborFrameOverrides[1] = 4
        var b = config()
        b.tempOutputPath = a.tempOutputPath
        b.staticNeighborFrameOverrides = [:]
        b.staticNeighborFrameOverrides[1] = 4
        b.staticNeighborFrameOverrides[7] = 2

        XCTAssertEqual(ArtifactInputs.current(from: a), ArtifactInputs.current(from: b))
    }

    /// Every recorded value must be a real reading of the config, not a default that
    /// happens to match. A stage recording nothing would silently never invalidate.
    func testEveryStageRecordsAtLeastOneSetting() {
        let inputs = ArtifactInputs.current(from: config())
        for stage in ArtifactStage.allCases {
            let recorded = inputs.stages[stage.rawValue]
            XCTAssertNotNil(recorded, "\(stage) records nothing at all")
            XCTAssertFalse(recorded?.isEmpty ?? true, "\(stage) records an empty set")
        }
    }
}
