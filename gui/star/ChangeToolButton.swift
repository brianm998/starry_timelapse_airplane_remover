import SwiftUI
import StarCore

// this button sets the tool to the given value

// used in StarCommands for keyboard shortcuts
struct ChangeToolButton: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let tool: ToolType
    
    var body: some View {
        Button {
            viewModel.selectionMode = tool
        } label: {
            Text(tool.displayName)
        }
          //.help("remove all of the outlier groups in the frame")
    }
}
