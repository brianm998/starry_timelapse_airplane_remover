import SwiftUI
import StarCore

struct RenderCurrentFrameButton: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    
    var body: some View {
        let action: () -> Void = {
            Task {
                if let frame = viewModel.currentFrame {
                    await viewModel.render(frame: frame, closure: nil)
                }
            }
        }
        
        return Button(action: action) {
            Text("Render This Frame")
        }
          .help("Render the active frame with current settings")
    }    
}
