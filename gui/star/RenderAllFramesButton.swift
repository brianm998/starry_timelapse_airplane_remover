import SwiftUI
import StarCore


struct RenderAllFramesButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    var body: some View {
        let action: () -> Void = {
            viewModel.processAll()
        }
        
        return Button(action: action) {
            Text("Render All Frames")
        }
          .help("Render all frames of this sequence with current settings")
    }    
}
