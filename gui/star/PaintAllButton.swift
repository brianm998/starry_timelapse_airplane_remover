import SwiftUI
import StarCore

// this button paints everything

struct PaintAllButton: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        Button(action: {
            viewModel.setAllCurrentFrameOutliers(to: true, renderImmediately: false)
        }) {
            Text("Paint All")
        }
          .help("paint all of the outlier groups in the frame")
    }
}
