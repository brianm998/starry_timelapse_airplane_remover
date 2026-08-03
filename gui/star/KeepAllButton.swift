import SwiftUI
import StarCore

// this button keeps everything

struct KeepAllButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Button(action: {
            viewModel.setAllCurrentFrameOutliers(to: false, renderImmediately: false)
        }) {
            Text(localized("ui.keep_all"))
        }
          .help(localized("ui.keep_all_of_the_outlier_groups_in_the_frame"))
    }
}
