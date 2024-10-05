import SwiftUI
import StarCore
import logging

struct ApplyAllDecisionTreeButton: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    
    var body: some View {
        Log.d("applyAllDecisionTreeButton")
        let action: () -> Void = {
            Log.d("applyAllDecisionTreeButton action")
            Task {
                Log.d("doh")
                do {
                    //Log.d("doh index \(viewModel.currentIndex) frame \(viewModel.frames[0].frame) have_all_frames \(viewModel.have_all_frames)")
                    if let frame = viewModel.currentFrame {
                        Log.d("doh")
                        await frame.applyDecisionTreeToAllOutliers()
                        Log.d("doh")
                        await viewModel.render(frame: frame) {
                            Log.d("doh")
                            Task {
                                await viewModel.refresh(frame: frame)
                                await viewModel.setOutlierGroups(forFrame: frame)
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
