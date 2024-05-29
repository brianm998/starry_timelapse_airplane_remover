import SwiftUI
import StarCore
import logging

// slider at the bottom that scrubs the frame position
struct ScrubSliderView: View {
    @EnvironmentObject var viewModel: ViewModel

    @State private var sliderValue = 0.0

    var body: some View {
        if viewModel.interactionMode == .edit {
            _ = Spacer().frame(maxHeight: 20)
        }
        let start = 0.0
        let end = Double(viewModel.imageSequenceSize)
        return Slider(value: $sliderValue, in : start...end)
          .frame(maxWidth: .infinity, alignment: .bottom)
          .disabled(viewModel.videoPlaying)
          .onChange(of: viewModel.currentIndex) { 
              self.sliderValue = Double(viewModel.currentIndex)
          }
          .onChange(of: sliderValue) {
              let frameIndex = Int(sliderValue)
              var newFrameIndex = Int(sliderValue)
              if newFrameIndex < 0 { newFrameIndex = 0 }
              if newFrameIndex >= viewModel.imageSequenceSize {
                  newFrameIndex = viewModel.imageSequenceSize - 1
              }
              viewModel.currentIndex = newFrameIndex
          }
    }
}
