import SwiftUI
import StarCore

struct PostProcessingRenderPromptView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    /// The frame on screen as it was and as star left it; nil unless both pictures exist.
    private var pictures: PostProcessingRenderPromptLayout.Pictures? {
        guard let frame = viewModel.currentFrame,
              let before = frame.imageAccessor.urlForImage(frameIndex: frame.frameIndex, ofType: .original, atSize: .preview),
              let after = frame.imageAccessor.urlForImage(frameIndex: frame.frameIndex, ofType: .final, atSize: .preview)
        else { return nil }
        return .init(before: before, after: after)
    }

    var body: some View {
        // The URLs can be missing when the sheet first sizes itself and appear later, and a sheet does not grow once
        // presented. So the picture width is reserved whenever there is a current frame, whether or not its pictures
        // exist yet; only with no frame at all does the dialog keep its narrow width.
        PostProcessingRenderPromptLayout(
            pictures: pictures,
            reservePictureWidth: viewModel.currentFrame != nil,
            cancel: { viewModel.postProcessingRenderPromptShowing = false },
            previewFirst: { viewModel.playFinalFrames() },
            yes: { viewModel.confirmRenderAfterProcessing(autoStart: true) })
    }
}

/// The dialog's layout, free of the view model so a test can host it.
struct PostProcessingRenderPromptLayout: View {
    struct Pictures { let before: URL; let after: URL }

    static let padding: CGFloat = 20
    static let artWidth: CGFloat = ArtImage(.done).displaySize.width
    static let columnSpacing: CGFloat = 16
    static let pictureSize = CGSize(width: 240, height: 160)
    static let arrowGap: CGFloat = 8
    static let arrowWidth: CGFloat = 17
    static let minWidth: CGFloat = 380

    /// Width of the before / arrow / after row.
    static var pictureRowWidth: CGFloat { pictureSize.width * 2 + arrowGap * 2 + arrowWidth }
    /// Width of the whole dialog when the pictures have room.
    static var widthWithPictures: CGFloat {
        padding * 2 + artWidth + columnSpacing + pictureRowWidth
    }

    var pictures: Pictures?
    /// Make the dialog as wide as the pictures need even if `pictures` is nil.
    var reservePictureWidth: Bool = false
    var cancel: () -> Void
    var previewFirst: () -> Void
    var yes: () -> Void

    @ViewBuilder
    private var beforeAndAfter: some View {
        if let pictures {
            HStack(spacing: Self.arrowGap) {
                picture(pictures.before)
                Image(systemName: "arrow.right")
                picture(pictures.after)
            }
        }
    }

    private func picture(_ url: URL) -> some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fit)
        } placeholder: {
            Color.clear
        }
          .frame(width: Self.pictureSize.width, height: Self.pictureSize.height)
    }

    var body: some View {
        let wide = pictures != nil || reservePictureWidth
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: Self.columnSpacing) {
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
                Button(localized("ui.cancel"), action: cancel)
                  .accessibilityIdentifier("prompt.post.cancel")

                Spacer()

                Button(localized("ui.preview_first"), action: previewFirst)
                  .help(localized("ui.play_the_final_processed_frames_from_the"))

                Button(localized("ui.yes"), action: yes)
                  .keyboardShortcut(.defaultAction)
                  .help(localized("ui.render_now_using_the_current_settings"))
            }
        }
          .padding(Self.padding)
          .frame(width: wide ? Self.widthWithPictures : nil)
          .frame(minWidth: Self.minWidth)
          .fixedSize()
          .starDialogStyle()
    }
}
