import SwiftUI
import StarCore
import logging

// the blue line above where the horizon is

public struct HorizonBarView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    public var body: some View {
        ZStack {
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
              let configManager = viewModel.config 
              // set the final value in the config
              var config = configManager.config()
              config.earthAlignedImageCropAmount = Int(viewModel.earthAlignedImageCropAmount)
              configManager.update(config)
          }
    }
}
