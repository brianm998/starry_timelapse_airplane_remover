import XCTest
import StarCore
@testable import Star

/// A run that died inside a GPU merge: the next launch turns GPU merge off and says why in the banner.
/// A planted marker and no window; the preference write is injected so the real preferences file is untouched.
@MainActor
final class GPUMergeTurnedOffTests: XCTestCase {

    private func marker(inMerge: Bool) -> RunMarker {
        var m = RunMarker(id: UUID().uuidString, client: "Star", pid: 999_999)
        m.gpuMergesInFlight = inMerge ? 1 : 0
        return m
    }

    func testARunThatDiedInAGPUMergeTurnsItOffAndShowsTheBanner() {
        let viewModel = ViewModel()
        var turnedOff = 0
        viewModel.reportAbandonedRuns([marker(inMerge: true)], turnOffGPUMerge: { turnedOff += 1 })
        XCTAssertEqual(turnedOff, 1)
        XCTAssertEqual(viewModel.bannerWarning?.kind, .gpuMergeTurnedOff)
        XCTAssertEqual(viewModel.bannerWarning?.severity, .warning)
        XCTAssertTrue(viewModel.showWarningAlert, "the previousRunDied alert is still raised")
        XCTAssertEqual(viewModel.warningTitle, marker(inMerge: true).asWarning.title)
    }

    func testARunThatDiedElsewhereLeavesGPUMergeAlone() {
        let viewModel = ViewModel()
        var turnedOff = 0
        viewModel.reportAbandonedRuns([marker(inMerge: false)], turnOffGPUMerge: { turnedOff += 1 })
        XCTAssertEqual(turnedOff, 0)
        XCTAssertNil(viewModel.bannerWarning)
        XCTAssertTrue(viewModel.showWarningAlert)
    }
}
