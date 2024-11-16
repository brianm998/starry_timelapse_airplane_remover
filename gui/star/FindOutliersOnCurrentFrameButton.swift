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
                        await viewModel.findOutliers(frame: frame)
                    } else {
                        // XXX probably should do something here
                    }
                }
            }
            
            return Button(action: action) {
                Text("Find Outliers for this frame")
            }
              .help("Find Outliers for this frame")
        }
    }
}












