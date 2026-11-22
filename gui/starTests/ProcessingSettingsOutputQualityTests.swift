import XCTest
import StarCore
@testable import Star

/// The output JPEG quality row of the processing settings (task #847): it starts at the input's quality,
/// the user can override it, and TIFF sequences do not get one.
@MainActor
final class ProcessingSettingsOutputQualityTests: XCTestCase {

    private func model(source: Int?, override: Int? = nil) -> (ImageSequenceViewModel, ConfigManager) {
        var config = Config()
        config.useGPUForMerge = false
        config.outputJPEGQuality = override
        let manager = ConfigManager(configFilename: NSTemporaryDirectory() + "c847-\(UUID().uuidString).json",
                                    config: config)
        let model = ImageSequenceViewModel(viewModel: nil, configManager: manager, trashLevel: 0.5, smallTrashMax: 0)
        model.sourceJPEGQuality = source
        return (model, manager)
    }

    func testSliderStartsAtTheInputQualityForJPEG() {
        let (m, _) = model(source: 83)
        XCTAssertTrue(m.showsOutputQuality)
        XCTAssertEqual(m.outputQualityValue, 83)
        XCTAssertTrue(m.outputQualityMatchesInput)
    }

    func testRowIsHiddenForTIFF() {
        let (m, _) = model(source: nil)
        XCTAssertFalse(m.showsOutputQuality)
    }

    func testMovingTheSliderOverridesAndResetClears() {
        let (m, manager) = model(source: 83)
        m.setOutputQuality(60)
        XCTAssertEqual(m.outputQualityValue, 60)
        XCTAssertFalse(m.outputQualityMatchesInput)
        XCTAssertEqual(manager.config().outputJPEGQuality, 60)

        m.resetOutputQuality()
        XCTAssertEqual(m.outputQualityValue, 83)
        XCTAssertNil(manager.config().outputJPEGQuality)
    }

    func testLandingOnTheInputQualityIsNoOverride() {
        let (m, manager) = model(source: 83, override: 60)
        XCTAssertEqual(m.outputQualityValue, 60)
        m.setOutputQuality(83)
        XCTAssertNil(m.outputJPEGQuality)
        XCTAssertNil(manager.config().outputJPEGQuality)
    }

    func testTheOverrideReachesTheFramesLive() {
        let (m, _) = model(source: 83)
        let box = OutputJPEGQualityOverride(nil)
        m.outputQualityOverride = box
        m.setOutputQuality(50)
        XCTAssertEqual(box.value, 50)
        m.resetOutputQuality()
        XCTAssertNil(box.value)
    }
}
