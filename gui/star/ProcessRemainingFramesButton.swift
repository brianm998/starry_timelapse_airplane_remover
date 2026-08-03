import SwiftUI
import StarCore
import logging

struct ProcessRemainingFramesButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            Button(action: buttonPress) {
                Text(localized("ui.process_frames_from_here_to_the_end"))
            }
              .help(localized("ui.process_frames_from_here_to_the_end"))
        }
    }

    private func buttonPress() {
        viewModel.processFrames(from: viewModel.currentIndex)
    }
}












