import SwiftUI
import StarCore
import logging

// slider at the bottom that scrubs the frame position
struct ScrubSliderView: View {
    @EnvironmentObject var viewModel: ViewModel
    let scroller: ScrollViewProxy
    
    var body: some View {
        if viewModel.interactionMode == .edit {
            _ = Spacer().frame(maxHeight: 20)
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
              var newFrameIndex = Int(value)
              //viewModel.currentIndex = Int(value)
              if newFrameIndex < 0 { newFrameIndex = 0 }
              if newFrameIndex >= viewModel.frames.count {
                  newFrameIndex = viewModel.frames.count - 1
              }
              let newFrameView = viewModel.frames[newFrameIndex]
              let currentFrame = viewModel.currentFrame
              self.viewModel.transition(toFrame: newFrameView,
                                     from: currentFrame,
                                     withScroll: scroller)
          }
    }
}
