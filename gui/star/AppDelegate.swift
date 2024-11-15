import Foundation
import SwiftUI
import AppKit

@MainActor public var _window: NSWindow! // XXX don't need this anymore

@MainActor public var _cursor_frame: CGRect?

@MainActor public var _cursor_frames: [String:CGRect] = [:]
@MainActor public var _cursors: [String:NSCursor] = [:]

/*
 make a much more sophisticated mechanism, by which:

 we have lots of areas in priority order with different cursors

 views can register themselves with a background geomeotry reader that sets their frame
 in a main actor with some kind of string id (blob id?)

 make an easily reusable view modifier that does this, and also checks disappear

 allow frames to change their cursor at will

 handle zooming of frame better, maybe include getting arrows on zoomed in view?
 
 */


class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ aNotification: Notification) {

        let viewModel = ViewModel()
        
        _window = StarWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
            styleMask: [.miniaturizable, .closable, .resizable, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        _window.center()
        //_window.contentView?.isInFullScreenMode
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

        self.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [
                                              .activeInKeyWindow,
                                              .assumeInside,
                                              .inVisibleRect,
                                              .mouseEnteredAndExited,

                                              .enabledDuringMouseDrag,
//                                              .cursorUpdate,
                                              .mouseMoved], owner: self))
    }

    // catch mouse click?

    override func mouseUp(with event: NSEvent) {
        print("FUCKING mouseUp")
        super.mouseUp(with: event)
        handle(event, withLogging: true)
        _window.enableCursorRects()
    }
    
    override func mouseDown(with event: NSEvent) {
        print("FUCKING mouseDown")
        super.mouseDown(with: event)
        _window.disableCursorRects()
        handle(event, withLogging: true)
    }
    
    override func otherMouseUp(with event: NSEvent) {
        print("FUCKING otherMouseUp")
        super.otherMouseUp(with: event)
        handle(event, withLogging: true)
    }
    
    override func otherMouseDown(with event: NSEvent) {
        print("FUCKING otherMouseDown")
        super.otherMouseDown(with: event)
        handle(event, withLogging: true)
    }
    
    override func rightMouseUp(with event: NSEvent) {
        print("FUCKING rightMouseUp")
        super.rightMouseUp(with: event)
        Task {
            handle(event, withLogging: true)
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        print("FUCKING rightMouseDown")
        super.rightMouseDown(with: event)
        handle(event, withLogging: true)
    }
    
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        handle(event)
//        cursorUpdate(with: event)
//    }
    }

    private func handle(_ event: NSEvent, withLogging fuck: Bool = false) {
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

        if fuck { print("FUCK started") }  
        if let windowRect = _window.contentView?.frame {
            let location = event.locationInWindow // XXX origin is in lower left corner

            let x = location.x
            var y = location.y
            y = windowRect.height - y // put origin in top left corner

            var pushed = false

//            print("_cursor_frames \(_cursor_frames.count)")
            
            for (key, frame) in _cursor_frames { // XXX put these in order somehow
                if x >= frame.minX,
                   x < frame.minX + frame.width,
                   y >= frame.minY,
                   y < frame.minY + frame.height
                {
                    if let cursor { cursor.pop() }
                    if let newCursor: NSCursor = _cursors[key] {
                        newCursor.push()
                        cursor = newCursor
                        pushed = true
                        if fuck { print("FUCK Push") }
                    }
                    break
                }
            }

            if !pushed,
               let cursor
            {
                if fuck { print("FUCK Pop") }  
                cursor.pop()
            }            
        } else {
            if fuck {
                print("FUCK")
            }
        }
    }
    
    private func handle_OLD(_ event: NSEvent, withLogging fuck: Bool = false) {
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

        if fuck { print("FUCK started") }  
        
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
                if let cursor { cursor.pop() }
                let newCursor: NSCursor = .pointingHand
                newCursor.push()
                cursor = newCursor
                if fuck { print("FUCK Push") }
            } else if let cursor {
                if fuck { print("FUCK Pop") }  
                cursor.pop()
            }
        } else {
            if fuck {
                print("FUCK")
            }
        }
    }
    
    @MainActor @preconcurrency required dynamic init?(coder aDecoder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }
}

final class StarWindow: NSWindow {
/*
    override func resetCursorRects() {
        print("FUCK resetCursorRects")
    }

    override func invalidateCursorRects(for view: NSView) {
        print("FUCK invalidateCursorRects(for: \(view)")
        //self.disableCursorRects()
        self.resetCursorRects()
    }

    override func discardCursorRects() {
        print("FUCK discardCursorRects")
    }

    override func disableCursorRects() {
        print("FUCK disableCursorRects")
    }

    override func enableCursorRects() {
        print("FUCK enableCursorRects")
    }
*/
}
