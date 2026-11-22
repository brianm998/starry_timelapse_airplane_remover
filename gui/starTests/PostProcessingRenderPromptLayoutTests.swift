import XCTest
import SwiftUI
import StarCore
@testable import Star

/// The "Processing complete" dialog shows all its content: wide enough for the art and both pictures, all three buttons inside.
@MainActor
final class PostProcessingRenderPromptLayoutTests: XCTestCase {
    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let b = view as? NSButton { found.append(b) }
        for sub in view.subviews { found += buttons(in: sub) }
        return found
    }

    private func png(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString)-\(name).png")
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 3, bitsPerSample: 8, samplesPerPixel: 4,
                                   hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }

    /// Hosts the layout off screen; returns its fitting size and the frames of its buttons in the host's coordinates.
    private func host(_ pictures: PostProcessingRenderPromptLayout.Pictures?) -> (fitting: CGSize, bounds: CGRect, buttons: [CGRect]) {
        let view = PostProcessingRenderPromptLayout(pictures: pictures, cancel: {}, previewFirst: {}, yes: {})
        let host = NSHostingView(rootView: view)
        let window = OffDisplayWindow(contentRect: OffDisplayWindow.farAway, styleMask: [.titled, .closable],
                                      backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.contentView = host
        let fitting = host.fittingSize
        window.setContentSize(fitting)
        window.orderFront(nil)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        host.layoutSubtreeIfNeeded()
        let frames = buttons(in: host).map { host.convert($0.bounds, from: $0) }
        OffDisplayWindow.assertNothingShowsOnADisplay()
        return (fitting, host.bounds, frames)
    }

    func testDialogFitsBothPictures() throws {
        let pair = PostProcessingRenderPromptLayout.Pictures(before: try png("before"), after: try png("after"))
        let r = host(pair)
        let L = PostProcessingRenderPromptLayout.self
        let needed = L.padding * 2 + L.artWidth + L.columnSpacing + L.pictureSize.width * 2 + L.arrowGap * 2
        XCTAssertGreaterThanOrEqual(r.fitting.width, needed)
        XCTAssertGreaterThanOrEqual(r.fitting.width, 685)  // 20+116+16+240+8+17+8+240+20
        XCTAssertGreaterThanOrEqual(r.buttons.count, 3)
        for f in r.buttons {
            XCTAssertTrue(r.bounds.insetBy(dx: -0.5, dy: -0.5).contains(f), "button \(f) outside \(r.bounds)")
        }
    }

    func testDialogWithoutPicturesShowsAllButtons() {
        let r = host(nil)
        XCTAssertGreaterThanOrEqual(r.fitting.width, 380)
        XCTAssertLessThan(r.fitting.width, 600)
        XCTAssertGreaterThanOrEqual(r.buttons.count, 3)
        for f in r.buttons {
            XCTAssertTrue(r.bounds.insetBy(dx: -0.5, dy: -0.5).contains(f), "button \(f) outside \(r.bounds)")
        }
    }
}
