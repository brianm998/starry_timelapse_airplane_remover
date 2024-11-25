import Foundation
import SwiftUI
import AppKit

@MainActor public var _window: NSWindow! // XXX don't need this anymore
@MainActor fileprivate var _cursor_frames: [String:CGRect] = [:]
@MainActor fileprivate var _cursors: [String:NSCursor] = [:]

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

     //   let viewModel = ViewModel()
        
        _window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 960),
            styleMask: [.miniaturizable, .closable, .resizable, .titled, .fullSizeContentView],
            backing: .buffered, defer: false)
        _window.center()
        _window.title = "FUCK"
        _window.disableCursorRects()
  //      _window.contentView = StarHostingView(rootView: ContentView().environment(ViewModel()))
        _window.contentView = NSHostingView(rootView: ContentView().environment(ViewModel()))
        _window.makeKeyAndOrderFront(nil)
    }
}

final class StarHostingView<Content>: NSHostingView<Content> where Content : View {

    var cursor: NSCursor?
    
    public required init(rootView content: Content) {
        super.init(rootView: content)
    } 

    override func viewDidMoveToWindow() {
        self.addTrackingArea(NSTrackingArea(rect: NSRect(x: 0, y: 0, width: 200, height: 200),//.zero,
        //self.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: [
                                              //.activeInKeyWindow,
                                              .activeInActiveApp,
                                              .cursorUpdate,
//                                              .assumeInside,
//                                              .inVisibleRect,
//                                              .mouseEnteredAndExited,
//                                              .enabledDuringMouseDrag,
                                            //  .mouseMoved
                                            ], owner: self))
    }

    // catch mouse click?

    override func mouseUp(with event: NSEvent) {
        //print("FUCKING mouseUp")
        super.mouseUp(with: event)
        handle(event, withLogging: true)
        _window.enableCursorRects()
    }
    
    override func mouseDown(with event: NSEvent) {
        //print("FUCKING mouseDown")
        super.mouseDown(with: event)
        _window.disableCursorRects()
        handle(event, withLogging: true)
    }
    
    override func otherMouseUp(with event: NSEvent) {
        //print("FUCKING otherMouseUp")
        super.otherMouseUp(with: event)
        handle(event, withLogging: true)
    }
    
    override func otherMouseDown(with event: NSEvent) {
        //print("FUCKING otherMouseDown")
        super.otherMouseDown(with: event)
        handle(event, withLogging: true)
    }
    
    override func rightMouseUp(with event: NSEvent) {
        //print("FUCKING rightMouseUp")
        super.rightMouseUp(with: event)
        Task {
            handle(event, withLogging: true)
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        //print("FUCKING rightMouseDown")
        super.rightMouseDown(with: event)
        handle(event, withLogging: true)
    }
    
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
//        handle(event)
    }

    override func cursorUpdate(with event: NSEvent) {
        print("cursorUpdate(with: \(event) \(event.locationInWindow))")
        super.cursorUpdate(with: event)
        handle(event)
    }

    private func handle_DOH(_ event: NSEvent, withLogging fuck: Bool = false) {
        let newCursor: NSCursor = .resizeLeft
        NSApp.windows.forEach { $0.disableCursorRects() } 
        newCursor.push()
    }

    override func resetCursorRects() {
        print("FUCKING resetCursorRects")
        addCursorRect(bounds, cursor: .pointingHand)
    }
    
    private func handle(_ event: NSEvent, withLogging fuck: Bool = false) {

//        if true  { return }
        
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
                        NSApp.windows.forEach { $0.disableCursorRects() } 
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
                NSApp.windows.forEach { $0.enableCursorRects() } 
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



extension View {
    func cursor(_ cursor: NSCursor, tag: String) -> some View {
        Group {
            background(
              Color.clear
                .onGeometryChange(for: CGRect.self) { proxy in
                    proxy.frame(in: .global)
                } action: { frame in
                    _cursor_frames[tag] = frame
                }
                .onAppear {
                    _cursors[tag] = cursor
                }
            )
        }
          .onDisappear {
              _cursor_frames.removeValue(forKey: tag)
          }
    }
}


// XXX WTF

extension View {
    func trackingMouse(onCursorUpdate: @escaping (NSPoint) -> Void) -> some View {
        TrackinAreaView(onCursorUpdate: onCursorUpdate) { self }
    }
}

struct TrackinAreaView<Content>: View where Content : View {
    let onCursorUpdate: (NSPoint) -> Void
    let content: () -> Content
    
    init(onCursorUpdate: @escaping (NSPoint) -> Void, @ViewBuilder content: @escaping () -> Content) {
        self.onCursorUpdate = onCursorUpdate
        self.content = content
    }
    
    var body: some View {
        TrackingAreaRepresentable(onCursorUpdate: onCursorUpdate, content: self.content())
    }
}

struct TrackingAreaRepresentable<Content>: NSViewRepresentable where Content: View {
    let onCursorUpdate: (NSPoint) -> Void
    let content: Content
    
    func makeNSView(context: Context) -> NSHostingView<Content> {
        return TrackingNSHostingView(onCursorUpdate: onCursorUpdate, rootView: self.content)
    }
    
    func updateNSView(_ nsView: NSHostingView<Content>, context: Context) {
    }
}

class TrackingNSHostingView<Content>: NSHostingView<Content> where Content : View {
    let onCursorUpdate: (NSPoint) -> Void
    
    init(onCursorUpdate: @escaping (NSPoint) -> Void, rootView: Content) {
        self.onCursorUpdate = onCursorUpdate
        
        super.init(rootView: rootView)
        
        setupTrackingArea()
    }
    
    required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }
    
    @objc required dynamic init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func setupTrackingArea() {
        let options: NSTrackingArea.Options =
          [
            .activeInActiveApp,
            .cursorUpdate,

//            .mouseMoved,
//            .activeAlways,
//            .inVisibleRect,
          ]
        
        self.addTrackingArea(NSTrackingArea(rect: .zero,
                                            options: options,
                                            owner: self,
                                            userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        self.onCursorUpdate(self.convert(event.locationInWindow, from: nil))
    }

    override func cursorUpdate(with event: NSEvent) {
        self.onCursorUpdate(self.convert(event.locationInWindow, from: nil))
    }
}



/// FUCK AGAIN


extension View {
    public func cursor3(_ cursor: NSCursor) -> some View {
        if #available(macOS 13.0, *) {
            return self.onContinuousHover { phase in
                switch phase {
                case .active(_):
//                    guard NSCursor.current != cursor else { return }
                    cursor.push()
                case .ended:
                    NSCursor.pop()
                }
            }
        } else {
            return self.onHover { inside in
                if inside {
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
        }
    }
}
