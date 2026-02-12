import SwiftUI
import StarCore
import logging

struct ApplyAllDecisionTreeButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    var body: some View {
        Log.d("applyAllDecisionTreeButton")
        let action: () -> Void = {
            Log.d("applyAllDecisionTreeButton action")
            Task.detached(priority: .userInitiated) {
                Log.d("doh")
                do {
                    //Log.d("doh index \(viewModel.currentIndex) frame \(viewModel.frames[0].frame) have_all_frames \(viewModel.have_all_frames)")
                    if let frame = await viewModel.currentFrame {
                        let frameView = await viewModel.currentFrameView
                        _ = await frame.applyDecisionTreeToAllOutliers(overwrite: !viewModel.classifyOnlyUnclassified,
                                                                       minimumSize: viewModel.minimumClassificationSize)
                        try? await viewModel.render(frame: frame) {
                            Task {
                                await viewModel.refresh(frame: frame)
                                await frameView.setOutlierGroups()
                            }
                        }
                    } else {
                        Log.w("FUCK")
                    }
                }
            }
        }
        let shortcutKey: KeyEquivalent = "d"
        return Button(action: action) {
            Text("Decision Tree All")
        }
          .keyboardShortcut(shortcutKey, modifiers: [])
          .help("apply the outlier group decision tree to all outlier groups in this frame")
    }
}
