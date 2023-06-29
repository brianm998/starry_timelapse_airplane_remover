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
        let end = Double(viewModel.imageSequenceSize)
        return Slider(value: $viewModel.sliderValue, in : start...end)
          .frame(maxWidth: .infinity, alignment: .bottom)
          .disabled(viewModel.videoPlaying)
          .onChange(of: viewModel.sliderValue) { value in
              let frameIndex = Int(viewModel.sliderValue)
              Log.i("transition to \(frameIndex)")
              // XXX do more than just this
              var new_frameIndex = Int(value)
              //viewModel.currentIndex = Int(value)
              if new_frameIndex < 0 { new_frameIndex = 0 }
              if new_frameIndex >= viewModel.frames.count {
                  new_frameIndex = viewModel.frames.count - 1
              }
              let new_frame_view = viewModel.frames[new_frameIndex]
              let current_frame = viewModel.currentFrame
              self.viewModel.transition(toFrame: new_frame_view,
                                     from: current_frame,
                                     withScroll: scroller)
          }
    }
}
