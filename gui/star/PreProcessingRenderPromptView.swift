import SwiftUI
import StarCore

struct PreProcessingRenderPromptView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("ui.render_video_after_processing"))
              .font(.title)

            Text(localized("ui.once_frame_processing_finishes_would_you"))
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(localized("ui.don_t_ask_me_again")) {
                    viewModel.confirmStartProcessing(autoRender: false, dontAskAgain: true)
                }
                  .help(localized("ui.start_processing_now_and_stop_showing_render"))

                Spacer()

                Button(localized("ui.no")) {
                    viewModel.confirmStartProcessing(autoRender: false, dontAskAgain: false)
                }

                Button(localized("ui.yes")) {
                    viewModel.confirmStartProcessing(autoRender: true, dontAskAgain: false)
                }
                  .keyboardShortcut(.defaultAction)
            }
        }
          .padding(20)
          .frame(minWidth: 380)
    }
}
