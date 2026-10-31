import AppKit
import SwiftUI
import StarCore
import logging

/*
 TODO:
 - deal with audio, show audio, checked by default only if present 
 - also notice when the pixelformat or muxer doesn't match the codec and we had to change it
 - if there are initial video settings, say when it's different (have button to revert)
 - show video resolution / aspect ratio
 - include timecode in rendered video so frame numbers show up
 - allow changing filename
 - notice if output video file already exists, and ask if ok to overwrite
 - add 'always overwrite' checkbox to ui and user prefs
 - not all codec/pixel format/muxer combos work, some codecs have no success :(
   (need a better default muxer)
 - record good/bad combos of codec, pixel format and container
 */

// view that renders the video from the frames in the ImageSequenceViewModel
struct RenderVideoSheetView: View {

    @Binding var isVisible: Bool
    let viewModel: ImageSequenceViewModel
    let autoStart: Bool

    init(isVisible: Binding<Bool>,
         viewModel: ImageSequenceViewModel,
         autoStart: Bool = false,
         autoChoice: RenderChoice? = nil)
    {
        _isVisible = isVisible
        self.viewModel = viewModel
        self.autoStart = autoStart
        let configured = viewModel.config.config()
        // A render the pre-processing prompt asked for uses what was chosen there; any other starts from the config.  The
        // config may name settings that do not go together, or ones the bundled ffmpeg does not have, so it is settled
        // on a set that does fit, keeping whatever already does.
        let choice = autoStart ? autoChoice : nil
        let initial = choice ?? RenderChoice.settled(frameRate: configured.frameRate,
                                                      codec: configured.codec,
                                                      encoder: configured.encoder,
                                                      pixelFormat: configured.pixelFormat,
                                                      muxer: configured.muxer)
        _draft = State(initialValue: RenderOptionsDraft(choice: initial))
        _videoFilename = State(initialValue: "\(configured.basename).\(initial.muxer.defaultFileExtension ?? initial.muxer.rawValue)")
    }

    @State private var draft: RenderOptionsDraft

    @State private var isRendering = false
    @State private var renderingError: Error? = nil
    @State private var renderSuccess = false

    @State private var videoFilename: String

    @State private var encodingProgress: Double = 0
    @State private var encodingFrameNumber = 0
    @State private var totalFrames = 0
    
    var body: some View {
        Group {
            if isRendering {
                self.renderingView
            } else if let renderingError {
                self.renderingErrorView
            } else if renderSuccess {
                self.renderingSuccessView
            } else {
                self.renderChoiceView
            }
        }
          .onAppear {
              if autoStart, !isRendering, !renderSuccess, renderingError == nil {
                  startRender()
              }
          }
    }

    private func startRender() {
        self.isRendering = true
        viewModel.renderVideo(named: videoFilename,
                              frameRate: draft.choice.frameRate,
                              encoder: draft.choice.encoder,
                              pixelFormat: draft.choice.pixelFormat,
                              muxer: draft.choice.muxer,
                              resolution: draft.choice.resolution)
        { currentFrame, totalFrames, _ in
            let progress = Double(currentFrame)/Double(totalFrames)
            Task { @MainActor in
                self.encodingProgress = progress
                self.encodingFrameNumber = currentFrame
                self.totalFrames = totalFrames
            }
        } completion: {
            Task { @MainActor in
                self.isRendering = false
                self.renderSuccess = true
            }
        } errorCallback: { error in
            Task { @MainActor in
                self.isRendering = false
                // Cancel put the sheet away already; a stopped render is not an error to report.
                if error is CancellationError {
                    self.isVisible = false
                } else {
                    self.renderingError = error
                }
            }
        }
    }

    // shown when the video is rendering with a progress bar
    private var renderingView: some View {
        HStack {
            Space(width: 20)
            VStack {
                Space(height: 20)
                Text(localized("ui.rendering_file", videoFilename))
                  .font(.title)
                Text(localized("ui.frame_n_of_m", encodingFrameNumber, totalFrames))
                ProgressBarView(progress: $encodingProgress, barColor: .green)
                Button(localized("ui.cancel")) {
                    viewModel.cancelVideoRender()
                }
                  .accessibilityIdentifier("render.cancel")
                Space(height: 20)
            }

            Space(width: 20)
        }
    }
    
    // shown if ffmpeg errors out
    private var renderingErrorView: some View {
        HStack {
            Space(width: 20)
            ScrollView {
                VStack {
                    Space(height: 20)
                    Text(localized("ui.rendering_error", renderingError))
                      .accessibilityIdentifier("render.error")
                      .font(.title)
                    Button(localized("ui.dismiss")) {
                        self.isVisible = false
                    }
                    Space(height: 20)
                }
            }
            Space(width: 20)
        }
    }

    // shown when the video render works with a button to reveal the video in finder
    private var renderingSuccessView: some View {
        HStack {
            Space(width: 20)
            VStack {
                Space(height: 20)
                Text(localized("ui.successfully_rendered", videoFilename))
                  .font(.title)
                  .accessibilityIdentifier("render.done")
                Button(localized("ui.reveal_in_finder")) {
                    let configManager = viewModel.config 
                    revealInFinder(path: "\(configManager.config().outputPath)/\(videoFilename)")
                }
                Button(localized("ui.dismiss")) {
                    self.isVisible = false
                }
                Space(height: 20)
            }
            Space(width: 20)
        }
    }
    
    // the view shown initially, allows the user to choose settings and render a video
    private var renderChoiceView: some View {
        HStack {
            Space(width: 20)
            VStack(alignment: .leading) {
                Spacer()
                  .frame(minWidth: 300)
                Text(localized("ui.render_video_from_n_frames", viewModel.frames.count))
                  .font(.title)

                RenderOptionsView(viewModel: viewModel, draft: $draft)
                  .onChange(of: draft.choice.muxer) {
                      // the file's extension follows the container
                      let ext = draft.choice.muxer.defaultFileExtension ?? draft.choice.muxer.rawValue
                      self.videoFilename = "\(viewModel.config.config().basename).\(ext)"
                  }

                Divider()

                Text(videoFilename)
                
                HStack {
                    Spacer()
                    Button(localized("ui.cancel")) {
                        self.isVisible = false
                    }
                    Button(localized("ui.render")) {
                        startRender()
                    }
                      .disabled(draft.hasRateProblem)
                }
                Spacer()
            }

            Space(width: 20)
        }
          .frame(minWidth: 300)
    }

    /// What the custom frame rate field accepts: from 0.01 to 1000 (the daemon refuses 0).  The desktop's rule is the same:
    /// `gherkin/ui/vectors/constants.json` holds the cases both are checked against.
    static let customFrameRateRange: ClosedRange<Double> = 0.01...1000

    static func customFrameRate(_ text: String) -> Double? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces)),
              value.isFinite, customFrameRateRange.contains(value) else { return nil }
        return value
    }

    /// "0.01", "1000": a bound as the message says it.
    static func rateText(_ value: Double) -> String { String(format: "%g", value) }
}

/// What the render options are set to while they are being chosen: the choice, and the state of the custom frame rate field.
struct RenderOptionsDraft: Equatable {
    var choice: RenderChoice
    /// Whether the Custom row is the picked one.  Not derivable from the rate: Custom starts at the rate in force, which is usually a standard one.
    var customPicked: Bool
    var frameRateString: String

    init(choice: RenderChoice) {
        self.choice = choice
        if case .custom = choice.frameRate { customPicked = true } else { customPicked = false }
        frameRateString = String(format: "%g", choice.frameRate.rawValue)
    }

    /// The custom field holds something that is not a frame rate the render accepts.
    var hasRateProblem: Bool {
        customPicked && RenderVideoSheetView.customFrameRate(frameRateString) == nil
    }
}

/// The render options: frame rate, resolution, codec, encoder, pixel format and container, each with what it is.  Shared by the Render
/// Video sheet and the pre-processing prompt's options step, which differ in what is around it.
struct RenderOptionsView: View {
    let viewModel: ImageSequenceViewModel
    @Binding var draft: RenderOptionsDraft

    private var frameRate: FrameRate {
        get { draft.choice.frameRate }
        nonmutating set { draft.choice.frameRate = newValue }
    }
    private var codec: FFmpegCodec {
        get { draft.choice.codec }
        nonmutating set { draft.choice.codec = newValue }
    }
    private var encoder: FFmpegEncoder {
        get { draft.choice.encoder }
        nonmutating set { draft.choice.encoder = newValue }
    }
    private var pixelFormat: FFmpegPixelFormat {
        get { draft.choice.pixelFormat }
        nonmutating set { draft.choice.pixelFormat = newValue }
    }
    private var muxer: FFmpegMuxer {
        get { draft.choice.muxer }
        nonmutating set { draft.choice.muxer = newValue }
    }
    private var frameRateString: String {
        get { draft.frameRateString }
        nonmutating set { draft.frameRateString = newValue }
    }
    private var customPicked: Bool {
        get { draft.customPicked }
        nonmutating set { draft.customPicked = newValue }
    }

    var body: some View {
        VStack(alignment: .leading) {
                HStack {
                    Picker(localized("ui.frame_rate"), selection: rateSelection) {
                        ForEach(FrameRate.allCases, id: \.self) { frameRate in
                            switch frameRate {
                            case .custom(_):
                                Text(localized("ui.custom_2"))
                            default:
                                Text("\(String(format: "%g", frameRate.rawValue))")
                            }
                        }
                    }
                    if customPicked {
                        TextField("", text: $draft.frameRateString)
                          .frame(maxWidth: 60)
                          .overlay(RoundedRectangle(cornerRadius: 4)
                                     .stroke(customRateProblem ? Color.red : Color.clear))
                          .accessibilityIdentifier("render.custom_frame_rate")
                          .onChange(of: frameRateString) {
                              // Applied as it is typed, so Render is never one keystroke behind what the field says.
                              let digits = frameRateString.filter { "0123456789.".contains($0) }
                              if digits != frameRateString { frameRateString = digits }
                              if let value = RenderVideoSheetView.customFrameRate(digits) { frameRate = .custom(value) }
                          }
                    }
                    Text(localized("ui.frames_per_second"))
                    Text(localized("ui.total_length"))
                    Text(self.totalLengthText)
                }
                  .onChange(of: frameRate) {
                      viewModel.userPreferences.frameRate = frameRate
                      viewModel.frameRate = frameRate
                      // The field shows what it was given; only a change that did not come from it (the picker) rewrites it, or
                      // "1.50" would be reformatted to "1.5" under the cursor.
                      if RenderVideoSheetView.customFrameRate(frameRateString) != frameRate.rawValue {
                          self.frameRateString = String(format: "%g", frameRate.rawValue)
                      }
                  }
                if customPicked && customRateProblem {
                    Text(localized("ui.enter_a_number_from_a_to_b", RenderVideoSheetView.rateText(RenderVideoSheetView.customFrameRateRange.lowerBound), RenderVideoSheetView.rateText(RenderVideoSheetView.customFrameRateRange.upperBound)))
                      .font(.caption)
                      .foregroundColor(.red)
                }
                
                Text(frameRate.description)
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)
                
                Picker(localized("ui.resolution"), selection: $draft.choice.resolution) {
                    ForEach(OutputResolution.allCases, id: \.self) { resolution in
                        Text(resolution == .original
                             ? localized("ui.resolution_original")
                             : resolution.name)
                    }
                }

                Divider()
                
                Picker(localized("ui.codec"), selection: $draft.choice.codec) {
                    ForEach(FFmpegCodec.availableVideoCodecs, id: \.self) { codec in
                        Text(codec.description)
                    }
                }
                  .onChange(of: codec) {
                      viewModel.userPreferences.codec = codec
                      viewModel.codec = codec
                      encoder = codec.availableEncoders[0]
                      viewModel.userPreferences.encoder = encoder
                      viewModel.encoder = encoder
                      pixelFormat = encoder.usablePixelFormats[0]
                      muxer = codec.defaultMuxer(for: encoder) ?? encoder.supportedMuxers[0]
                  }

                Picker(localized("ui.encoder"), selection: $draft.choice.encoder) {
                    ForEach(codec.availableEncoders, id: \.self) { encoder in
                        Text("\(encoder.rawValue) [\(encoder.description)]")
                    }
                }
                  .onChange(of: encoder) {
                      viewModel.userPreferences.encoder = encoder
                      viewModel.encoder = encoder
                      pixelFormat = encoder.usablePixelFormats[0]
                      if !encoder.supportedMuxers.contains(muxer) {
                          muxer = codec.defaultMuxer(for: encoder) ?? encoder.supportedMuxers[0]
                      }
                  }
                
                Picker(localized("ui.pixel_format"), selection: $draft.choice.pixelFormat) {
                    ForEach(encoder.usablePixelFormats, id: \.self) { pixelFormat in
                        Text(pixelFormat.rawValue)
                    }
                }
                  .onChange(of: pixelFormat) {
                      viewModel.userPreferences.pixelFormat = pixelFormat
                      viewModel.pixelFormat = pixelFormat
                  }

                Text(localized("ui.n_components_per_pixel", pixelFormat.numberOfComponents))
                Text(localized("ui.n_bits_per_pixel", pixelFormat.bitsPerPixel))
                Text(localized("ui.bit_depths", pixelFormat.bitDepths))
                
                Divider()

                Picker(localized("ui.container"), selection: $draft.choice.muxer) {
                    ForEach(encoder.supportedMuxers, id: \.self) { muxer in
                        Text(muxer.rawValue)
                    }
                }
                  .onChange(of: muxer) {
                      // set in user prefs and the view model if it changes
                      viewModel.userPreferences.muxer = muxer
                      viewModel.muxer = muxer
                  }

                Text("\(muxer.description) - (.\(muxer.defaultFileExtension ?? muxer.rawValue))")
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The picker's selection: a standard rate, or the Custom row, whose tag (`.custom(24)`) is only a tag.  Picking Custom keeps the
    /// rate in force for the field to start from; it used to put 24 there.
    private var rateSelection: Binding<FrameRate> {
        Binding(
          get: { customPicked ? .custom(24) : frameRate },
          set: { picked in
              if case .custom = picked {
                  customPicked = true
                  frameRate = .custom(frameRate.rawValue)
              } else {
                  customPicked = false
                  frameRate = picked
              }
          })
    }

    private var customRateProblem: Bool { RenderVideoSheetView.customFrameRate(frameRateString) == nil }

    private var totalLengthText: String {
        formatTimeInterval(Double(viewModel.frames.count)/frameRate.rawValue)
    }
}

func formatTimeInterval(_ interval: TimeInterval) -> String {
    let totalSeconds = Int(interval)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let seconds = totalSeconds % 60

    var components: [String] = []
    if hours > 0 {
        components.append("\(hours)h")
    }
    if minutes > 0 || hours > 0 { // include minutes if hours exists
        components.append("\(minutes)m")
    }
    components.append("\(seconds)s")

    return components.joined(separator: " ")
}


struct ProgressBarView: View {
    @Binding var progress: Double // Value between 0.0 and 1.0
    var barColor: Color = .blue
    var backgroundColor: Color = .gray.opacity(0.3)
    var height: CGFloat = 10

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(backgroundColor)
                    .frame(height: height)

                RoundedRectangle(cornerRadius: height / 2)
                    .fill(barColor)
                    .frame(width: CGFloat(progress) * geometry.size.width, height: height)
                    .animation(.easeInOut(duration: 0.2), value: progress)
            }
        }
        .frame(height: height)
    }
}

public func revealInFinder(path: String) {
    let url = URL(fileURLWithPath: path)
    NSWorkspace.shared.activateFileViewerSelecting([url])
}
