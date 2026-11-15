import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


final class LoadingRingArtTests: XCTestCase {
    func testLoadingRingArtSize() {
        // The mac ring at its 500 pt frame: stroke 80, so outer 580 and inner 420; 60% is 252, capped at 120.
        XCTAssertEqual(loadingRingArtSize(outerDiameter: 580, stroke: 80), 120)
        // A small ring scales: inner 100 -> 60.
        XCTAssertEqual(loadingRingArtSize(outerDiameter: 260, stroke: 80), 60, accuracy: 0.001)
        // The desktop's 160/10 ring: inner 140 -> 84.
        XCTAssertEqual(loadingRingArtSize(outerDiameter: 160, stroke: 10), 84, accuracy: 0.001)
        // No inner room, no robot.
        XCTAssertEqual(loadingRingArtSize(outerDiameter: 160, stroke: 80), 0)
        XCTAssertEqual(loadingRingArtSize(outerDiameter: 100, stroke: 80), 0)
    }
}
