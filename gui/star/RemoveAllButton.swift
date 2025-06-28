import SwiftUI
import StarCore

// this button removes everything

struct RemoveAllButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Button(action: {
            viewModel.setAllCurrentFrameOutliers(to: true, renderImmediately: false)
        }) {
            Text("Remove All")
        }
          .help("remove all of the outlier groups in the frame")
    }
}
