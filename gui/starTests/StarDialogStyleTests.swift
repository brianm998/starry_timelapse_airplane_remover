import XCTest
import AVFoundation
import SwiftUI
import Observation
import StarCore
import StarCppBridge
// The app target is named `Star`, not `star` — the lowercase name belongs to the .xcodeproj
// and to this test target.  TEST_HOST points at Star.app, so this is what links.
@testable import Star



/// The gui's plain sheets and popovers are drawn in the star dialog style (the grey dialog ground) whatever appearance the window
/// they open over has, so they do not depend on the app-wide dark appearance. The window is forced to `.aqua`, the light appearance,
/// to prove it. A corner pixel of each view is sampled: a styled view fills its whole bounds with the dialog grey, an unstyled one
/// shows the light window background.
@MainActor
final class StarDialogStyleTests: XCTestCase {

    private func settle(_ seconds: TimeInterval = 0.4) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    /// Hosts `view` in a window forced to the light appearance and returns the RGB of a pixel just inside its top-left corner.
    private func cornerColor<V: View>(of view: V) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let host = NSHostingView(rootView: view)
        let window = OffDisplayWindow(contentRect: OffDisplayWindow.farAway,
                                      styleMask: [.titled, .closable],
                                      backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false  // ARC owns it; close() would release it a second time
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        window.setContentSize(host.fittingSize)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        settle()
        host.display()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            XCTFail("could not make a bitmap of the hosted view")
            return (0, 0, 0)
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        OffDisplayWindow.assertNothingShowsOnADisplay()
        guard let color = rep.colorAt(x: 24, y: 24)?.usingColorSpace(.sRGB) else {
            XCTFail("the corner pixel has no sRGB value")
            return (0, 0, 0)
        }
        XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.01, "the view was not drawn into the bitmap")
        return (color.redComponent, color.greenComponent, color.blueComponent)
    }

    /// The dialog ground is white 0.12, the desktop client's `StarColors.prefsCard`. The bitmap a hosted view is cached into is in
    /// the display's colour space, which on some Macs reads a plain sRGB 0.12 back as 0.188, so the expectation is a plain
    /// sRGB 0.12 swatch put through the same pipeline rather than the absolute number.
    private func assertDialogGround(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat), _ name: String,
                                    file: StaticString = #filePath, line: UInt = #line) {
        let expected = cornerColor(of: Color(.sRGB, white: 0.12, opacity: 1).frame(width: 300, height: 300))
        for (channel, value, want) in [("red", rgb.r, expected.r), ("green", rgb.g, expected.g), ("blue", rgb.b, expected.b)] {
            XCTAssertLessThan(abs(value - want), 0.03,
                              "\(name): \(channel) of the corner is \(value), not the dialog grey \(want)",
                              file: file, line: line)
        }
    }

    func testSheetsDrawOnTheStarDialogGround() {
        assertDialogGround(cornerColor(of: ToolHelpView(isPresented: .constant(true))), "ToolHelpView", file: #filePath, line: #line)
        // Width as the alignment overlay gives it, so the text wraps and the window is not sized to one long line.
        assertDialogGround(cornerColor(of: AlignmentInfoContent(cameraMoving: false, close: {})
                                        .frame(width: 540, alignment: .topLeading)),
                           "AlignmentInfoContent", file: #filePath, line: #line)
    }
}
