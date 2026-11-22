import XCTest
import StarCore
@testable import Star

/// A deleted image type is no longer offered for its frame (task #838).
@MainActor
final class ImageDeletionTests: XCTestCase {

    private func frameView() -> FrameViewModel {
        FrameViewModel(ConfigManager(configFilename: NSTemporaryDirectory() + "c838.json", config: Config()), 3)
    }

    func testDeletingFinalUpdatesExistingImages() {
        let frame = frameView()
        frame.existingImages = [.original, .final]
        var removedReports = 0
        frame.onImageAvailabilityChange = { _, removed in if removed { removedReports += 1 } }

        // what `imageDeleted` does for a full-size deletion
        frame.existingImages.remove(.final)

        XCTAssertFalse(frame.existingImages.contains(.final))
        XCTAssertTrue(frame.existingImages.contains(.original))
        XCTAssertEqual(removedReports, 1, "the sequence recomputes availableModes on removal")
    }

    func testViewModeFallsBackToOriginal() {
        let frame = frameView()
        frame.existingImages = [.original, .final]
        XCTAssertEqual(ImageSequenceViewModel.viewMode(.final, whenFrameHas: { frame.hasImage(type: $0) }), .final)
        frame.existingImages.remove(.final)
        XCTAssertEqual(ImageSequenceViewModel.viewMode(.final, whenFrameHas: { frame.hasImage(type: $0) }), .original)
    }
}
