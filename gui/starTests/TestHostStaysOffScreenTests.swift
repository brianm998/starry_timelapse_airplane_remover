import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// XCTest launches the app to host these tests on whatever machine runs them, often while someone is using it or while its display is
/// asleep. The host must never show up there.
final class TestHostStaysOffScreenTests: XCTestCase {
    @MainActor func testTheHostIsBackgroundOnlyAndShowsNoWindow() {
        XCTAssertEqual(NSApp.activationPolicy(), .prohibited)
        XCTAssertEqual(NSApp.windows.filter(\.isVisible).map(\.title), [])
    }
}
