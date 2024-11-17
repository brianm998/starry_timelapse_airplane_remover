import SwiftUI
import StarCore

// displays a single frame as an image, and nothing else.
// the image is always a preview here

public struct FrameImageView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var size: CGSize = .zero
    
    public var body: some View {
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]
        return 
          ZStack {
              frameView.previewImage(type: viewModel.frameViewMode)
                .aspectRatio(viewModel.frameSize, contentMode: .fit)
                .readSize() { size in
                    self.size = size
                }
              
              if viewModel.showIgnoreLowerBar {
                  self.ignoreBar
              }
          }
//          .aspectRatio(viewModel.frameSize, contentMode: .fit)
    }

    var ignoreBar: some View {
        let barHeight = viewModel.ignoreLowerPixels/viewModel.frameHeight*size.height
        
        return ZStack {
            Rectangle()
              .background(.red)
              .opacity(0.3)

            // draw an X
            Path { path in
                
                path.addLines([CGPoint(x: 0, y: 0),
                               CGPoint(x: self.size.width, y: barHeight)])
                path.closeSubpath()
                
                path.addLines([CGPoint(x: self.size.width, y: 0),
                               CGPoint(x: 0, y: barHeight)])
                path.closeSubpath()
            }
              .stroke(.white, lineWidth: 1)
              .opacity(0.4)

        }
          .frame(width: size.width, height: barHeight)
          .offset(y: size.height/2 - barHeight/2)
        
    }
}
