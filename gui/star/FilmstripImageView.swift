import SwiftUI
import StarCore

// the view for each frame in the filmstrip at the bottom
struct FilmstripImageView: View {
    @EnvironmentObject var viewModel: ViewModel
    let frameIndex: Int
    let scroller: ScrollViewProxy

    var body: some View {
        return VStack(alignment: .leading) {
            Spacer().frame(maxHeight: 8)
            HStack{
                Spacer().frame(maxWidth: 10)
                Text("\(frameIndex)").foregroundColor(.white)
            }.frame(maxHeight: 10)
            if frameIndex >= 0 && frameIndex < viewModel.frames.count {
                let frameView = viewModel.frames[frameIndex]
              //  let stroke_width: CGFloat = 4
                if viewModel.currentIndex == frameIndex {
                    
                    frameView.thumbnail_image
                      .foregroundColor(.orange)
                    
                } else {
                    frameView.thumbnail_image
                }
            }
            Spacer().frame(maxHeight: 8)
        }
          .frame(minWidth: CGFloat((viewModel.config?.thumbnail_width ?? 80) + 8),
                 minHeight: CGFloat((viewModel.config?.thumbnail_height ?? 50) + 30))
        // highlight the selected frame
          .background(viewModel.currentIndex == frameIndex ? Color(white: 0.45) : Color(white: 0.22))
          .onTapGesture {
              // XXX move this out 
              //viewModel.label_text = "loading..."
              // XXX set loading image here
              // grab frame and try to show it
              let frame_view = viewModel.frames[frameIndex]
              
              let current_frame = viewModel.currentFrame
              viewModel.transition(toFrame: frame_view,
                                           from: current_frame,
                                           withScroll: scroller)
          }
    }
}

