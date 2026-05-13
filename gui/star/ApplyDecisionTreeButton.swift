import SwiftUI
import StarCore

struct ApplyDecisionTreeButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    var body: some View {
        let action: () -> Void = {
            Task {
                do {
                    if let frame = viewModel.currentFrame {
                        await frame.applyDecisionTreeToAutoSelectedOutliers(includingTrash: viewModel.shouldShowTrash,
                                                                            overwrite: !viewModel.classifyOnlyUnclassified,
                                                                            minimumSize: viewModel.minimumClassificationSize)
                        try await viewModel.render(frame: frame) {
                            Task {
                                await viewModel.refresh(frame: frame)
                                await viewModel.frames[frame.frameIndex].setOutlierGroups()
                            }
                        }
                    }
                } catch {
                    viewModel.report(error: "Decision tree render failed: \(error)")
                }
            }
        }
        return Button(action: action) {
            Text("DT Auto Only")
        }
          .help("apply the outlier group decision tree to all selected outlier groups in this frame")
    }    
}
