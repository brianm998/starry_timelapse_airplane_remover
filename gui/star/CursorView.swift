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
