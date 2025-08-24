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
              .cursor(.disappearingItem)
              .onTapGesture { viewModel.showIgnoreLowerBar = false }

            // draw an X
            Path { path in
                path.addLines([CGPoint(x: 0,
                                       y: self.viewModel.frameHeight-self.viewModel.ignoreLowerPixels),
                               CGPoint(x: self.viewModel.frameWidth,
                                       y: self.viewModel.frameHeight-self.viewModel.ignoreLowerPixels)])
                path.closeSubpath()
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
              .cursor(.disappearingItem)
              .onTapGesture { viewModel.showIgnoreLowerBar = false }

            
            // arrow on the right
            Image(systemName: "chevron.left")
              .resizable()
              .foregroundColor(.orange)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: (viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: viewModel.frameHeight/2 - viewModel.ignoreLowerPixels)
              .highPriorityGesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.arrowHeight/2))
              .cursor(.resizeUpDown)

            // arrow on the left
            Image(systemName: "chevron.right")
              .resizable()
              .foregroundColor(.orange)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: -(viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: viewModel.frameHeight/2 - viewModel.ignoreLowerPixels)
              .highPriorityGesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.arrowHeight/2))
              .cursor(.resizeUpDown)

            // orange line at the top for gestures
            Rectangle()
              .opacity(0.4)
              .background(.orange)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.lineWidth*4)
              .offset(y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)

            // larger clear selectable area for gesture
            Rectangle()
              .background(.clear)
              .opacity(0.00001)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.lineWidth*20)
              .offset(y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .highPriorityGesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.lineWidth*4))
              .cursor(.resizeUpDown)

            // Text on the top
            if viewModel.ignoreLowerPixels > viewModel.frameHeight/11 {
                Text("This area will not be processed")
                  .foregroundColor(.red)
                  .font(.system(size: viewModel.frameHeight/12))
                  .offset(y: viewModel.frameHeight/2 - viewModel.ignoreLowerPixels/2)
                  .cursor(.disappearingItem)
                  .onTapGesture { viewModel.showIgnoreLowerBar = false }
            }

            // earth crop bar 

            
            // earthAlignedImageCropAmount
            // viewModel.frameHeight/2 - viewModel.ignoreLowerPixels

            
            // arrow on the right
            Image(systemName: "chevron.left")
              .resizable()
              .foregroundColor(.blue)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: (viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: CGFloat(viewModel.earthAlignedImageCropAmount) - (viewModel.frameHeight/2))
              .highPriorityGesture(self.earthCropAmountGesture(adjustment: viewModel.arrowHeight/2))
              .cursor(.resizeUpDown)

            // arrow on the left
            Image(systemName: "chevron.right")
              .resizable()
              .foregroundColor(.blue)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: -(viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: CGFloat(viewModel.earthAlignedImageCropAmount) - (viewModel.frameHeight/2))
              .highPriorityGesture(self.earthCropAmountGesture(adjustment: viewModel.arrowHeight/2))
              .cursor(.resizeUpDown)

            // orange line at the top for gestures
            Rectangle()
              .opacity(0.4)
              .background(.blue)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.lineWidth*4)

              .offset(y: CGFloat(viewModel.earthAlignedImageCropAmount) - (viewModel.frameHeight/2))

            // larger clear selectable area for gesture
            Rectangle()
              .background(.clear)
              .opacity(0.00001)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.lineWidth*20)
              .offset(y: CGFloat(viewModel.earthAlignedImageCropAmount) - (viewModel.frameHeight/2))
//              .offset(y: viewModel.frameHeight - CGFloat(viewModel.earthAlignedImageCropAmount))//viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .highPriorityGesture(self.earthCropAmountGesture(adjustment: viewModel.lineWidth*4))
              .cursor(.resizeUpDown)

            
        }        
    }
    
    func ignoreLowerPixelsGesture(adjustment: CGFloat) -> some Gesture {
        DragGesture() 
          .onChanged { gesture in
              let offset = viewModel.frameHeight/2 - gesture.location.y
              Log.d("gesture.location.y \(gesture.location.y) viewModel.frameHeight \(viewModel.frameHeight) viewModel.ignoreLowerPixels \(viewModel.ignoreLowerPixels) offset \(offset)")
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
              if let configManager = viewModel.config {
                  // set the final value in the config
                  var config = configManager.config()
                  config.ignoreLowerPixels = Int(viewModel.ignoreLowerPixels)
                  configManager.update(config)
              }
          }
    }

    func earthCropAmountGesture(adjustment: CGFloat) -> some Gesture {
        DragGesture() 
          .onChanged { gesture in
              let offset = viewModel.frameHeight/2 - gesture.location.y
              Log.d("gesture.location.y \(gesture.location.y) viewModel.frameHeight \(viewModel.frameHeight) viewModel.earthAlignedImageCropAmount \(viewModel.earthAlignedImageCropAmount) offset \(offset)")
              if viewModel.earthAlignedImageCropAmount + Int(offset) > 0 {
                  viewModel.earthAlignedImageCropAmount = Int(viewModel.frameHeight - offset + adjustment)
              } 
              if viewModel.earthAlignedImageCropAmount > Int(viewModel.frameHeight) {
                  viewModel.earthAlignedImageCropAmount = Int(viewModel.frameHeight)
              }
          }
          .onEnded { gesture in
              Log.d("gesture.location.y \(gesture.location.y)")
              let offset = viewModel.frameHeight/2 - gesture.location.y
              if viewModel.earthAlignedImageCropAmount + Int(offset) > 0 {
                  viewModel.earthAlignedImageCropAmount = Int(viewModel.frameHeight - offset + adjustment)
              } else {
                  viewModel.earthAlignedImageCropAmount = 0
              }
              if viewModel.earthAlignedImageCropAmount > Int(viewModel.frameHeight) {
                  viewModel.earthAlignedImageCropAmount = Int(viewModel.frameHeight)
              }
              if let configManager = viewModel.config {
                  // set the final value in the config
                  var config = configManager.config()
                  config.earthAlignedImageCropAmount = Int(viewModel.earthAlignedImageCropAmount)
                  configManager.update(config)
              }
          }
    }
}
