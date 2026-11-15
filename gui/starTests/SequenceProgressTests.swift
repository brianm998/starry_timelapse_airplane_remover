import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The panel star puts up when a sequence is re-opened reports how far the last run got by
/// counting artifacts on disk, and then hands those counts to the same bars the processing
/// modal draws.  Those bars were built to describe a *live* run — this is the second caller,
/// filling in a different pair of fields for a different meaning, and getting the mapping
/// wrong would draw a perfectly plausible bar over the wrong number.  That, and the two
/// predicates that decide which of the panel's buttons the user gets, are what these pin down.
final class SequenceProgressTests: XCTestCase {

    private func progress(frameCount: Int,
                          framesComplete: Int,
                          steps: [ProcessingStepProgress]) -> SequenceProgress
    {
        SequenceProgress(sequenceName: "a_sequence",
                         frameCount: frameCount,
                         framesComplete: framesComplete,
                         steps: steps)
    }

    private func surveyed(_ types: [OperationType],
                          frameCount: Int,
                          _ onDisk: [OperationType: Int]) -> [ProcessingStepProgress]
    {
        SequenceProgressSurvey.steps(for: types,
                                     frameCount: frameCount,
                                     framesOnDisk: onDisk)
    }

    private func step(_ steps: [ProcessingStepProgress],
                      _ type: OperationType) throws -> ProcessingStepProgress
    {
        try XCTUnwrap(steps.first { $0.type == type })
    }

    // MARK: - what a surveyed step says

    /// Frames whose artifact is on disk belong at the *finished* end of the bar, and to
    /// `alreadyDone` rather than `done`: nothing here is work a run in front of the user
    /// did, which is the whole distinction `ProcessingStepProgress` draws between the two.
    func testFramesFoundOnDiskCountAsWorkDoneBeforeThisRun() throws {
        let horizon = try step(surveyed([.horizon], frameCount: 19, [.horizon: 12]), .horizon)

        XCTAssertEqual(horizon.alreadyDone, 12)
        XCTAssertEqual(horizon.done, 0)
        XCTAssertEqual(horizon.running, 0)
        XCTAssertEqual(horizon.queued, 7)
        XCTAssertEqual(horizon.completed, 12)
        XCTAssertEqual(horizon.total, 19)
        XCTAssertEqual(horizon.doneFraction, 12.0 / 19.0, accuracy: 0.0001)
        XCTAssertEqual(horizon.runningFraction, 0)
    }

    /// The bar is over the whole sequence, whatever it finds — a step measured against only
    /// the frames it has already finished reads as complete the moment it starts.
    func testEveryStepIsMeasuredOverTheWholeSequence() {
        let steps = surveyed([.horizon, .starKeypoints, .merge],
                             frameCount: 19,
                             [.horizon: 19, .starKeypoints: 4, .merge: 0])

        XCTAssertEqual(steps.map(\.total), [19, 19, 19])
    }

    /// A step this configuration takes but that the survey found nothing for is a row at
    /// zero, not a missing row: the survey went and looked, and "none yet" is its answer.
    /// (`ProcessingSteps.visible` would drop it, which is right for a live run and wrong
    /// here — this panel does not filter.)
    func testAStepWithNothingOnDiskStillGetsARow() throws {
        let steps = surveyed([.horizon, .merge], frameCount: 19, [.horizon: 19])
        let merge = try step(steps, .merge)

        XCTAssertEqual(steps.map(\.type), [.horizon, .merge])
        XCTAssertEqual(merge.completed, 0)
        XCTAssertEqual(merge.queued, 19)
        XCTAssertEqual(merge.doneFraction, 0)
        XCTAssertTrue(merge.hasWork, "a row over a sequence with frames in it is not empty")
    }

    func testTheRowsComeOutInTheOrderTheStepsWereAskedFor() {
        let types = ProcessingSteps.types(horizonDetectionEnabled: true,
                                          hasStaticReferenceHorizon: false,
                                          cameraWasMoving: true,
                                          allowEarthAlignment: true,
                                          usesOutliers: true)
        XCTAssertEqual(surveyed(types, frameCount: 5, [:]).map(\.type), types)
    }

    /// The counts come off the filesystem, so nothing upstream guarantees they are sane.  A
    /// count past the end of the sequence must not push `queued` negative — a negative
    /// segment width is a drawing fault, not a wrong number.
    func testACountLargerThanTheSequenceIsClampedToIt() throws {
        let merge = try step(surveyed([.merge], frameCount: 19, [.merge: 25]), .merge)

        XCTAssertEqual(merge.alreadyDone, 19)
        XCTAssertEqual(merge.queued, 0)
        XCTAssertEqual(merge.doneFraction, 1, accuracy: 0.0001)
    }

    func testANegativeCountIsTreatedAsNoneAtAll() throws {
        let merge = try step(surveyed([.merge], frameCount: 19, [.merge: -3]), .merge)

        XCTAssertEqual(merge.alreadyDone, 0)
        XCTAssertEqual(merge.queued, 19)
    }

    /// The bar has three segments and they have to cover it exactly, whatever was found.
    func testTheSegmentsAlwaysFillExactlyTheWholeBar() throws {
        for onDisk in 0...19 {
            let merge = try step(surveyed([.merge], frameCount: 19, [.merge: onDisk]), .merge)
            XCTAssertEqual(merge.doneFraction + merge.runningFraction
                             + Double(merge.queued) / Double(merge.total),
                           1, accuracy: 0.0001)
        }
    }

    /// An empty sequence has to divide by something other than zero.
    func testAnEmptySequenceDrawsAnEmptyBarRatherThanDividingByZero() throws {
        let merge = try step(surveyed([.merge], frameCount: 0, [.merge: 0]), .merge)

        XCTAssertEqual(merge.total, 0)
        XCTAssertEqual(merge.doneFraction, 0)
        XCTAssertFalse(merge.hasWork)
    }

    // MARK: - which button the user gets

    func testASequenceWithEveryFrameWrittenIsComplete() {
        let steps = surveyed([.starKeypoints, .merge], frameCount: 19,
                             [.starKeypoints: 19, .merge: 19])
        let sequence = progress(frameCount: 19, framesComplete: 19, steps: steps)

        XCTAssertTrue(sequence.isComplete)
        XCTAssertFalse(sequence.isUntouched)
    }

    func testASequenceMissingOneFrameIsNotComplete() {
        let steps = surveyed([.starKeypoints, .merge], frameCount: 19,
                             [.starKeypoints: 19, .merge: 18])
        let sequence = progress(frameCount: 19, framesComplete: 18, steps: steps)

        XCTAssertFalse(sequence.isComplete)
        XCTAssertFalse(sequence.isUntouched)
    }

    /// An empty sequence is not a finished one — offering it a video render would offer a
    /// render of nothing.
    func testAnEmptySequenceIsNotComplete() {
        XCTAssertFalse(progress(frameCount: 0, framesComplete: 0, steps: []).isComplete)
    }

    func testASequenceWithNothingOnDiskAtAllIsUntouched() {
        let steps = surveyed([.horizon, .starKeypoints, .merge], frameCount: 19, [:])
        let sequence = progress(frameCount: 19, framesComplete: 0, steps: steps)

        XCTAssertTrue(sequence.isUntouched)
        XCTAssertFalse(sequence.isComplete)
    }

    /// The distinction the "Start Processing" / "Finish Processing" wording rests on: a
    /// sequence with its keypoints detected and nothing merged has had most of the hours
    /// spent on it already, whatever the frame count says.
    func testASequenceWithAnEarlyStepDoneIsNotUntouchedEvenWithNoFramesWritten() {
        let steps = surveyed([.starKeypoints, .merge], frameCount: 19,
                             [.starKeypoints: 19, .merge: 0])
        let sequence = progress(frameCount: 19, framesComplete: 0, steps: steps)

        XCTAssertFalse(sequence.isUntouched)
        XCTAssertFalse(sequence.isComplete)
    }

    /// The panel's status line and its buttons read the same two predicates, so exactly one
    /// of the three states it describes can hold at a time.
    func testCompleteAndUntouchedAreNeverBothTrue() {
        for onDisk in 0...19 {
            let steps = surveyed([.merge], frameCount: 19, [.merge: onDisk])
            let sequence = progress(frameCount: 19, framesComplete: onDisk, steps: steps)
            XCTAssertFalse(sequence.isComplete && sequence.isUntouched,
                           "\(onDisk) frames written reads as both finished and untouched")
        }
    }

    // MARK: - the footer

    /// Settings sits immediately left of the one action, so the processing settings can be
    /// looked at before the video is rendered — and the action stays the rightmost button.
    func testSettingsIsJustLeftOfRenderVideoForACompleteSequence() {
        let steps = surveyed([.merge], frameCount: 19, [.merge: 19])
        let sequence = progress(frameCount: 19, framesComplete: 19, steps: steps)

        XCTAssertEqual(SequenceProgressPanel.footerActions(for: sequence),
                       [.close, .settings, .renderVideo])
    }

    /// The same place in the other state, so the settings can be changed before a partly
    /// processed run is finished (or an untouched one is started).
    func testSettingsIsJustLeftOfTheProcessingButtonForAnIncompleteSequence() {
        let untouched = progress(frameCount: 19, framesComplete: 0,
                                 steps: surveyed([.starKeypoints, .merge], frameCount: 19, [:]))
        XCTAssertEqual(SequenceProgressPanel.footerActions(for: untouched),
                       [.close, .settings, .startProcessing])

        let partial = progress(frameCount: 19, framesComplete: 4,
                               steps: surveyed([.starKeypoints, .merge], frameCount: 19,
                                               [.starKeypoints: 19, .merge: 4]))
        XCTAssertEqual(SequenceProgressPanel.footerActions(for: partial),
                       [.close, .settings, .finishProcessing])

        XCTAssertEqual(SequenceProgressAction.settings.accessibilityIdentifier,
                       "sequenceprogress.settings")
    }

    /// Render and progress robots A1: the header robot follows the complete / rebuild / not-yet / partial decision.
    func testSequenceProgressArt() {
        let steps = surveyed([.merge], frameCount: 19, [.merge: 19])
        let complete = progress(frameCount: 19, framesComplete: 19, steps: steps)
        XCTAssertEqual(SequenceProgressPanel.progressArt(for: complete), .done)

        let rebuild = SequenceProgress(sequenceName: "a_sequence", frameCount: 19, framesComplete: 0,
                                       steps: steps, staleStages: [.keypoints])
        XCTAssertTrue(rebuild.needsRebuild)
        XCTAssertEqual(SequenceProgressPanel.progressArt(for: rebuild), .rebuilding)

        let untouched = progress(frameCount: 19, framesComplete: 0,
                                 steps: surveyed([.merge], frameCount: 19, [:]))
        XCTAssertEqual(SequenceProgressPanel.progressArt(for: untouched), .review)

        let partial = progress(frameCount: 19, framesComplete: 4,
                               steps: surveyed([.merge], frameCount: 19, [.merge: 4]))
        XCTAssertEqual(SequenceProgressPanel.progressArt(for: partial), .review)
    }

    /// Import Video A3: each frame format has its own tile.
    func testEveryFrameFormatHasItsTile() {
        XCTAssertEqual(FrameDecodeFormat.Kind.tiff16.art, .formatTiff16)
        XCTAssertEqual(FrameDecodeFormat.Kind.tiff8.art, .formatTiff8)
        XCTAssertEqual(FrameDecodeFormat.Kind.jpeg.art, .formatJpeg)
        XCTAssertEqual(Set(FrameDecodeFormat.Kind.allCases.map { $0.art }).count, FrameDecodeFormat.Kind.allCases.count)
    }

    /// Render robots A4 (and the fitting size arithmetic): rendering, success and failure each have their robot.
    func testRenderStateArt() {
        XCTAssertEqual(RenderVideoSheetView.renderArt(for: .rendering), .rendering)
        XCTAssertEqual(RenderVideoSheetView.renderArt(for: .success), .done)
        XCTAssertEqual(RenderVideoSheetView.renderArt(for: .failure), .oops)

        XCTAssertEqual(ArtImage(.done).displaySize, StarArt.done.size)
        XCTAssertEqual(ArtImage(.done, fitting: 64).displaySize, CGSize(width: 62, height: 64))
        XCTAssertEqual(ArtImage(.rendering, fitting: 96).displaySize, CGSize(width: 96, height: 84))
    }
}
