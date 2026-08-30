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

    /// A record as some earlier star wrote it, with one keypoint input edited or dropped.
    /// The only way to stand in for "written by a different build", since `current` can
    /// only ever report this build's constant.
    private func record(_ inputs: ArtifactInputs,
                        withKeypointInput key: String,
                        setTo value: String?) -> ArtifactInputs {
        var stages = inputs.stages
        var keypoints = stages[ArtifactStage.keypoints.rawValue] ?? [:]
        keypoints[key] = value
        stages[ArtifactStage.keypoints.rawValue] = keypoints
        return ArtifactInputs(version: inputs.version, stages: stages)
    }

    // MARK: - the dependency chain

    /// Each stage consumes the one before it, so a change never invalidates only itself.
    func testStagesAreDeclaredInDependencyOrder() {
        XCTAssertEqual(ArtifactStage.allCases,
                       [.horizon, .mergedHorizon, .keypoints,
                        .alignment, .outliers, .output],
                       "andDownstream slices allCases, so the declaration order IS the " +
                       "dependency order — reordering these silently breaks the cascade")
    }

    func testDownstreamOfAStageIncludesItselfAndEverythingAfter() {
        XCTAssertEqual(ArtifactStage.horizon.andDownstream,
                       [.horizon, .mergedHorizon, .keypoints,
                        .alignment, .outliers, .output])
        XCTAssertEqual(ArtifactStage.mergedHorizon.andDownstream,
                       [.mergedHorizon, .keypoints, .alignment, .outliers, .output])
        XCTAssertEqual(ArtifactStage.keypoints.andDownstream,
                       [.keypoints, .alignment, .outliers, .output])
        XCTAssertEqual(ArtifactStage.alignment.andDownstream,
                       [.alignment, .outliers, .output])
        XCTAssertEqual(ArtifactStage.outliers.andDownstream, [.outliers, .output])
        XCTAssertEqual(ArtifactStage.output.andDownstream, [.output])
    }

    /// Every stage says what it owns on disk.  That half of the mapping is what
    /// `FrameGraphBuilder.invalidateStaleArtifacts` has to keep deleting: a stage that
    /// records a setting and removes nothing when it moves is the original bug, one level
    /// further down the pipeline.
    func testEveryStageDescribesWhatItLeavesOnDisk() {
        for stage in ArtifactStage.allCases {
            XCTAssertFalse(stage.artifactDescription.isEmpty, "\(stage)")
            XCTAssertFalse(stage.logDescription.isEmpty, "\(stage)")
        }
    }

    /// A record with a setting in it that nothing deletes is a setting that still silently
    /// does nothing on an already-processed sequence.
    func testEveryStageRecordsSomeSettings() {
        let inputs = ArtifactInputs.current(from: config())
        for stage in ArtifactStage.allCases {
            XCTAssertFalse(inputs.stages[stage.rawValue]?.isEmpty ?? true,
                           "\(stage) records no settings at all")
        }
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

        XCTAssertEqual(stale, [.horizon, .mergedHorizon, .keypoints,
                               .alignment, .outliers, .output])
    }

    func testAKeypointChangeInvalidatesTheKeypointsAndWhatConsumesThem() {
        var before = config()
        before.alignmentMaxKeypoints = 2000
        var after = before
        after.alignmentMaxKeypoints = 3000

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: before))

        XCTAssertEqual(stale, [.keypoints, .alignment, .outliers, .output],
                       "nothing recorded here feeds back into the horizon masks, but " +
                       "everything after the keypoints was built from them")
    }

    // MARK: - the code that produces the keypoints

    /// Settings are enough for a stage whose behaviour lives in settings.  Keypoint
    /// detection's mostly lives in `ia_find_features`, so the code gets recorded too —
    /// without it, a change to the stretch or the detector leaves every cached feature
    /// file in place and does nothing at all on a resumed sequence.
    func testTheKeypointStageRecordsTheVersionOfTheCodeThatBuiltIt() {
        let recorded = ArtifactInputs.current(from: config())
            .stages[ArtifactStage.keypoints.rawValue]
        XCTAssertEqual(recorded?["detectionAlgorithmVersion"],
                       "\(ArtifactInputs.detectionAlgorithmVersion)")
    }

    /// The whole reason this lever is affordable.  Nothing upstream of `keypoints` depends
    /// on it, so `andDownstream` reaches forward only: a bump discards the alignment, the
    /// outlier groups and the frames rendered from them, and leaves the horizon masks —
    /// which cost far more to rebuild, and which the detection code has no hand in — alone.
    ///
    /// The three stages after `keypoints` were once one lump inside
    /// `invalidateStaleArtifacts`, deleted by the keypoint branch itself, so naming them
    /// changed what this reports and not what a bump costs.
    func testBumpingTheDetectionVersionInvalidatesTheKeypointsAndNothingUpstream() {
        let c = config()
        let current = ArtifactInputs.current(from: c)
        let builtByAnEarlierStar = record(current,
                                          withKeypointInput: "detectionAlgorithmVersion",
                                          setTo: "1")

        let stale = current.staleStages(comparedTo: builtByAnEarlierStar)

        XCTAssertEqual(stale, [.keypoints, .alignment, .outliers, .output],
                       "a detection-code change cannot have moved a horizon mask, and " +
                       "rebuilding those would cost the whole sequence (got \(stale))")
        XCTAssertEqual(current.differences(from: builtByAnEarlierStar)[.keypoints],
                       ["detectionAlgorithmVersion 1 -> " +
                          "\(ArtifactInputs.detectionAlgorithmVersion)"],
                       "and the log has to be able to name the reason")
    }

    /// Every temp directory written by 0.11.4 or 0.11.5 is in this state: a record at the
    /// current version whose keypoint stage predates this key. Their features came out of
    /// the min/max stretch that 485c4e04 replaced, so they have to go — once.
    ///
    /// Only those. A directory from before `ArtifactInputs` existed has no record at all,
    /// and `staleStages(comparedTo: nil)` invalidates nothing by design
    /// (`testNoStoredRecordInvalidatesNothing`), so this cannot reach it: those sequences
    /// keep the old stretch's keypoints until they are reprocessed from scratch.
    func testARecordFromBeforeThisKeyExistedInvalidatesItsKeypointsExactlyOnce() throws {
        let c = config()
        defer { tearDownPath(c.tempOutputPath) }
        let current = ArtifactInputs.current(from: c)
        let pre = record(current, withKeypointInput: "detectionAlgorithmVersion", setTo: nil)
        XCTAssertEqual(pre.version, ArtifactInputs.currentVersion,
                       "precondition: same version, so this is compared rather than " +
                       "waved through as an unreadable format")

        XCTAssertEqual(current.staleStages(comparedTo: pre),
                       [.keypoints, .alignment, .outliers, .output],
                       "the key appearing at all is what invalidates these — its value " +
                       "is never compared against anything, because they have none")

        // Once: the run that rebuilds them records the current inputs, and the run after
        // that finds nothing to do.
        try current.save(toTempOutputPath: c.tempOutputPath)
        let stored = try XCTUnwrap(ArtifactInputs.load(fromTempOutputPath: c.tempOutputPath))
        XCTAssertTrue(ArtifactInputs.current(from: c).staleStages(comparedTo: stored).isEmpty)
    }

    /// The horizon stages deliberately have no equivalent, and adding one is not a
    /// like-for-like decision: `horizon` leads the dependency order, so a version there
    /// takes the merged masks, every keypoint set and every homography with it — a full
    /// reprocess, against the keypoint lever's re-alignment. Change this test when a
    /// horizon change actually moves a mask, and not before.
    func testOnlyTheKeypointStageRecordsACodeVersion() {
        let inputs = ArtifactInputs.current(from: config())
        for stage in [ArtifactStage.horizon, .mergedHorizon] {
            let versionKeys = (inputs.stages[stage.rawValue] ?? [:]).keys
              .filter { $0.lowercased().contains("algorithmversion") }
            XCTAssertTrue(versionKeys.isEmpty,
                          "\(stage) records \(versionKeys), which invalidates it and " +
                          "everything downstream on any star upgrade that bumps it")
        }
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

    /// The alignment stage: what the homographies and the aligned images were fitted
    /// under.  Before these were recorded, turning earth alignment on for a
    /// half-processed moving sequence left the first half aligned the old way.
    func testSettingsFedToAlignmentInvalidateIt() {
        var base = config()
        base.tripodHeadWasMoving = true
        let mutations: [(String, (inout Config) -> Void)] = [
            ("allowEarthAlignment",        { $0.allowEarthAlignment = true }),
            ("homographySmoothingEpsilon", { $0.homographySmoothingEpsilon = 0.25 }),
            ("pixelThreshold",             { $0.pixelThreshold = 2.5 }),
            ("numberAlignedNeighborFrames", { $0.numberAlignedNeighborFrames = 12 }),
            ("horizonDetectionEnabled",    { $0.horizonDetectionEnabled = false }),
        ]
        for (name, mutate) in mutations {
            var after = base
            mutate(&after)
            let stale = ArtifactInputs.current(from: after)
                .staleStages(comparedTo: ArtifactInputs.current(from: base))
            XCTAssertTrue(stale.contains(.alignment),
                          "changing \(name) must invalidate the alignment")
            XCTAssertTrue(stale.contains(.output),
                          "and the output with it, since the finished frame is composited " +
                          "from the aligned neighbours")
        }
    }

    /// A fixed camera has no ground to align — the earth branch median merges the static
    /// neighbours and reads none of the earth settings — so the toggle cannot have changed
    /// anything that is on disk.
    func testEarthAlignmentDoesNotInvalidateAFixedCamera() {
        var base = config()
        base.tripodHeadWasMoving = false
        var after = base
        after.allowEarthAlignment = true

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: base))
        XCTAssertTrue(stale.isEmpty, "got \(stale)")
    }

    func testSettingsFedToOutlierDetectionInvalidateIt() {
        var base = config()
        base.cleanMethod = .selective
        let mutations: [(String, (inout Config) -> Void)] = [
            ("detectionType",     { $0.detectionType = .excessive }),
            ("ignoreLowerPixels", { $0.ignoreLowerPixels = 200 }),
            ("numberFinalProcessingNeighborsNeeded",
                                  { $0.numberFinalProcessingNeighborsNeeded = 4 }),
            ("cleanMethod",       { $0.cleanMethod = .automatic(true) }),
        ]
        for (name, mutate) in mutations {
            var after = base
            mutate(&after)
            let stale = ArtifactInputs.current(from: after)
                .staleStages(comparedTo: ArtifactInputs.current(from: base))
            XCTAssertTrue(stale.contains(.outliers),
                          "changing \(name) must invalidate the outlier groups")
            XCTAssertTrue(stale.contains(.output),
                          "and the output with it, since the removal is painted from them")
            XCTAssertFalse(stale.contains(.alignment),
                           "but not the alignment: \(name) is read after the frames are " +
                           "aligned, and re-aligning for it would throw away the expensive " +
                           "half of the run for nothing")
        }
    }

    /// A clean method with no outliers writes no outlier group, so nothing about how they
    /// would have been detected can be stale.
    func testOutlierDetectionSettingsDoNotInvalidateAnAutomaticOnlyRun() {
        var base = config()
        base.cleanMethod = .automatic(false)
        var after = base
        after.detectionType = .excessive
        after.ignoreLowerPixels = 200

        let stale = ArtifactInputs.current(from: after)
            .staleStages(comparedTo: ArtifactInputs.current(from: base))
        XCTAssertTrue(stale.isEmpty, "got \(stale)")
    }

    /// The last stage.  These change how the finished frame is painted and nothing
    /// upstream of it, so the alignment — hours of work on a long sequence — must survive.
    func testSettingsFedToTheOutputInvalidateOnlyTheOutput() {
        let base = config()
        let mutations: [(String, (inout Config) -> Void)] = [
            ("outlierGroupPaintBorderPixels",
               { $0.outlierGroupPaintBorderPixels = 40 }),
            ("outlierGroupPaintBorderInnerWallPixels",
               { $0.outlierGroupPaintBorderInnerWallPixels = 9 }),
            ("pixelReplacementOverrides",
               { $0.pixelReplacementOverrides = [4: .selective] }),
        ]
        for (name, mutate) in mutations {
            var after = base
            mutate(&after)
            let stale = ArtifactInputs.current(from: after)
                .staleStages(comparedTo: ArtifactInputs.current(from: base))
            XCTAssertEqual(stale, [.output],
                           "changing \(name) must redo the merge and keep everything " +
                           "that fed it (got \(stale))")
        }
    }

    /// `pixelReplacementOverrides` is a dictionary, and an unordered one recorded two ways
    /// would invalidate the output every run for a sequence that had not changed at all.
    func testTheSameOverridesRecordTheSameWayWhateverOrderTheyWereBuiltIn() {
        var one = config()
        one.pixelReplacementOverrides = [1: .selective, 7: .automatic(true), 3: .automatic(false)]
        var two = config()
        two.pixelReplacementOverrides = [3: .automatic(false), 1: .selective, 7: .automatic(true)]

        XCTAssertEqual(ArtifactInputs.current(from: one).stages,
                       ArtifactInputs.current(from: two).stages)
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
            // The answer to "redo the frames that were done differently?" is not itself a
            // difference — recording it would make every run that was told "no" look
            // changed to the run after it.
            ("reprocessOnSettingsChange",  { $0.reprocessOnSettingsChange = false }),
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
