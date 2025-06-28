import SwiftUI
import logging


/// A SwiftUI wrapper for `CursorHostingView`
struct CursorView<Content: View>: NSViewRepresentable {
    let cursor: NSCursor
    let content: Content

    init(cursor: NSCursor, @ViewBuilder content: () -> Content) {
        self.cursor = cursor
        self.content = content()
    }

    func makeNSView(context: Context) -> CursorHostingView<Content> {
        CursorHostingView(rootView: content, cursor: cursor)
    }

    func updateNSView(_ nsView: CursorHostingView<Content>, context: Context) {
        nsView.rootView = content
        nsView.cursor = cursor
    }
}


/// A hosting view that installs a custom cursor over its entire area.
final class CursorHostingView<Content: View>: NSHostingView<Content> {
    /// The cursor to use. You can change this at any time and it will re-install.
    var cursor: NSCursor {
        didSet {
            // Re-draw the cursor rects whenever it changes
            window?.invalidateCursorRects(for: self)
        }
    }
    
    init(rootView: Content, cursor: NSCursor) {
        self.cursor = cursor
        super.init(rootView: rootView)
    }
    
    @objc required dynamic init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
  
    @MainActor @preconcurrency required init(rootView: Content) {
        fatalError("init(rootView:) has not been implemented")
    }
  
    override func resetCursorRects() {
        super.resetCursorRects()
        // Clear any old rects…
        discardCursorRects()
        // …then install our cursor over our full bounds
        addCursorRect(bounds, cursor: cursor)
    }
    
    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        // If the view resized, make sure our cursor rect covers the new area
        window?.invalidateCursorRects(for: self)
    }
}

// 1) A ViewModifier that can own @EnvironmentObject
struct CursorModifier: ViewModifier {
    @Environment(ViewModel.self) var viewModel: ViewModel
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content
          .onHover { inside in
              if inside {
                  viewModel.pushCursor(cursor)
              } else {
                  viewModel.popCursor()
              }
          }
    }
}

// 2) A nice View extension to apply it
extension View {
    /// Installs a hover‐driven cursor change using your ViewModel in the environment.
    func cursor(_ cursor: NSCursor) -> some View {
        self.modifier(CursorModifier(cursor: cursor))
    }
}

extension NSCursor {
/*
    public class var paint: NSCursor {
        NSCursor(image: NSImage(named: "paintbrush_icon")!,
                 hotSpot: .init(x: 8, y: 24))
    }
    public class var eraser: NSCursor {
        NSCursor(image: NSImage(named: "eraser_icon")!,
                 hotSpot: .init(x: 7, y: 27))
    }
*/
    public class var undo: NSCursor {
        NSCursor(image: NSImage(named: "undo_icon")!,
                 hotSpot: .init(x: 3, y: 12))
    }

    public class var razor: NSCursor {
        NSCursor(image: NSImage(named: "razor_icon")!,
                 hotSpot: .init(x: 3, y: 23))
    }

    public class var remove: NSCursor {
        NSCursor(image: NSImage(named: "remove_icon")!,
                 hotSpot: .init(x: 15, y: 15))
    }

    public class var keep: NSCursor {
        NSCursor(image: NSImage(named: "keep_icon")!,
                 hotSpot: .init(x: 15, y: 15))
    }

    public class var removeCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "remove_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var removePointing: NSCursor {
        NSCursor(image: NSImage(named: "remove_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

    public class var keepCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "keep_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var keepPointing: NSCursor {
        NSCursor(image: NSImage(named: "keep_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

    public class var razorCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "razor_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var razorPointing: NSCursor {
        NSCursor(image: NSImage(named: "razor_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

    public class var shovelCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "shovel_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var shovelPointing: NSCursor {
        NSCursor(image: NSImage(named: "shovel_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

    public class var extractTrashCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "extract_trash_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var extractTrashPointing: NSCursor {
        NSCursor(image: NSImage(named: "extract_trash_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

    public class var deleteTrashCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "delete_trash_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var deleteTrashPointing: NSCursor {
        NSCursor(image: NSImage(named: "delete_trash_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

    public class var multiCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "multi_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var multiPointing: NSCursor {
        NSCursor(image: NSImage(named: "multi_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

    public class var infoCrosshair: NSCursor {
        NSCursor(image: NSImage(named: "info_crosshair")!,
                 hotSpot: .init(x: 45/3, y: 45/3))
    }

    public class var infoPointing: NSCursor {
        NSCursor(image: NSImage(named: "info_pointing")!,
                 hotSpot: .init(x: 27/3, y: 17/3))
    }

}
