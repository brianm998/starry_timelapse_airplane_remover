import XCTest
@testable import StarCore

/// The info dialog beside the Processing Frames "Steps" heading.  Expected text is built from the
/// catalogue rather than spelled out, so the tests hold in whatever language the machine runs in.
final class ProcessingStepsInfoTests: XCTestCase {

    private func make(moving: Bool = true,
                      method: CleanMethod = .automatic(false),
                      steps: [OperationType],
                      extraction: Bool = false) -> ProcessingStepsInfo {
        ProcessingStepsInfo.make(cameraMoving: moving, cleanMethod: method, steps: steps, showsExtraction: extraction)
    }

    private let everyStep: [OperationType] = ProcessingSteps.types(
      horizonDetectionEnabled: true, hasStaticReferenceHorizon: false, cameraWasMoving: true,
      allowEarthAlignment: true, usesOutliers: true, usesHorizonConsensus: true)

    // MARK: - A2: the opening

    func testIntroNamesMovingAndModeForMovingAutomatic() {
        let info = make(moving: true, method: .automatic(false), steps: [.merge])
        XCTAssertEqual(info.intro, localized("ui.steps_info_intro_moving", localized("ui.automatic")))
        XCTAssertTrue(info.intro.contains(localized("ui.automatic")))
        XCTAssertEqual(info.subtitle, localized("ui.steps_info_subtitle"))
    }

    func testIntroNamesStaticAndModeForStaticSelective() {
        let info = make(moving: false, method: .selective, steps: [.merge])
        XCTAssertEqual(info.intro, localized("ui.steps_info_intro_static", localized("ui.selective")))
        XCTAssertTrue(info.intro.contains(localized("ui.selective")))
        XCTAssertNotEqual(info.intro, make(moving: true, method: .selective, steps: [.merge]).intro,
                          "moving and static read differently")
    }

    func testIntroForAutoSelectiveMode() {
        let info = make(moving: true, method: .automatic(true), steps: [.merge])
        XCTAssertEqual(info.intro, localized("ui.steps_info_intro_moving", localized("ui.auto_selective")))
        XCTAssertNotEqual(info.intro, make(moving: true, method: .automatic(false), steps: [.merge]).intro,
                          "auto-selective is not named as automatic")
    }

    // MARK: - A3: exactly the steps the panel shows

    func testEntriesAreExactlyTheGivenStepsInOrder() {
        let info = make(steps: everyStep)
        XCTAssertEqual(info.entries.map(\.id), everyStep.map(\.rawValue))
        XCTAssertEqual(info.entries.map(\.name), everyStep.map(\.stepName))

        // A step the panel has dropped, from the middle of the list, is not listed.
        let without = everyStep.filter { $0 != .outliers && $0 != .horizon }
        XCTAssertEqual(make(steps: without).entries.map(\.id), without.map(\.rawValue))
    }

    func testStaticRunWithoutEarthStepsListsNoEarthEntry() {
        let steps = ProcessingSteps.types(
          horizonDetectionEnabled: true, hasStaticReferenceHorizon: false, cameraWasMoving: false,
          allowEarthAlignment: true, usesOutliers: false)
        let ids = make(moving: false, steps: steps).entries.map(\.id)
        XCTAssertEqual(ids, steps.map(\.rawValue))
        for earth in [OperationType.earthKeypoints, .earthHomography, .horizonConsensus, .outliers] {
            XCTAssertFalse(ids.contains(earth.rawValue), "\(earth) is not a step of this run")
        }
    }

    func testExtractionEntryComesFirstOnlyWhenShown() {
        let steps: [OperationType] = [.starKeypoints, .starHomography, .merge]
        let shown = make(steps: steps, extraction: true)
        XCTAssertEqual(shown.entries.map(\.id), ["extraction"] + steps.map(\.rawValue))
        XCTAssertEqual(shown.entries.first?.name, localized("ui.processing_step_extracting_video"))
        XCTAssertEqual(make(steps: steps, extraction: false).entries.map(\.id), steps.map(\.rawValue))
        XCTAssertEqual(make(steps: [], extraction: true).entries.map(\.id), ["extraction"])
        XCTAssertTrue(make(steps: [], extraction: false).entries.isEmpty)
    }

    func testTypesTheModalHasNoRowForAreSkipped() {
        XCTAssertEqual(make(steps: [.preview, .starKeypoints, .alignmentValidation]).entries.map(\.id),
                       [OperationType.starKeypoints.rawValue])
    }

    // MARK: - A4: what each does and what it relies on

    func testEveryProcessingStepTypeHasWhatAndNeedsText() {
        let info = make(steps: everyStep, extraction: true)
        XCTAssertEqual(info.entries.count, 10)
        for entry in info.entries {
            XCTAssertFalse(entry.what.isEmpty, "\(entry.id) has no description")
            XCTAssertFalse(entry.needs.isEmpty, "\(entry.id) has no dependency text")
            XCTAssertNotEqual(entry.what, entry.needs, "\(entry.id)")
            XCTAssertFalse(entry.what.contains("\n\n"), "\(entry.id): only the first paragraph of the help")
        }
        XCTAssertEqual(Set(info.entries.map(\.needs)).count, info.entries.count, "each step says its own reason")
        XCTAssertEqual(Set(info.entries.map(\.what)).count, info.entries.count)
        // Every key must really be in the catalogue, not fall back to showing the key.
        for entry in info.entries {
            XCTAssertFalse(entry.needs.hasPrefix("ui."), "\(entry.id) shows a raw key")
            XCTAssertFalse(entry.what.hasPrefix("ui."), "\(entry.id) shows a raw key")
        }
    }
}
