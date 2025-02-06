import SwiftUI
import StarCore
import logging

struct ProcessRemainingFramesButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            Button(action: buttonPress) {
                Text("Process frames from here to the end")
            }
              .help("Process frames from here to the end")
        }
    }

    private func buttonPress() {
        viewModel.processFrames(from: viewModel.currentIndex)
    }
}












