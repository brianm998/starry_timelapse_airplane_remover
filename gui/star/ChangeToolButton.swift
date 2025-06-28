import SwiftUI
import StarCore

// this button sets the tool to the given value

struct ChangeToolButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let tool: SelectionMode
    
    var body: some View {
        Button {
            viewModel.selectionMode = tool
        } label: {
            Text(tool.displayName)
        }
          //.help("remove all of the outlier groups in the frame")
    }
}
