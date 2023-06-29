import SwiftUI
import StarCore

struct ApplyAllDecisionTreeButton: View {
    @EnvironmentObject var viewModel: ViewModel
    
    var body: some View {
        Log.d("applyAllDecisionTreeButton")
        let action: () -> Void = {
            Log.d("applyAllDecisionTreeButton action")
            Task {
                Log.d("doh")
                do {
                    //Log.d("doh index \(viewModel.current_index) frame \(viewModel.frames[0].frame) have_all_frames \(viewModel.have_all_frames)")
                    if let frame = viewModel.currentFrame {
                        Log.d("doh")
                        await frame.applyDecisionTreeToAllOutliers()
                        Log.d("doh")
                        await viewModel.render(frame: frame) {
                            Log.d("doh")
                            Task {
                                await viewModel.refresh(frame: frame)
                                if frame.frame_index == viewModel.current_index {
                                    viewModel.refreshCurrentFrame() // XXX not always still current
                                }
                                await viewModel.setOutlierGroups(forFrame: frame)
                                viewModel.update()
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