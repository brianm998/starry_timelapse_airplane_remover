import SwiftUI
import StarCore

struct PostProcessingRenderPromptView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    /// The frame on screen as it was and as star left it; left out unless both pictures exist.
    @ViewBuilder
    private var beforeAndAfter: some View {
        if let frame = viewModel.currentFrame,
           let before = frame.imageAccessor.urlForImage(frameIndex: frame.frameIndex, ofType: .original, atSize: .preview),
           let after = frame.imageAccessor.urlForImage(frameIndex: frame.frameIndex, ofType: .final, atSize: .preview)
        {
            HStack(spacing: 8) {
                picture(before)
                Image(systemName: "arrow.right")
                picture(after)
            }
              .frame(maxWidth: .infinity)
        }
    }

    private func picture(_ url: URL) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            Color.clear
        }
          .frame(width: 240, height: 160)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                ArtImage(.done)
                VStack(alignment: .leading, spacing: 16) {
                    Text(localized("ui.processing_complete"))
                      .font(.title)

                    beforeAndAfter

                    Text(localized("ui.render_video_now"))
                      .font(.title2)
                }
            }

            HStack {
                Button(localized("ui.cancel")) {
                    viewModel.postProcessingRenderPromptShowing = false
                }
                  .accessibilityIdentifier("prompt.post.cancel")

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
          .starDialogStyle()
    }
}
