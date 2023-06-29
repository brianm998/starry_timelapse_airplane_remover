import SwiftUI
import StarCore

// slider at the bottom that scrubs the frame position
struct ScrubSliderView: View {
    @EnvironmentObject var viewModel: ViewModel
    let scroller: ScrollViewProxy
    
    var body: some View {
        if viewModel.interactionMode == .edit {
            Spacer().frame(maxHeight: 20)
        }
        let start = 0.0
        let end = Double(viewModel.image_sequence_size)
        return Slider(value: $viewModel.sliderValue, in : start...end)
          .frame(maxWidth: .infinity, alignment: .bottom)
          .disabled(viewModel.video_playing)
          .onChange(of: viewModel.sliderValue) { value in
              let frame_index = Int(viewModel.sliderValue)
              Log.i("transition to \(frame_index)")
              // XXX do more than just this
              var new_frame_index = Int(value)
              //viewModel.current_index = Int(value)
              if new_frame_index < 0 { new_frame_index = 0 }
              if new_frame_index >= viewModel.frames.count {
                  new_frame_index = viewModel.frames.count - 1
              }
              let new_frame_view = viewModel.frames[new_frame_index]
              let current_frame = viewModel.currentFrame
              self.viewModel.transition(toFrame: new_frame_view,
                                     from: current_frame,
                                     withScroll: scroller)
          }
    }
}
