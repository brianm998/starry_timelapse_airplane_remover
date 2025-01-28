import SwiftUI
import StarCore

struct ApplyDecisionTreeButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    var body: some View {
        let action: () -> Void = {
            Task {
                do {
                    if let frame = viewModel.currentFrame {
                        await frame.applyDecisionTreeToAutoSelectedOutliers(includingDustbin: viewModel.currentFrameView.shouldShowDustbin,
                                                                            overwrite: !viewModel.classifyOnlyUnclassified,
                                                                            minimumSize: viewModel.minimumClassificationSize)
                        try? await viewModel.render(frame: frame) {
                            Task {
                                await viewModel.refresh(frame: frame)
                                await viewModel.setOutlierGroups(forFrame: frame)
                            }
                        }
                    }
                }
            }
        }
        return Button(action: action) {
            Text("DT Auto Only")
        }
          .help("apply the outlier group decision tree to all selected outlier groups in this frame")
    }    
}
