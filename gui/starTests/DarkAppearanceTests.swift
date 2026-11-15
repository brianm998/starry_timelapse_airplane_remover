import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


/// The launch hook makes star's dark theme hold for everything the system draws: alerts, NSAlerts,
/// open panels and popovers follow `NSApp.appearance` when it is set, so a Light-mode Mac must not
/// bring up white dialogs in the dark app.
@MainActor
final class DarkAppearanceTests: XCTestCase {

    override func tearDown() {
        // The test host is shared; leave the appearance as the other tests found it.
        NSApplication.shared.appearance = nil
        super.tearDown()
    }

    func testTheAppForcesTheDarkAppearance() {
        AppDelegate().applicationWillFinishLaunching(
            Notification(name: NSApplication.willFinishLaunchingNotification))

        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        let alert = NSAlert()
        XCTAssertEqual(
            alert.window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]), .darkAqua,
            "a fresh NSAlert must be drawn dark")
    }

    func testHorizonPainterDiagrams() {
        XCTAssertEqual(horizonPainterDiagrams(isMoving: false),
                       [.paintBrush, .paintFill, .paintTouchUp])
        XCTAssertEqual(horizonPainterDiagrams(isMoving: true),
                       [.paintBrush, .paintFill, .paintTouchUp, .paintMoving])
    }
}
