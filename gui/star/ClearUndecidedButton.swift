import SwiftUI
import StarCore

// this button clears all undecided outliers

struct ClearUndecidedButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Button(action: {
            viewModel.setUndecidedFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text("Clear Undecided")
        }
          .help("don't paint any of the undecided outlier groups in the frame")
    }
}
