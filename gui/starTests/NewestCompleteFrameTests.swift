import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star
final class NewestCompleteFrameTests: XCTestCase {
    /// A2: the newest finished frame is the highest-numbered complete one; none when none is.
    func testNewestCompleteFrame() {
        XCTAssertNil(ImageSequenceViewModel.newest(of: [Int]()))
        XCTAssertEqual(ImageSequenceViewModel.newest(of: [4]), 4)
        XCTAssertEqual(ImageSequenceViewModel.newest(of: [2, 9, 5]), 9)
        // Frames finish out of order; the highest number still wins.
        XCTAssertEqual(ImageSequenceViewModel.newest(of: Set([7, 1, 3])), 7)
        XCTAssertEqual(ProcessingFrameThumbnail.minimumSwap, 2)
    }
}
