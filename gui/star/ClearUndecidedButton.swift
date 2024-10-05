import SwiftUI
import StarCore

// this button clears all undecided outliers

struct ClearUndecidedButton: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        Button(action: {
            viewModel.setUndecidedFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text("Clear Undecided")
        }
          .help("don't paint any of the undecided outlier groups in the frame")
    }
}
