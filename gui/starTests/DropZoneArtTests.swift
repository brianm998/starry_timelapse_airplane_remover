import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


final class DropZoneArtTests: XCTestCase {
    func testDropZoneArt() {
        XCTAssertEqual(FinderStyleDropZone.art(isTargeted: true), .dropHover)
        XCTAssertEqual(FinderStyleDropZone.art(isTargeted: false), .drop)
    }
}
