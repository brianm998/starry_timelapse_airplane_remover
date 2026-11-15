import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// S6 of `plans/GUI_CLIENT_PARITY_PLAN.md`: a single image dropped on the start screen is a frame, not a video.
final class DroppedImageTests: XCTestCase {
    func testTheExtensionsOfAnImageSequence() {
        for name in ["a.jpg", "a.jpeg", "a.tif", "a.tiff", "a.png"] {
            XCTAssertTrue(InitialView.isImageFile("/x/\(name)"), name)
        }
    }

    func testCaseDoesNotMatter() {
        for name in ["IMG_0001.JPG", "IMG_0001.Jpeg", "scan.TIF", "scan.TIFF", "shot.PNG"] {
            XCTAssertTrue(InitialView.isImageFile("/x/\(name)"), name)
        }
    }

    func testAVideoIsNotAnImage() {
        for name in ["clip.mov", "clip.MP4", "clip", "jpg", ".jpg.mov"] {
            XCTAssertFalse(InitialView.isImageFile("/x/\(name)"), name)
        }
    }
}
