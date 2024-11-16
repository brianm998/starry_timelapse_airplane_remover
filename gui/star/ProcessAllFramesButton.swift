import SwiftUI
import StarCore
import logging

struct ProcessAllFramesButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            Button(action: buttonPress) {
                Text("Process all frames")
            }
              .help("Process all frames")
        }
    }

    private func buttonPress() {
        viewModel.processAllFrames()
    }
}












