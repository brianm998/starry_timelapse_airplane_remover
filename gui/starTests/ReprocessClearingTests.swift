import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// L6 of `plans/GUI_CLIENT_PARITY_PLAN.md`: re-processing frames 2 and 6 used to clear every frame from 2 to 6.
final class ReprocessClearingTests: XCTestCase {
    func testOnlyTheSelectedFramesAreCleared() {
        XCTAssertEqual(ImageSequenceViewModel.framesToClear(in: 2...6, selected: [2, 6]), [2, 6])
    }

    func testAContiguousRunIsClearedWhole() {
        XCTAssertEqual(ImageSequenceViewModel.framesToClear(in: 3...5, selected: [3, 4, 5]), [3, 4, 5])
    }

    func testNoSelectionMeansTheWholeRange() {
        XCTAssertEqual(ImageSequenceViewModel.framesToClear(in: 4...7, selected: nil), [4, 5, 6, 7])
    }

    func testASelectionOutsideTheRangeClearsNothingThere() {
        XCTAssertEqual(ImageSequenceViewModel.framesToClear(in: 4...5, selected: [1, 9]), [])
    }
}
