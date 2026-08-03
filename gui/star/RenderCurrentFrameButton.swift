import SwiftUI
import StarCore

struct RenderCurrentFrameButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    var body: some View {
        let action: () -> Void = {
            Task {
                do {
                    if let frame = viewModel.currentFrame {
                        try await viewModel.render(frame: frame, closure: nil)
                    }
                } catch {
                    viewModel.report(error: localized("ui.render_failed", error))
                }
            }
        }
        
        return Button(action: action) {
            Text(localized("ui.render_this_frame"))
        }
          .help(localized("ui.render_the_active_frame_with_current"))
    }    
}
