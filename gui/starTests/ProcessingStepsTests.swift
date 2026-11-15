import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The processing modal draws one bar per step from `FrameGraphViewModel`'s operation
/// counters.  Those counters are cumulative for as long as a sequence is open — they only
/// reset when it is closed — so every number the modal shows is a subtraction, and a
/// subtraction that is wrong still draws a perfectly plausible bar.  That is what these
/// pin down.
final class ProcessingStepsTests: XCTestCase {

    // MARK: - which steps are listed

    /// Everything on: a moving camera with earth alignment, horizon detection, the horizon
    /// consensus and a clean method that reviews outliers.
    private func allSteps() -> [OperationType] {
        ProcessingSteps.types(horizonDetectionEnabled: true,
                              hasStaticReferenceHorizon: false,
                              cameraWasMoving: true,
                              allowEarthAlignment: true,
                              usesOutliers: true,
                              usesHorizonConsensus: true)
    }

    func testTheStepsAreInTheOrderTheModalStacksThem() {
        XCTAssertEqual(allSteps(),
                       [.horizon, .mergedHorizon,
                        .starKeypoints, .earthKeypoints,
                        .starHomography, .earthHomography,
                        .horizonConsensus,
                        .outliers, .merge])
    }

    /// The horizon consensus is carried along the aligned ground, so it has a row only where
    /// the ground is aligned — and only with its own setting on.
    func testTheHorizonConsensusIsListedOnlyWhereTheGroundIsAligned() {
        func types(moving: Bool, earth: Bool, consensus: Bool) -> [OperationType] {
            ProcessingSteps.types(horizonDetectionEnabled: true,
                                  hasStaticReferenceHorizon: false,
                                  cameraWasMoving: moving,
                                  allowEarthAlignment: earth,
                                  usesOutliers: true,
                                  usesHorizonConsensus: consensus)
        }
        XCTAssertTrue(types(moving: true, earth: true, consensus: true).contains(.horizonConsensus))
        XCTAssertFalse(types(moving: true, earth: true, consensus: false).contains(.horizonConsensus))
        XCTAssertFalse(types(moving: false, earth: true, consensus: true).contains(.horizonConsensus))
        XCTAssertFalse(types(moving: true, earth: false, consensus: true).contains(.horizonConsensus))

        var config = Config()
        config.tripodHeadWasMoving = true
        config.allowEarthAlignment = true
        XCTAssertTrue(ProcessingSteps.types(for: config).contains(.horizonConsensus),
                      "on by default for a moving camera")
    }

    func testEarthStepsAreNotListedWhenEarthAlignmentIsOff() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertEqual(types, [.horizon, .mergedHorizon, .starKeypoints, .starHomography,
                               .outliers, .merge])
    }

    /// The setting is not enough on its own: `FrameGraphBuilder` needs the camera to have
    /// been moving too, so on a fixed tripod these rows would sit at zero all run.
    func testEarthStepsAreNotListedForAFixedCameraEvenWithEarthAlignmentOn() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: false,
                                          allowEarthAlignment: true,
                                          usesOutliers: true)
        XCTAssertFalse(types.contains(.earthKeypoints))
        XCTAssertFalse(types.contains(.earthHomography))
    }

    /// Earth work is masked by the horizon, so with no horizon detection there is none of
    /// it either — the builder gates both on `hasHorizon && processEarth`.
    func testEarthStepsAreNotListedWithoutHorizonDetection() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: false,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: true,
                                          usesOutliers: true)
        XCTAssertEqual(types, [.starKeypoints, .starHomography, .outliers, .merge])
    }

    func testHorizonStepsAreNotListedWhenHorizonDetectionIsOff() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: false,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: false,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertEqual(types, [.starKeypoints, .starHomography, .outliers, .merge])
    }

    /// A painted reference horizon on a static sequence is used directly, so neither
    /// detection nor the merge that combines detections runs at all.
    func testHorizonStepsAreNotListedForAPaintedStaticReference() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: true,
                                          cameraWasMoving: false,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertFalse(types.contains(.horizon))
        XCTAssertFalse(types.contains(.mergedHorizon))
    }

    /// The same painted reference does not apply to a moving sequence — there the painted
    /// frames are references for detection rather than a replacement for it.
    func testHorizonStepsSurviveAPaintedReferenceWhenTheCameraMoved() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: true,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: false,
                                          usesOutliers: true)
        XCTAssertTrue(types.contains(.horizon))
        XCTAssertTrue(types.contains(.mergedHorizon))
    }

    func testOutliersAreNotListedForACleanMethodThatDoesNotUseThem() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: false,
                                          usesOutliers: false)
        XCTAssertFalse(types.contains(.outliers))
        XCTAssertEqual(types.last, .merge)
    }

    /// The two steps every run takes, whatever it is configured to do.
    func testKeypointsAndTheMergeAreAlwaysListed() {
        for horizon in [true, false] {
            for earth in [true, false] {
                for moving in [true, false] {
                    for outliers in [true, false] {
                        let types = ProcessingSteps.types(
                          horizonDetectionEnabled: horizon,
                          hasStaticReferenceHorizon: false,
                          cameraWasMoving: moving,
                          allowEarthAlignment: earth,
                          usesOutliers: outliers)
                        XCTAssertTrue(types.contains(.starKeypoints))
                        XCTAssertTrue(types.contains(.starHomography))
                        XCTAssertTrue(types.contains(.merge))
                        XCTAssertFalse(types.contains(.preview))
                    }
                }
            }
        }
    }

    /// Every listed step needs a row label, and `localized` returns the key itself when the
    /// catalogue does not have it — which renders as `ui.merged_horizon` on screen rather
    /// than as anything a user would recognise.
    func testEveryListedStepHasALabelFromTheCatalogue() {
        for type in allSteps() {
            let name = type.stepName
            XCTAssertFalse(name.isEmpty, "\(type) has no name")
            XCTAssertFalse(name.hasPrefix("ui."),
                           "\(type) is labelled '\(name)', which is a missing catalogue key")
        }
    }

    /// Same for the tooltip that explains the step.  An empty one is a row that silently
    /// stops explaining itself; a `ui.` one is the key showing through.
    func testEveryListedStepHasHoverHelpFromTheCatalogue() {
        for type in allSteps() {
            let help = type.stepHelp
            XCTAssertFalse(help.isEmpty, "\(type) has no hover help")
            XCTAssertFalse(help.hasPrefix("ui."),
                           "\(type)'s hover help is '\(help)', a missing catalogue key")
            XCTAssertNotEqual(help, type.stepName,
                              "\(type)'s hover help just repeats its label")
        }
    }

    // MARK: - which steps are drawn

    private func progress(_ entries: [(OperationType, Int)]) -> [ProcessingStepProgress] {
        entries.map { ProcessingStepProgress(type: $0.0, queued: $0.1, running: 0, done: 0) }
    }

    /// The point of the whole exercise: a step whose artifacts were all already on disk
    /// built no operations, so it is not a step this run takes and it should not be a row.
    func testAStepWithNothingToDoIsNotDrawnOnceThePlanIsSettled() {
        let steps = progress([(.horizon, 0), (.starKeypoints, 19), (.merge, 19)])
        let visible = ProcessingSteps.visible(steps, graphIsBuilt: true)

        XCTAssertEqual(visible.map(\.type), [.starKeypoints, .merge])
    }

    /// Until the builder has finished, every step has no operations yet.  Filtering then
    /// would open the panel empty and pop the rows in one at a time.
    func testNothingIsHiddenWhileThePlanIsStillBeingWorkedOut() {
        let steps = progress([(.horizon, 0), (.starKeypoints, 0), (.merge, 0)])
        let visible = ProcessingSteps.visible(steps, graphIsBuilt: false)

        XCTAssertEqual(visible.map(\.type), [.horizon, .starKeypoints, .merge])
    }

    /// A step that has finished still has operations, so it keeps its filled bar rather
    /// than vanishing at the moment it completes.
    func testAFinishedStepIsStillDrawn() {
        let done = ProcessingStepProgress(type: .horizon, queued: 0, running: 0, done: 19)
        let visible = ProcessingSteps.visible([done], graphIsBuilt: true)

        XCTAssertEqual(visible.map(\.type), [.horizon])
    }

    // MARK: - the arithmetic

    private func counts(_ entries: [OperationType: (queued: UInt, running: UInt, done: UInt)])
      -> [OperationType: [OperationState: UInt]]
    {
        entries.mapValues { [.queued: $0.queued, .running: $0.running, .done: $0.done] }
    }

    private func step(_ progress: [ProcessingStepProgress],
                      _ type: OperationType) throws -> ProcessingStepProgress
    {
        try XCTUnwrap(progress.first { $0.type == type })
    }

    func testAStepReportsItsQueuedRunningAndDoneCounts() throws {
        let progress = ProcessingSteps.progress(
          for: [.horizon],
          counts: counts([.horizon: (queued: 5, running: 2, done: 3)]))
        let horizon = try step(progress, .horizon)

        XCTAssertEqual(horizon.queued, 5)
        XCTAssertEqual(horizon.running, 2)
        XCTAssertEqual(horizon.done, 3)
        XCTAssertEqual(horizon.total, 10)
        XCTAssertTrue(horizon.hasWork)
    }

    func testTheBarSegmentsAreFractionsOfTheWholeStep() throws {
        let progress = ProcessingSteps.progress(
          for: [.merge],
          counts: counts([.merge: (queued: 1, running: 1, done: 2)]))
        let merge = try step(progress, .merge)

        XCTAssertEqual(merge.doneFraction, 0.5, accuracy: 0.0001)
        XCTAssertEqual(merge.runningFraction, 0.25, accuracy: 0.0001)
    }

    /// A step whose artifacts were all on disk already builds no operations at all.  It has
    /// to divide by something other than zero, and it must not read as 100% done.
    func testAStepWithNoOperationsHasNoWorkAndNoFilledBar() throws {
        let progress = ProcessingSteps.progress(for: [.starKeypoints], counts: [:])
        let keypoints = try step(progress, .starKeypoints)

        XCTAssertEqual(keypoints.total, 0)
        XCTAssertFalse(keypoints.hasWork)
        XCTAssertEqual(keypoints.doneFraction, 0)
        XCTAssertEqual(keypoints.runningFraction, 0)
    }

    func testAStepIsAskedForEvenWhenTheCountersHaveNothingForIt() {
        let progress = ProcessingSteps.progress(
          for: [.horizon, .merge],
          counts: counts([.horizon: (queued: 0, running: 0, done: 4)]))

        XCTAssertEqual(progress.map(\.type), [.horizon, .merge],
                       "every requested step needs a row, so the rows do not move about "
                         + "as the run reaches each one")
    }

    // MARK: - work finished before the run started

    /// The bug this exists for: star was stopped part way through a 1434 frame sequence,
    /// 494 of them already merged.  The rebuilt graph only has merge ops for the 940 that
    /// are left, so counting operations alone reported "74 / 940" against a sequence the
    /// line above it called 1434 frames — the wrong job, and a bar that jumps backwards
    /// every time the run is resumed.
    func testAResumedStepIsMeasuredAgainstTheWholeSequence() throws {
        let progress = ProcessingSteps.progress(
          for: [.merge],
          counts: counts([.merge: (queued: 866, running: 0, done: 74)]),
          alreadyDone: [.merge: 494])
        let merge = try step(progress, .merge)

        XCTAssertEqual(merge.total, 1434)
        XCTAssertEqual(merge.completed, 568)
        XCTAssertEqual(merge.doneFraction, 568.0 / 1434.0, accuracy: 0.0001)
    }

    /// Work done before the run counts as done, not as running or queued, so the bar fills
    /// from the same end whichever run did it.
    func testWorkFromBeforeTheRunFillsTheDoneEndOfTheBar() throws {
        let progress = ProcessingSteps.progress(
          for: [.starKeypoints],
          counts: counts([.starKeypoints: (queued: 2, running: 1, done: 1)]),
          alreadyDone: [.starKeypoints: 6])
        let keypoints = try step(progress, .starKeypoints)

        XCTAssertEqual(keypoints.total, 10)
        XCTAssertEqual(keypoints.completed, 7)
        XCTAssertEqual(keypoints.doneFraction, 0.7, accuracy: 0.0001)
        XCTAssertEqual(keypoints.runningFraction, 0.1, accuracy: 0.0001)
        XCTAssertEqual(keypoints.queued, 2)
    }

    /// A step finished entirely by an earlier run builds no operations at all.  It is not a
    /// step with nothing to it — it is a step that is done — so it keeps its row, full.
    func testAStepFinishedBeforeTheRunIsShownComplete() throws {
        let progress = ProcessingSteps.progress(
          for: [.horizon],
          counts: [:],
          alreadyDone: [.horizon: 1434])
        let horizon = try step(progress, .horizon)

        XCTAssertTrue(horizon.hasWork)
        XCTAssertEqual(horizon.completed, 1434)
        XCTAssertEqual(horizon.total, 1434)
        XCTAssertEqual(horizon.doneFraction, 1)
        XCTAssertEqual(ProcessingSteps.visible([horizon], graphIsBuilt: true).map(\.type),
                       [.horizon],
                       "a step that is finished is not a step to hide")
    }

    /// Nothing on disk and nothing to do is still nothing, and still goes.
    func testAStepWithNeitherOperationsNorEarlierWorkIsStillHidden() throws {
        let progress = ProcessingSteps.progress(for: [.mergedHorizon], counts: [:])
        let merged = try step(progress, .mergedHorizon)

        XCTAssertFalse(merged.hasWork)
        XCTAssertTrue(ProcessingSteps.visible([merged], graphIsBuilt: true).isEmpty)
    }

    /// The segments still tile the bar exactly once earlier work is one of them.
    func testTheSegmentsFillTheWholeBarWithEarlierWorkInIt() throws {
        let progress = ProcessingSteps.progress(
          for: [.merge],
          counts: counts([.merge: (queued: 3, running: 2, done: 1)]),
          alreadyDone: [.merge: 4])
        let merge = try step(progress, .merge)

        XCTAssertEqual(merge.doneFraction + merge.runningFraction
                         + Double(merge.queued) / Double(merge.total),
                       1, accuracy: 0.0001)
    }

    // MARK: - the baseline

    /// The whole point of the baseline: a second run in the same session starts with the
    /// first run's operations still counted as done, and without subtracting them the bars
    /// would open most of the way across.
    func testASecondRunMeasuresFromWhereTheFirstOneFinished() throws {
        let baseline = counts([.horizon: (queued: 0, running: 0, done: 20)])
        let now = counts([.horizon: (queued: 2, running: 1, done: 22)])

        let horizon = try step(ProcessingSteps.progress(for: [.horizon],
                                                        counts: now,
                                                        since: baseline),
                               .horizon)
        XCTAssertEqual(horizon.total, 5, "this run created five ops, not twenty five")
        XCTAssertEqual(horizon.done, 2)
        XCTAssertEqual(horizon.running, 1)
        XCTAssertEqual(horizon.queued, 2)
    }

    func testAnEmptyBaselineMeasuresEverythingTheCountersHold() throws {
        let now = counts([.merge: (queued: 0, running: 0, done: 7)])
        let merge = try step(ProcessingSteps.progress(for: [.merge], counts: now), .merge)

        XCTAssertEqual(merge.done, 7)
        XCTAssertEqual(merge.total, 7)
        XCTAssertEqual(merge.doneFraction, 1)
    }

    /// The gui does not let a second run start while one is going, but nothing in the
    /// arithmetic depends on that: a baseline taken with work still in flight has to produce
    /// a bar that can be drawn, not a negative width.
    func testLeftoverOperationsFromBeforeTheBaselineCannotMakeASegmentNegative() throws {
        let baseline = counts([.starHomography: (queued: 3, running: 0, done: 0)])
        // those three finished, and nothing new was ever queued
        let now = counts([.starHomography: (queued: 0, running: 0, done: 3)])

        let align = try step(ProcessingSteps.progress(for: [.starHomography],
                                                      counts: now,
                                                      since: baseline),
                             .starHomography)
        XCTAssertGreaterThanOrEqual(align.queued, 0)
        XCTAssertGreaterThanOrEqual(align.running, 0)
        XCTAssertGreaterThanOrEqual(align.done, 0)
        XCTAssertEqual(align.total, align.queued + align.running + align.done)
        XCTAssertLessThanOrEqual(align.doneFraction, 1)
    }

    /// Every op the counters hold is in exactly one state, so the three segments always add
    /// up to the whole bar however the counts move.
    func testTheSegmentsAlwaysFillExactlyTheWholeBar() throws {
        for done in 0...4 {
            for running in 0...4 {
                let now = counts([.merge: (queued: 4, running: UInt(running), done: UInt(done))])
                let merge = try step(ProcessingSteps.progress(for: [.merge], counts: now), .merge)
                XCTAssertEqual(merge.doneFraction + merge.runningFraction
                                 + Double(merge.queued) / Double(merge.total),
                               1, accuracy: 0.0001)
            }
        }
    }
}
