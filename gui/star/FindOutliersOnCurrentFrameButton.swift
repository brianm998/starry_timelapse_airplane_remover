import SwiftUI
import StarCore
import logging

struct FindOutliersOnCurrentFrameButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            let action: () -> Void = {
                Task {
                    if let frame = viewModel.currentFrame {
                        // re-find them
                        viewModel.findOutliersAndRender(frame: frame)
                    } else {
                        // XXX probably should do something here
                    }
                }
            }
            
            return Button(action: action) {
                Text(localized("ui.find_outliers_for_this_frame"))
            }
              .help(localized("ui.find_outliers_for_this_frame"))
        }
    }
}












