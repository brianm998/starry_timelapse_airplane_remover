import XCTest
import StarCore
@testable import Star

/// The horizon painter tells the user when detection or a refinement stroke fails, in the
/// desktop client's words, and a failed stroke puts back the horizon the solver last gave.
@MainActor
final class HorizonPaintStateFailureTests: XCTestCase {

    private let bandFailed = "ui.horizon_detection_failed_adjust_the_band_and_try_again"
    private let strokeFailed = "ui.refinement_failed_try_another_stroke"

    private func refinementState() -> HorizonPaintState {
        let state = HorizonPaintState(viewWidth: 100, viewHeight: 100)
        state.loadExistingHorizon([Int?](repeating: 50, count: 100), margin: 10)
        return state
    }

    func testBandFailureShowsMessage() {
        let state = HorizonPaintState(viewWidth: 100, viewHeight: 100)
        state.setPhase(.computing)
        state.bandComputationFailed()
        XCTAssertEqual(state.detectionError, localized(bandFailed))
        XCTAssertEqual(state.phase, .bandSelection)
    }

    func testRefinementFailureRestoresHorizon() {
        let state = refinementState()
        XCTAssertEqual(state.phase, .refinement)
        state.brushRadius = 20
        state.addStroke(at: CGPoint(x: 50, y: 80))   // paints sky: preview moves down
        XCTAssertNotEqual(state.previewHorizonY?[50], 50)
        state.refinementFailed()
        XCTAssertEqual(state.detectionError, localized(strokeFailed))
        XCTAssertEqual(state.previewHorizonY?[50], 50)
        XCTAssertEqual(state.previewHorizonY ?? [], state.lastHorizonY ?? [nil])
    }

    func testNextStrokeClearsMessage() {
        let state = refinementState()
        state.refinementFailed()
        XCTAssertNotNil(state.detectionError)
        state.addStroke(at: CGPoint(x: 50, y: 50))
        XCTAssertNil(state.detectionError)
    }

    func testEmptyBandIsFailure() {
        XCTAssertFalse(HorizonPaintState.hasDetectedColumn([Int?](repeating: nil, count: 100)))
        XCTAssertFalse(HorizonPaintState.hasDetectedColumn([]))
        XCTAssertTrue(HorizonPaintState.hasDetectedColumn([nil, 3, nil]))
    }
}
