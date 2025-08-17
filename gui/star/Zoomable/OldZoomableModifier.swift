
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
    @State private var tapXLocation: CGFloat
    @State private var tapYLocation: CGFloat
    
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
    
    public func doubleTapGesture(_ scroller: ScrollViewProxy) -> some Gesture {
        if #available(macOS 13, *) {
            return SpatialTapGesture(count: 2).onEnded { event in
                tapXLocation = event.location.x / currentScale
                tapYLocation = event.location.y / currentScale
                print("FRICKING event location \(event.location) contentSize \(contentSize) currentScale \(currentScale) tap [\(tapXLocation), \(tapYLocation)]")
                if scale <= min { currentScale = max } else
                if scale >= max { currentScale = min } else {
                    currentScale = ((max - min) * 0.5 + min) < scale ? max : min
                }
                // XXX this doesn't work :(
//                scroller.scrollTo(42, anchor: .center)
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

    // https://stackoverflow.com/questions/70175558/swiftui-scrollviewreader-scrollto-not-correct-working/70177677#70177677
    private func setUnitPoint(_ index:Int) -> UnitPoint {
        switch true {
        case index % 10 < 2 && index / 10 < 2:
             return .topLeading
         case index % 10 >= 7 && index / 10 < 7:
            return .topTrailing
        case index % 10 < 2 && index / 10 >= 7:
            return .bottomLeading
        case index % 10 >= 2 && index / 10 >= 7:
            return .bottomTrailing
        default:
            return .center
        }
    }
    
    public func body(content: Content) -> some View {
        ScrollView([.horizontal, .vertical], showsIndicators: showsIndicators) {
            ScrollViewReader { scroller in
                content
                  .frame(width: contentSize.width * scale, height: contentSize.height * scale, alignment: .center)
                  .scaleEffect(scale, anchor: .center)
                  //.gesture(doubleTapGesture) // disable zoom because it conflicts with other select gesture
                  .simultaneousGesture(doubleTapGesture(scroller)) // disable zoom because it conflicts with other select gesture
            }
        }
        .simultaneousGesture(zoomGesture)
        .animation(.easeInOut, value: scale)
    }
}
