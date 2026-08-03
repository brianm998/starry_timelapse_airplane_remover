import SwiftUI
import StarCore


struct RenderAllFramesButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    var body: some View {
        let action: () -> Void = {
            viewModel.processAll()
        }
        
        return Button(action: action) {
            Text(localized("ui.render_all_frames"))
        }
          .help(localized("ui.render_all_frames_of_this_sequence_with"))
    }    
}
