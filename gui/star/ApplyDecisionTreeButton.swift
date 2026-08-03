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
                    viewModel.report(error: localized("ui.decision_tree_render_failed", error))
                }
            }
        }
        return Button(action: action) {
            Text(localized("ui.dt_auto_only"))
        }
          .help(localized("ui.apply_the_outlier_group_decision_tree_to_all_2"))
    }    
}
