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
          }
    }
}
