import SwiftUI
import StarCore

// the view for each frame in the filmstrip at the bottom
struct FilmstripImageView: View {
    @ObservedObject var viewModel: ViewModel
    let imageSequenceView: ImageSequenceView
    let frame_index: Int
    let scroller: ScrollViewProxy

    public init(viewModel: ViewModel,
                imageSequenceView: ImageSequenceView,
                frame_index: Int,
                scroller: ScrollViewProxy)
    {
        self.viewModel = viewModel
        self.imageSequenceView = imageSequenceView
        self.frame_index = frame_index
        self.scroller = scroller
    }
    
    var body: some View {
        return VStack(alignment: .leading) {
            Spacer().frame(maxHeight: 8)
            HStack{
                Spacer().frame(maxWidth: 10)
                Text("\(frame_index)").foregroundColor(.white)
            }.frame(maxHeight: 10)
            if frame_index >= 0 && frame_index < viewModel.frames.count {
                let frameView = viewModel.frames[frame_index]
              //  let stroke_width: CGFloat = 4
                if viewModel.current_index == frame_index {
                    
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
          .background(viewModel.current_index == frame_index ? Color(white: 0.45) : Color(white: 0.22))
          .onTapGesture {
              // XXX move this out 
              //viewModel.label_text = "loading..."
              // XXX set loading image here
              // grab frame and try to show it
              let frame_view = viewModel.frames[frame_index]
              
              let current_frame = viewModel.currentFrame
              imageSequenceView.transition(toFrame: frame_view,
                                           from: current_frame,
                                           withScroll: scroller)
          }
    }
}
