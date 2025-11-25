
import SwiftUI
import logging

// this is a broken POS from chatgpt that tried to use NSScrollView to allow
// for tapping into a scroll view for zoom properly.
// it is totatlly broken and chatgpt is full of crap

public struct OldZoomableModifier: ViewModifier {
    
    private enum ZoomState {
        case inactive
        case active(scale: CGFloat)
        
        var scale: CGFloat {
            switch self {
            case .active(let scale):
                return scale
            default: return 1.0
            }
        }
    }
    
    private var contentSize: CGSize
    private var min: CGFloat = 1.0
    private var max: CGFloat = 3.0
    private var showsIndicators: Bool = false
    
    @GestureState private var zoomState = ZoomState.inactive
    @Binding private var currentScale: CGFloat
    @State private var targetPoint: CGPoint? = nil
    @State private var tapXLocation: CGFloat
    @State private var tapYLocation: CGFloat
    @State private var scrollPosition: ScrollPosition? = nil
    
    /**
     Initializes an `OldZoomableModifier`
     - parameter contentSize : The content size of the views.
     - parameter min : The minimum value that can be zoom out.
     - parameter max : The maximum value that can be zoom in.
     - parameter showsIndicators : A value that indicates whether the scroll view displays the scrollable component of the content offset, in a way that’s suitable for the platform.
     */
    public init(contentSize: CGSize,
                min: CGFloat = 1.0,
                max: CGFloat = 3.0,
                showsIndicators: Bool = false,
                currentScale: Binding<CGFloat>)
    {
        _currentScale = currentScale
        self.contentSize = contentSize
        self.min = min
        self.max = max
        self.showsIndicators = showsIndicators
        self.tapXLocation = contentSize.width/2
        self.tapYLocation = contentSize.height/2
    }
    
    var scale: CGFloat {
        return currentScale * zoomState.scale
    }

    public var zoomGesture: some Gesture {
        MagnificationGesture()
            .updating($zoomState) { value, state, transaction in
                state = .active(scale: value)
            }
            .onEnded { value in
                var new = self.currentScale * value
                if new <= min { new = min }
                if new >= max { new = max }
                self.currentScale = new
            }
    }
    
    public func doubleTapGesture() -> some Gesture {
        if #available(macOS 13, *) {
            return SpatialTapGesture(count: 2).onEnded { event in

                let location = event.location
                let contentPoint = CGPoint(
                  x: location.x / currentScale,
                  y: location.y / currentScale
                )
                
                if scale <= min {
                    currentScale = max
                } else if scale >= max { currentScale = min } else {
                    currentScale = ((max - min) * 0.5 + min) < scale ? max : min
                }

                // 🔑 Tell CocoaScrollView to re-center on this point
                targetPoint = contentPoint
            }
        } else {
            return TapGesture(count: 2).onEnded { 
                if scale <= min { currentScale = max } else
                if scale >= max { currentScale = min } else {
                    currentScale = ((max - min) * 0.5 + min) < scale ? max : min
                }
            }
        }
    }

    public func body(content: Content) -> some View {
        HStack {
            Spacer()
            CocoaScrollView(zoomScale: $currentScale, targetPoint: $targetPoint) {
                //ScrollView([.horizontal, .vertical], showsIndicators: showsIndicators) {
                content
                  .frame(width: contentSize.width/* * scale*/,
                         height: contentSize.height/* * scale*/,
                         alignment: .center)
                  .border(.green)
                // .scaleEffect(scale, anchor: .center)
                //.gesture(doubleTapGesture) // disable zoom because it conflicts with other select gesture
                  .simultaneousGesture(doubleTapGesture()) // disable zoom because it conflicts with other select gesture
            }
              .border(.red)
              .onChange(of: currentScale) {
                  if let pos = scrollPosition {
                      // adjust so the visible center remains constant
                      // scrollPosition = CGPoint(
                      //   x: pos.x * currentScale,
                      //   y: pos.y * currentScale
                      // )
                  }
              }
              .simultaneousGesture(zoomGesture)
              .animation(.easeInOut, value: scale)
            Spacer()
        }
    }
}



// XXX maybe bad code

struct CocoaScrollViewFUCKED<Content: View>: NSViewRepresentable {
    @Binding var zoomScale: CGFloat
    @Binding var targetPoint: CGPoint?
    let content: () -> Content

    init(zoomScale: Binding<CGFloat>, targetPoint: Binding<CGPoint?>, @ViewBuilder content: @escaping () -> Content) {
        self._zoomScale = zoomScale
        self._targetPoint = targetPoint
        self.content = content
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false

        let hosting = NSHostingView(
          rootView: AnyView(
            content()
//              .frame(width: hosting.fittingSize.width, height: hosting.fittingSize.height)
//              .position(x: hostingSize.width/2, y: hostingSize.height/2)
              .scaleEffect(zoomScale, anchor: .topLeading)
          )
        )
        hosting.autoresizingMask = []

        let hostingSize = CGSize(
          width: max(
            hosting.fittingSize.width * zoomScale,
            scrollView.contentView.bounds.width
          ),
          height: max(
            hosting.fittingSize.height * zoomScale,
            scrollView.contentView.bounds.height
          )
        )
        hosting.setFrameSize(hostingSize)
        
        
        scrollView.documentView = hosting

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hosting = scrollView.documentView as? NSHostingView<AnyView> else { return }
        
        let hostingSize = CGSize(
          width: max(
            hosting.fittingSize.width * zoomScale,
            scrollView.contentView.bounds.width
          ),
          height: max(
            hosting.fittingSize.height * zoomScale,
            scrollView.contentView.bounds.height
          )
        )
        hosting.setFrameSize(hostingSize)
        
        // Wrap in AnyView so modifiers don't break the type
        hosting.rootView = AnyView(
          content()
            .frame(width: hosting.fittingSize.width, height: hosting.fittingSize.height)
            .position(x: hostingSize.width/2, y: hostingSize.height/2)
            .scaleEffect(zoomScale, anchor: .center)
        )

        let size = hosting.fittingSize
        hosting.setFrameSize(CGSize(width: size.width * zoomScale,
                                    height: size.height * zoomScale))

        if let target = targetPoint {
            let visibleSize = scrollView.contentView.bounds.size

            /*
            let scaledTarget = CGPoint(x: target.x * zoomScale, y: target.y * zoomScale)
            let newOrigin = CGPoint(
                x: max(scaledTarget.x - visibleSize.width / 2, 0),
                y: max(scaledTarget.y - visibleSize.height / 2, 0)
                )*/

            let contentSize = hosting.fittingSize
            let hostingSize = hosting.frame.size

            // Offset from top-left of hosting view to make target center
            let offsetX = (contentSize.width * zoomScale)/2 - hostingSize.width/2 + target.x * zoomScale
            let offsetY = (contentSize.height * zoomScale)/2 - hostingSize.height/2 + target.y * zoomScale

            let newOrigin = CGPoint(
              x: max(offsetX - visibleSize.width / 2, 0),
              y: max(offsetY - visibleSize.height / 2, 0)
            )
            
            scrollView.contentView.setBoundsOrigin(newOrigin)
            scrollView.reflectScrolledClipView(scrollView.contentView)

            DispatchQueue.main.async {
                self.targetPoint = nil
            }
        }
    }
}


/// even mroe really bad code


import SwiftUI
import SwiftUI

struct CocoaScrollView<Content: View>: NSViewRepresentable {
    @Binding var zoomScale: CGFloat
    @Binding var targetPoint: CGPoint?
    let content: () -> Content

    init(zoomScale: Binding<CGFloat>, targetPoint: Binding<CGPoint?>, @ViewBuilder content: @escaping () -> Content) {
        self._zoomScale = zoomScale
        self._targetPoint = targetPoint
        self.content = content
    }

    class Coordinator {
        var hosting: NSHostingView<Content>?
        var container: NSView?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.drawsBackground = false

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        let hosting = NSHostingView(rootView: content())
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)

        scrollView.documentView = container

        context.coordinator.hosting = hosting
        context.coordinator.container = container

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let hosting = context.coordinator.hosting,
              let container = context.coordinator.container else { return }

        let visibleSize = scrollView.contentView.bounds.size
        var naturalSize = hosting.fittingSize
        if naturalSize.width <= 0 || naturalSize.height <= 0 {
            naturalSize = CGSize(width: 1, height: 1)
        }

        // Compute initial zoom if invalid
        if zoomScale <= 0 {
            zoomScale = min(visibleSize.width / naturalSize.width,
                            visibleSize.height / naturalSize.height)
        }

        // Zoomed frame
        let zoomedSize = CGSize(width: naturalSize.width * zoomScale,
                                height: naturalSize.height * zoomScale)

        // Update hosting view frame (no scaleEffect)
        hosting.frame = CGRect(origin: .zero, size: zoomedSize)

        // Update content view in case SwiftUI state changed
        hosting.rootView = content()

        // Container size: at least scrollView size
        let containerWidth = max(zoomedSize.width, visibleSize.width)
        let containerHeight = max(zoomedSize.height, visibleSize.height)
        container.frame = CGRect(x: 0, y: 0, width: containerWidth, height: containerHeight)

        // Center content if smaller than container
        let offsetX = max((containerWidth - zoomedSize.width)/2, 0)
        let offsetY = max((containerHeight - zoomedSize.height)/2, 0)
        hosting.setFrameOrigin(CGPoint(x: offsetX, y: offsetY))

        // Scroll to target point if needed
        if let target = targetPoint {
            let scrollX = target.x * zoomScale - visibleSize.width / 2
            let scrollY = target.y * zoomScale - visibleSize.height / 2

            let maxX = max(containerWidth - visibleSize.width, 0)
            let maxY = max(containerHeight - visibleSize.height, 0)

            scrollView.contentView.setBoundsOrigin(CGPoint(
                x: min(max(scrollX, 0), maxX),
                y: min(max(scrollY, 0), maxY)
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)

            DispatchQueue.main.async { self.targetPoint = nil }
        }
    }
}
