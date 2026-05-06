import SwiftUI
import StarCore

struct PreProcessingRenderPromptView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Render video after processing?")
              .font(.title)

            Text("Once frame processing finishes, would you like the video rendered automatically?")
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Don't ask me again") {
                    viewModel.confirmStartProcessing(autoRender: false, dontAskAgain: true)
                }
                  .help("Start processing now and stop showing render prompts. You can still render manually.")

                Spacer()

                Button("No") {
                    viewModel.confirmStartProcessing(autoRender: false, dontAskAgain: false)
                }

                Button("Yes") {
                    viewModel.confirmStartProcessing(autoRender: true, dontAskAgain: false)
                }
                  .keyboardShortcut(.defaultAction)
            }
        }
          .padding(20)
          .frame(minWidth: 380)
    }
}
