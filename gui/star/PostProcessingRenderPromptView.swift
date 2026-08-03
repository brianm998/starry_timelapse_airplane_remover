import SwiftUI
import StarCore

struct PostProcessingRenderPromptView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("ui.processing_complete"))
              .font(.title)

            Text(localized("ui.render_video_now"))
              .font(.title2)

            HStack {
                Button(localized("ui.cancel")) {
                    viewModel.postProcessingRenderPromptShowing = false
                }

                Spacer()

                Button(localized("ui.preview_first")) {
                    viewModel.playFinalFrames()
                }
                  .help(localized("ui.play_the_final_processed_frames_from_the"))

                Button(localized("ui.yes")) {
                    viewModel.confirmRenderAfterProcessing(autoStart: true)
                }
                  .keyboardShortcut(.defaultAction)
                  .help(localized("ui.render_now_using_the_current_settings"))
            }
        }
          .padding(20)
          .frame(minWidth: 380)
    }
}
