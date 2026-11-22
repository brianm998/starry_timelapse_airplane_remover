import XCTest
import StarCore
@testable import Star

/// Which frames hold full outlier groups: the current one plus or minus a radius, and the grid selection.
final class OutlierWindowTests: XCTestCase {
    private func sequence(frames count: Int) -> ImageSequenceViewModel {
        var config = Config()
        config.useGPUForMerge = false
        let manager = ConfigManager(configFilename: NSTemporaryDirectory() + "c851-\(UUID().uuidString).json",
                                    config: config)
        let model = ImageSequenceViewModel(viewModel: nil, configManager: manager, trashLevel: 0.5, smallTrashMax: 0)
        model.set(numberOfFrames: count)
        return model
    }

    func testWindowIsCurrentPlusOrMinusRadius() {
        let model = sequence(frames: 100)
        let r = ImageSequenceViewModel.outlierWindowRadius
        XCTAssertGreaterThanOrEqual(r, 2, "neighbours of a loaded frame must stay loaded")
        model.currentIndex = 50
        XCTAssertEqual(model.outlierWindowIndices, Set((50 - r)...(50 + r)))
        XCTAssertLessThan(model.outlierWindowIndices.count, 100)
    }

    func testWindowClampsAtTheEndsAndIncludesSelection() {
        let model = sequence(frames: 100)
        let r = ImageSequenceViewModel.outlierWindowRadius
        model.currentIndex = 0
        XCTAssertEqual(model.outlierWindowIndices, Set(0...r))
        model.selectedFrameIndices = [0, 90, 91]
        XCTAssertEqual(model.outlierWindowIndices, Set(0...r).union([90, 91]))
    }
}
