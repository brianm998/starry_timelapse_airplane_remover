import SwiftUI
import StarCore
import logging

struct ProcessAllFramesButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            Button(action: buttonPress) {
                Text(localized("ui.process_all_frames"))
            }
              .help(localized("ui.process_all_frames"))
        }
    }

    private func buttonPress() {
        viewModel.processAll()
    }
}












