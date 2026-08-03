import SwiftUI
import StarCore

// this button clears all undecided outliers

struct ClearUndecidedButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Button(action: {
            viewModel.setUndecidedFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text(localized("ui.clear_undecided"))
        }
          .help(localized("ui.don_t_paint_any_of_the_undecided_outlier"))
    }
}
