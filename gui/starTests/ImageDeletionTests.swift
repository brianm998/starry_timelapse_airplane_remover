import XCTest
import StarCore
@testable import Star

/// A deleted image type is no longer offered for its frame (task #838).
@MainActor
final class ImageDeletionTests: XCTestCase {

    /// A sequence model with `count` frames and no images on disk: only the settings half of opening one.
    private func sequence(frames count: Int) -> ImageSequenceViewModel {
        var config = Config()
        config.useGPUForMerge = false
        let manager = ConfigManager(configFilename: NSTemporaryDirectory() + "c838-\(UUID().uuidString).json",
                                    config: config)
        let model = ImageSequenceViewModel(viewModel: nil, configManager: manager, trashLevel: 0.5, smallTrashMax: 0)
        model.set(numberOfFrames: count)
        return model
    }

    func testDeletingFinalUpdatesExistingImages() {
        let model = sequence(frames: 2)
        model.frames[0].existingImages = [.original, .final]
        model.frames[1].existingImages = [.original, .final]
        XCTAssertTrue(model.availableModes.contains(.final))

        // a preview-size deletion does not mean the full image is gone
        model.imageDeleted(frameIndex: 0, type: .final, size: .preview)
        XCTAssertEqual(model.frames[0].existingImages, [.original, .final])

        model.imageDeleted(frameIndex: 0, type: .final, size: .original)
        XCTAssertEqual(model.frames[0].existingImages, [.original])
        XCTAssertEqual(model.frames[1].existingImages, [.original, .final])
        XCTAssertTrue(model.availableModes.contains(.final), "frame 1 still has its final image")

        model.imageDeleted(frameIndex: 1, type: .final, size: .original)
        XCTAssertEqual(model.frames[1].existingImages, [.original])
        XCTAssertFalse(model.availableModes.contains(.final), "no frame has a final image any more")
        XCTAssertTrue(model.availableModes.contains(.original))
    }

    func testDeletingAnOutOfRangeFrameIsIgnored() {
        let model = sequence(frames: 1)
        model.frames[0].existingImages = [.original, .final]
        model.imageDeleted(frameIndex: 5, type: .final, size: .original)
        model.imageDeleted(frameIndex: -1, type: .final, size: .original)
        XCTAssertEqual(model.frames[0].existingImages, [.original, .final])
    }

    func testViewModeFallsBackToOriginal() {
        let model = sequence(frames: 2)
        model.frames[0].existingImages = [.original, .final]
        model.frames[1].existingImages = [.original, .final]
        model.currentIndex = 1
        model.frameViewMode = .final

        // another frame losing its image leaves the current one's mode alone
        model.imageDeleted(frameIndex: 0, type: .final, size: .original)
        XCTAssertEqual(model.frameViewMode, .final)

        model.imageDeleted(frameIndex: 1, type: .final, size: .original)
        XCTAssertEqual(model.frameViewMode, .original)
    }

    func testViewModeHelper() {
        XCTAssertEqual(ImageSequenceViewModel.viewMode(.final, whenFrameHas: { $0 == .final }), .final)
        XCTAssertEqual(ImageSequenceViewModel.viewMode(.final, whenFrameHas: { _ in false }), .original)
        XCTAssertEqual(ImageSequenceViewModel.viewMode(.original, whenFrameHas: { _ in false }), .original)
    }
}
