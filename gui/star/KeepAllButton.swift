import SwiftUI
import StarCore

// this button keeps everything

struct KeepAllButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Button(action: {
            viewModel.setAllCurrentFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text("Keep All")
        }
          .help("keep all of the outlier groups in the frame")
    }
}
