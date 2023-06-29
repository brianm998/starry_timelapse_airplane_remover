import SwiftUI
import StarCore

// this button clears everything

struct ClearAllButton: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        Button(action: {
            viewModel.setAllCurrentFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text("Clear All")
        }
          .help("don't paint any of the outlier groups in the frame")
    }
}
