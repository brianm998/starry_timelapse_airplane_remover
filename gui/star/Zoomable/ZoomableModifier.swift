//
//  ZoomableModifier.swift
//  ZoomableView
//
//  Created by jasu on 2022/01/26.
//  Copyright (c) 2022 jasu All rights reserved.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is furnished
//  to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED,
//  INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A
//  PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
//  HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF
//  CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE
//  OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

import SwiftUI
import logging

public struct ZoomableModifier: ViewModifier {

    private var min: CGFloat
    private var max: CGFloat

    @GestureState private var gestureScale: CGFloat = 1.0
    @GestureState private var dragDelta: CGSize = .zero

    @Binding private var currentScale: CGFloat
    @State private var offset: CGSize = .zero

    public init(min: CGFloat = 1.0,
                max: CGFloat = 3.0,
                currentScale: Binding<CGFloat>) {
        self.min = min
        self.max = max
        _currentScale = currentScale
    }

    private var totalScale: CGFloat {
        Swift.max(min, Swift.min(max, currentScale * gestureScale))
    }

    public func body(content: Content) -> some View {
        GeometryReader { geo in
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)

            // Canvas centers the content at rest and provides a clipping rect
            ZStack {

                content
                  .scaleEffect(totalScale, anchor: .center)
                  .offset(x: offset.width + dragDelta.width,
                          y: offset.height + dragDelta.height)
                  .compositingGroup() // ensure transform happens before clipping

//                TwoFingerDragOverlay(offset: $offset)                 
//                  .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
            .contentShape(Rectangle()) // full area is hittable for gestures
            .clipped(antialiased: true) // keep within bounds
            .simultaneousGesture(magnificationGesture())
            .simultaneousGesture(doubleTapGesture(in: geo, center: center))
            .animation(.easeInOut, value: totalScale)
            .animation(.easeInOut, value: offset)
        }
    }

    // MARK: Gestures
 
    private func magnificationGesture() -> some Gesture {
        MagnificationGesture()
            .updating($gestureScale) { value, state, _ in
                state = value
            }
            .onEnded { value in
                let new = currentScale * value
                currentScale = Swift.max(min, Swift.min(max, new))
                // macOS MagnificationGesture has no pinch location; zooms around view center.
            }
    }

    private var dragGesture: some Gesture {
        DragGesture()
          .updating($dragDelta) { value, state, _ in
              Log.d("FUCK")
                state = value.translation
            }
            .onEnded { value in
                offset.width += value.translation.width
                offset.height += value.translation.height
            }
    }

    /// Double-tap zoom that keeps the tapped point fixed (anchor: .center math).
    private func doubleTapGesture(in geo: GeometryProxy, center: CGPoint) -> some Gesture {
        if #available(macOS 13, iOS 16, *) {
            return SpatialTapGesture(count: 2).onEnded { value in
                let p = value.location         // local (container) coords
                let s = totalScale
                let target = (abs(s - min) < 0.001) ? max : min
                let ratio = target / Swift.max(s, 0.0001)

                // With anchor .center, keep p fixed:
                // newOffset = (p - center) - (p - center - offset) * (s'/s)
                let rel = CGPoint(x: p.x - center.x, y: p.y - center.y)
                let newOffset = CGSize(
                    width: rel.x - (rel.x - offset.width) * ratio,
                    height: rel.y - (rel.y - offset.height) * ratio
                )

                withAnimation(.easeInOut) {
                    currentScale = target
                    offset = target == min ? .zero : newOffset
                }
            }
        } else {
            return TapGesture(count: 2).onEnded {
                withAnimation(.easeInOut) {
                    if totalScale > min {
                        currentScale = min
                        offset = .zero
                    } else {
                        currentScale = max
                    }
                }
            }
        }
    }
}

// MARK: - Convenience

public extension View {
    func zoomable(min: CGFloat = 1.0,
                  max: CGFloat = 3.0,
                  currentScale: Binding<CGFloat>) -> some View {
        modifier(ZoomableModifier(min: min, max: max, currentScale: currentScale))
    }
}



struct TwoFingerDragOverlay: NSViewRepresentable {
    @Binding var offset: CGSize

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        let recognizer = NSPanGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.pan(_:)))
        recognizer.allowedTouchTypes = [.direct] // trackpad
        view.addGestureRecognizer(recognizer)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(offset: $offset) }

    class Coordinator: NSObject {
        @Binding var offset: CGSize
        init(offset: Binding<CGSize>) { _offset = offset }

      @MainActor @objc func pan(_ sender: NSPanGestureRecognizer) {
          if sender.numberOfTouchesRequired != 2 { return } // only two fingers
            let translation = sender.translation(in: sender.view)
            offset.width += translation.x
            offset.height += translation.y
            sender.setTranslation(.zero, in: sender.view)
        }
    }
}
