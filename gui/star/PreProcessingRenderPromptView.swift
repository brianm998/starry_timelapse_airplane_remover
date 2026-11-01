import SwiftUI
import StarCore
import logging

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
                  .accessibilityIdentifier("prompt.pre.no")

                Button(localized("ui.yes")) {
                    viewModel.chooseRenderOptions()
                }
                  .keyboardShortcut(.defaultAction)
                  .accessibilityIdentifier("prompt.pre.yes")
            }
        }
          .padding(20)
          .frame(minWidth: 380)
    }
}

/// The second step of the pre-processing prompt, after Yes: how the video is to be rendered once the frames are processed.
/// It hosts the same options as the Render Video sheet.  Cancel goes back to the first question.
struct PreProcessingRenderOptionsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @State private var draft: RenderOptionsDraft

    init(initial: RenderChoice) {
        _draft = State(initialValue: RenderOptionsDraft(choice: initial))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("ui.render_options_after_processing_title"))
              .font(.title)

            RenderOptionsView(viewModel: viewModel, draft: $draft)

            HStack {
                Spacer()
                Button(localized("ui.cancel")) {
                    viewModel.cancelRenderOptions()
                }

                Button(localized("ui.use_these_settings")) {
                    viewModel.confirmRenderOptions(draft.choice)
                }
                  .keyboardShortcut(.defaultAction)
                  .disabled(draft.hasRateProblem)
                  .accessibilityIdentifier("prompt.options.confirm")
            }
        }
          .padding(20)
          .frame(minWidth: 380)
    }
}

/// How a video is to be rendered: everything the Render Video sheet's options set.
struct RenderChoice: Equatable {
    var frameRate: FrameRate
    var codec: FFmpegCodec
    var encoder: FFmpegEncoder
    var pixelFormat: FFmpegPixelFormat
    var muxer: FFmpegMuxer
    var resolution: OutputResolution = .original

    /// A choice from settings that may not go together, or that the bundled ffmpeg does not have (they are saved
    /// with whatever was bundled then, and a GPU encoder only exists on a machine with the GPU): each part is kept
    /// if it fits the ones before it and otherwise replaced by one that does.
    static func settled(frameRate: FrameRate,
                        codec: FFmpegCodec,
                        encoder: FFmpegEncoder,
                        pixelFormat: FFmpegPixelFormat,
                        muxer: FFmpegMuxer) -> RenderChoice
    {
        let settings = FFmpegCodec.consistentSettings(codec: codec,
                                                      encoder: encoder,
                                                      pixelFormat: pixelFormat,
                                                      muxer: muxer)
        let choice = RenderChoice(frameRate: frameRate,
                                  codec: settings?.codec ?? codec,
                                  encoder: settings?.encoder ?? encoder,
                                  pixelFormat: settings?.pixelFormat ?? pixelFormat,
                                  muxer: settings?.muxer ?? muxer)
        if choice.codec != codec || choice.encoder != encoder
             || choice.pixelFormat != pixelFormat || choice.muxer != muxer
        {
            Log.w("video settings \(codec)/\(encoder)/\(pixelFormat)/\(muxer) do not fit this ffmpeg; using \(choice.codec)/\(choice.encoder)/\(choice.pixelFormat)/\(choice.muxer)")
        }
        return choice
    }
}

/// The pre-processing prompt as a sequence of steps, and the render choice made in it, which is held until the run ends.
///
/// Pure, so the flow can be tested without a view model: `ImageSequenceViewModel` holds one and acts on what it returns.
struct PreProcessingRenderFlow: Equatable {
    enum Step: Equatable {
        case closed
        /// "Render video after processing?"
        case asking
        /// Yes was answered: the render options are being chosen.
        case choosingOptions
    }

    /// The arguments of `ImageSequenceViewModel.confirmStartProcessing`.
    struct Start: Equatable {
        var autoRender: Bool
        var dontAskAgain: Bool
    }

    private(set) var step: Step = .closed
    /// What the user chose for the render at the end of the run being started, until `takeChoice`.
    private(set) var choice: RenderChoice?

    /// A new question: whatever was chosen for an earlier one is not its answer.
    mutating func open() {
        step = .asking
        choice = nil
    }

    /// Yes: on to the options.  Nothing starts yet.
    mutating func yes() {
        if step == .asking { step = .choosingOptions }
    }

    /// Cancel in the options: back to the question, with nothing started.
    mutating func cancelOptions() {
        if step == .choosingOptions { step = .asking }
    }

    /// "Use These Settings": hold the choice and say how processing starts.  nil if the options were not showing.
    mutating func confirm(_ chosen: RenderChoice) -> Start? {
        guard step == .choosingOptions else { return nil }
        choice = chosen
        step = .closed
        return Start(autoRender: true, dontAskAgain: false)
    }

    mutating func no() -> Start {
        reset()
        return Start(autoRender: false, dontAskAgain: false)
    }

    mutating func dontAskAgain() -> Start {
        reset()
        return Start(autoRender: false, dontAskAgain: true)
    }

    /// The run ended and is going to render: hand over the choice, once.
    mutating func takeChoice() -> RenderChoice? {
        defer { choice = nil }
        return choice
    }

    /// The sheet is closing and a run is starting: the choice made stays to be taken at the end of it.
    mutating func finish() { step = .closed }

    /// Nothing is pending: closed, with no choice held.
    mutating func reset() {
        step = .closed
        choice = nil
    }
}
