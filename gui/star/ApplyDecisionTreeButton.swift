import SwiftUI
import StarCore

struct ApplyDecisionTreeButton: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        let action: () -> Void = {
            Task {
                do {
                    if let frame = viewModel.currentFrame {
                        await frame.applyDecisionTreeToAutoSelectedOutliers()
                        await viewModel.render(frame: frame) {
                            Task {
                                await viewModel.refresh(frame: frame)
                                if frame.frameIndex == viewModel.currentIndex {
                                    viewModel.refreshCurrentFrame() // XXX not always still current
                                }
                                await viewModel.setOutlierGroups(forFrame: frame)
                                viewModel.update()
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
