import Foundation
import SwiftUI
import AppKit

@MainActor public var _window: NSWindow! // XXX don't need this anymore

@MainActor public var _cursor_frame: CGRect?

class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        let viewModel = ViewModel() // XXX how to move this into the content view ?
        
        _window = StarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.miniaturizable, .closable, .resizable, .titled],
            backing: .buffered, defer: false)
        _window.center()
        _window.title = "FUCK"
        _window.contentView = StarHostingView(rootView: ContentView().environment(ViewModel()))
        _window.makeKeyAndOrderFront(nil)
    }
}

final class StarHostingView<Content>: NSHostingView<Content> where Content : View{

    var cursor: NSCursor?
    
    public required init(rootView content: Content) {
        super.init(rootView: content)
    } 

    override func viewDidMoveToWindow() {
        print("FUCKING MOVED TO WINDOW")

        //self.addTrackingArea(NSTrackingArea(rect: .zero,
        self.addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 64, height: 48),
                                            options: [
                                              .activeInKeyWindow,
                                              //.activeInActiveApp,
                                              //.activeWhenFirstResponder, // only changes on click
                                              //.activeAlways,
                                              .assumeInside,
                                              .inVisibleRect,
//                                              .cursorUpdate,
                                              .mouseMoved], owner: self))
    }

    
    override func mouseMoved(with event: NSEvent) {
//        cursorUpdate(with: event)
//    }
    
//    override func cursorUpdate(with event: NSEvent) {
//        print("cursorUpdate(with: \(event) \(event.locationInWindow))")
        /*
         next steps:

         * better handle smaller amounts of the screen
         * read size of frame display with geometry reader
         - figure out menu items (they're gone now)
         */

        // XXX crude, but it works well to always make the cursor the given value when
        // in the window

        if let _cursor_frame,
           let windowRect = _window.contentView?.frame
        {
            let location = event.locationInWindow // XXX origin is in lower left corner

            let x = location.x
            var y = location.y
            y = windowRect.height - y // put origin in top left corner

            if x >= _cursor_frame.minX,
               x < _cursor_frame.minX + _cursor_frame.width,
               y >= _cursor_frame.minY,
               y < _cursor_frame.minY + _cursor_frame.height
            {
                if let cursor {
                    cursor.pop()
                }
                let newCursor: NSCursor = .openHand
                newCursor.push()
                cursor = newCursor
            } else if let cursor {
                cursor.pop()
            }
        }
    }
    
    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class StarWindow: NSWindow {
    override func resetCursorRects() {
        print("FUCK resetCursorRects")
    }

    override func invalidateCursorRects(for view: NSView) {
        print("FUCK invalidateCursorRects(for: \(view)")
        //self.disableCursorRects()
        self.resetCursorRects()
    }
/*
    override func discardCursorRects() {
        print("FUCK discardCursorRects")
    }

    override func enableCursorRects() {
        print("FUCK enableCursorRects")
    }

    override func disableCursorRects() {
        print("FUCK disableCursorRects")
    }
*/
}
