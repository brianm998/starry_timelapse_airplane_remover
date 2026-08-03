import SwiftUI
import StarCore

// this button removes everything

struct RemoveAllButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Button(action: {
            viewModel.setAllCurrentFrameOutliers(to: true, renderImmediately: false)
        }) {
            Text(localized("ui.remove_all"))
        }
          .help(localized("ui.remove_all_of_the_outlier_groups_in_the"))
    }
}
