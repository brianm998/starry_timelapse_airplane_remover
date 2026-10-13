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
          .disabled(!viewModel.currentFrameUsesOutliers)
          .help(viewModel.currentFrameUsesOutliers ?
                  tool.helpText :
                  localized("tool.help.disabled"))
    }
}

/// The circled "i" next to the tool list; opens the detailed explanation of every tool.
struct ToolHelpButton: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Image(systemName: "info.circle")
              .foregroundColor(.white)
        }
          .buttonStyle(.plain)
          .help(localized("ui.tool_help_button"))
          .sheet(isPresented: $showing) {
              ToolHelpView(isPresented: $showing)
          }
    }
}

struct ToolHelpView: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("ui.tool_help_title"))
              .font(.title2)
              .bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(localized("ui.tool_help_intro"))
                    Text(localized("ui.tool_help_selective"))
                    ForEach(ToolType.allCases, id: \.self) { tool in
                        HStack(alignment: .top, spacing: 10) {
                            Image(tool.iconName)
                              .resizable()
                              .frame(width: 35, height: 35)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.displayName)
                                  .bold()
                                Text(tool.helpText)
                            }
                        }
                    }
                    Text(localized("ui.tool_help_drag_note"))
                }
                  .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button(localized("ui.close")) { isPresented = false }
                  .keyboardShortcut(.defaultAction)
            }
        }
          .padding(20)
          .frame(width: 520, height: 560)
    }
}
