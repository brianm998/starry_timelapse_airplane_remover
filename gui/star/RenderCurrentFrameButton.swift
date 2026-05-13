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
                    viewModel.report(error: "Render failed: \(error)")
                }
            }
        }
        
        return Button(action: action) {
            Text("Render This Frame")
        }
          .help("Render the active frame with current settings")
    }    
}
