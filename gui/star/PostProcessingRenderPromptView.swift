import SwiftUI
import StarCore

struct PostProcessingRenderPromptView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Processing complete")
              .font(.title)

            Text("Render video now?")
              .font(.title2)

            HStack {
                Button("Cancel") {
                    viewModel.postProcessingRenderPromptShowing = false
                }

                Spacer()

                Button("Preview first") {
                    viewModel.confirmRenderAfterProcessing(autoStart: false)
                }
                  .help("Open the render settings sheet so you can adjust before rendering.")

                Button("Yes") {
                    viewModel.confirmRenderAfterProcessing(autoStart: true)
                }
                  .keyboardShortcut(.defaultAction)
                  .help("Render now using the current settings.")
            }
        }
          .padding(20)
          .frame(minWidth: 380)
    }
}
