import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star


extension StarWarning.Kind {
    /// `title` is localized, so a test asserting on it has to ask for it the same way the view
    /// does rather than hard-coding English.
    var titleForTest: String {
        StarWarning(kind: self, severity: .warning, message: "").title
    }
}


/// A real window for a test that needs AppKit to lay out or present on one. Presenting a SwiftUI alert orders its window and the alert
/// on screen even in a background-only app, and centers the window on a display as it does, so every way of moving this one keeps its
/// origin beyond all the displays (its size still changes, which is what the tests measure). The alert is centered on this window, so
/// it stays out there with it, where neither can be seen or light a display up.
final class OffDisplayWindow: NSWindow {
    static let farAway = NSRect(x: -30000, y: -30000, width: 900, height: 600)

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override func center() {}
    override func setFrameOrigin(_ point: NSPoint) { super.setFrameOrigin(Self.farAway.origin) }
    override func setFrameTopLeftPoint(_ point: NSPoint) { super.setFrameOrigin(Self.farAway.origin) }
    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(NSRect(origin: Self.farAway.origin, size: frameRect.size), display: flag)
    }
    override func setFrame(_ frameRect: NSRect, display displayFlag: Bool, animate animateFlag: Bool) {
        super.setFrame(NSRect(origin: Self.farAway.origin, size: frameRect.size), display: displayFlag, animate: animateFlag)
    }

    @MainActor static func assertNothingShowsOnADisplay(file: StaticString = #filePath, line: UInt = #line) {
        let shown = NSApp.windows.filter { window in
            window.isVisible && NSScreen.screens.contains { $0.frame.intersects(window.frame) }
        }
        XCTAssertEqual(shown.map(\.frame), [], "a test window is showing on a display", file: file, line: line)
    }
}
