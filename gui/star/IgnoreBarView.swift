import SwiftUI
import StarCore
import logging

// the red bar showing what part of the frame to ignore
public struct IgnoreBarView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    public var body: some View {
        ZStack {
            // red background
            Rectangle()
              .background(.red)
              .opacity(0.3)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.ignoreLowerPixels)
              .offset(y: viewModel.frameHeight/2 - viewModel.ignoreLowerPixels/2)

            // draw an X
            Path { path in
                path.addLines([CGPoint(x: 0, y: self.viewModel.frameHeight),
                               CGPoint(x: self.viewModel.frameWidth,
                                       y: self.viewModel.frameHeight-self.viewModel.ignoreLowerPixels)])
                path.closeSubpath()
                path.addLines([CGPoint(x: self.viewModel.frameWidth,
                                       y: self.viewModel.frameHeight),
                               CGPoint(x: 0,
                                       y: self.viewModel.frameHeight-self.viewModel.ignoreLowerPixels)])
                path.closeSubpath()
            }
              .stroke(.white, lineWidth: viewModel.lineWidth*2)
              .opacity(0.4)

            // arrow on the right
            Image(systemName: "arrow.left")
              .resizable()
              .foregroundColor(.orange)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: (viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .gesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.arrowHeight/2))

            // arrow on the left
            Image(systemName: "arrow.right")
              .resizable()
              .foregroundColor(.orange)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: -(viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .gesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.arrowHeight/2))

            // white line at the top of the ignore bar
            Rectangle()
              .foregroundColor(.white)
              .background(.white)
              .opacity(0.85)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.lineWidth)
              .offset(y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .gesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.lineWidth))

            // Text on the top
            if viewModel.ignoreLowerPixels > viewModel.frameHeight/11 {
                Text("This area will not be processed")
                  .foregroundColor(.red)
                  .font(.system(size: viewModel.frameHeight/12))
                  .offset(y: viewModel.frameHeight/2 - viewModel.ignoreLowerPixels/2)
            }
        }        
    }
    
    func ignoreLowerPixelsGesture(adjustment: CGFloat) -> some Gesture {
        DragGesture() 
          .onChanged { gesture in
              //Log.d("gesture.location.y \(gesture.location.y) viewModel.frameHeight \(viewModel.frameHeight) viewModel.ignoreLowerPixels \(viewModel.ignoreLowerPixels)")
              let offset = viewModel.frameHeight/2 - gesture.location.y
              if viewModel.ignoreLowerPixels + offset > 0 {
                  viewModel.ignoreLowerPixels = offset + adjustment
              } 
              if viewModel.ignoreLowerPixels > viewModel.frameHeight {
                  viewModel.ignoreLowerPixels = viewModel.frameHeight
              }
          }
          .onEnded { gesture in
              //Log.d("gesture.location.y \(gesture.location.y)")
              let offset = viewModel.frameHeight/2 - gesture.location.y
              if viewModel.ignoreLowerPixels + offset > 0 {
                  viewModel.ignoreLowerPixels = offset + adjustment
              } else {
                  viewModel.ignoreLowerPixels = 0
              }
              if viewModel.ignoreLowerPixels > viewModel.frameHeight {
                  viewModel.ignoreLowerPixels = viewModel.frameHeight
              }
              if var config = viewModel.config {
                  config.ignoreLowerPixels = Int(viewModel.ignoreLowerPixels)
                  viewModel.config = config
                  // XXX this config doesn't get mirroried to the other spots
                  // XXX we need a centeralized config for this to work :(
                  // XXX and save the config to file as well
              }
          }
    }
}
