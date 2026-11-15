import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The processing modal's columns size themselves from the translated headings and step names
/// (the desktop's `ProcessingColumns`), so a long language wraps at a space instead of
/// truncating with an ellipsis ("Queu…", "In Warteschl…").
final class ProcessingColumnsTests: XCTestCase {
    private let stepTypes: [OperationType] = [
        .horizon, .mergedHorizon, .starKeypoints, .earthKeypoints, .starHomography,
        .earthHomography, .horizonConsensus, .outliers, .merge,
    ]
    private var steps: [ProcessingStepProgress] {
        stepTypes.map { ProcessingStepProgress(type: $0, queued: 1, running: 1, done: 1) }
    }
    private var caption: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: NSFont.preferredFont(forTextStyle: .caption1).pointSize, weight: .regular)
    }
    private var callout: NSFont { NSFont.preferredFont(forTextStyle: .callout) }

    /// A1: in every language no column is narrower than the widest word it holds.
    func testColumnsFitTheWidestWordOfEveryHeadingInEveryLanguage() {
        defer { StarLocalization.shared.languageOverride = nil }
        for language in StarLocalization.shared.languages {
            StarLocalization.shared.languageOverride = language.code
            let columns = ProcessingColumns.measured(steps: steps, extraction: true)
            let code = language.code
            for key in ["ui.queued", "ui.running", "ui.done"] {
                XCTAssertGreaterThanOrEqual(columns.number, TextFit.widestWord([localized(key)], font: caption), "\(key) in \(code)")
            }
            XCTAssertGreaterThanOrEqual(columns.count, TextFit.widestWord([localized("ui.n_of_m_complete", 99999, 99999)], font: caption), "n of m in \(code)")
            XCTAssertGreaterThanOrEqual(columns.eta, TextFit.widestWord([localized("ui.time_left")], font: caption), "time left in \(code)")
            let longest = ProcessingHeadline.duration(9 * 3600 + 59 * 60)
            XCTAssertGreaterThanOrEqual(columns.eta, TextFit.widestWord([longest], font: caption, wholeText: true), "estimate in \(code)")
            for name in steps.map({ $0.type.stepName }) + [localized("ui.processing_step_extracting_video")] {
                XCTAssertGreaterThanOrEqual(columns.name, TextFit.widestWord([name], font: callout), "\(name) in \(code)")
            }
            XCTAssertGreaterThanOrEqual(columns.name, ProcessingColumns.nameWidth, code)
            XCTAssertGreaterThanOrEqual(columns.number, ProcessingColumns.numberWidth, code)
            XCTAssertGreaterThanOrEqual(columns.eta, ProcessingColumns.etaWidth, code)
        }
    }

    /// A2: English keeps the constants; German grows past them.
    func testGermanColumnsGrowPastTheEnglishConstants() {
        defer { StarLocalization.shared.languageOverride = nil }
        StarLocalization.shared.languageOverride = "en"
        let english = ProcessingColumns.measured(steps: steps, extraction: true)
        XCTAssertEqual(english, ProcessingColumns(name: 180, number: 46, eta: 56))
        StarLocalization.shared.languageOverride = "de"
        let german = ProcessingColumns.measured(steps: steps, extraction: true)
        XCTAssertGreaterThan(german.number, 46, "In Warteschlange")
        XCTAssertGreaterThan(german.eta, 56, "Verbleibende Zeit")
        // One value, shared by every row: the count is three number columns, and the extraction row's count is as wide.
        XCTAssertEqual(german.count, german.number * 3)
    }

    /// A3: the panel is 640 wide unless the columns need more, and both panels take the width from the same place.
    func testPanelWidthGrowsOnlyWhenTheColumnsNeedIt() {
        defer { StarLocalization.shared.languageOverride = nil }
        typealias Panel = ProcessingModalPanel<EmptyView, EmptyView>
        StarLocalization.shared.languageOverride = "en"
        XCTAssertEqual(Panel.width(steps: steps, extraction: true), 640)
        XCTAssertEqual(SequenceProgressPanel.width(for: steps), 640)
        StarLocalization.shared.languageOverride = "de"
        let columns = ProcessingColumns.measured(steps: steps, extraction: true)
        XCTAssertEqual(Panel.width(steps: steps, extraction: true), max(640, columns.required + 40))
        XCTAssertEqual(SequenceProgressPanel.width(for: steps),
                       Panel.width(steps: steps, extraction: false))
    }
}
