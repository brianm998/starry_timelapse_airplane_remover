import SwiftUI
import StarCore

// the view for each frame in the filmstrip at the bottom
struct FilmstripImageView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    let frameIndex: Int

    var body: some View {
        return VStack(alignment: .leading) {
            Spacer().frame(maxHeight: 8)
            HStack{
                Spacer().frame(maxWidth: 10)
                Text("\(frameIndex)").foregroundColor(.white)
            }.frame(maxHeight: 10)
            if frameIndex >= 0 && frameIndex < viewModel.frames.count {
                let frameView = viewModel.frames[frameIndex]
                if viewModel.currentIndex == frameIndex {
                    
                    frameView.thumbnailImage
                      .foregroundColor(.orange)
                    
                } else {
                    frameView.thumbnailImage
                }
            }
            Spacer().frame(maxHeight: 8)
        }
          .frame(minWidth: CGFloat((viewModel.config?.thumbnailWidth ?? 80) + 8),
                 minHeight: CGFloat((viewModel.config?.thumbnailHeight ?? 50) + 30))
        // highlight the selected frame
          .background(viewModel.currentIndex == frameIndex ? Color(white: 0.45) : Color(white: 0.22))
          .onTapGesture {
              viewModel.currentIndex = frameIndex
          }
    }
}

