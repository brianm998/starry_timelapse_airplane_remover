import AppKit
import SwiftUI
import StarCore
import logging

/*
 TODO:
 - deal with audio, show audio, checked by default only if present 
 - also notice when the pixelformat or muxer doesn't match the codec and we had to change it
 - if there are initial video settings, say when it's different (have button to revert)
 - add cancel button (keep track of task)
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

    init(isVisible: Binding<Bool>,
         viewModel: ImageSequenceViewModel)
    {
        _isVisible = isVisible
        self.viewModel = viewModel
        if let config = viewModel.config {
            if let frameRate = config.config().frameRate {
                _frameRate = State(initialValue: frameRate)
                _frameRateString = State(initialValue: String(format: "%g", frameRate.rawValue))
            } else {
                _frameRate = State(initialValue: viewModel.frameRate)
                _frameRateString = State(initialValue: String(format: "%g", viewModel.frameRate.rawValue))
            }
            
            if let codec = config.config().codec {
                _codec = State(initialValue: codec)
            } else {
                _codec = State(initialValue: viewModel.codec)
            }
            if let encoder = config.config().encoder {
                _encoder = State(initialValue: encoder)
            } else {
                _encoder = State(initialValue: viewModel.encoder)
            }
            if let pixelFormat = config.config().pixelFormat {
                _pixelFormat = State(initialValue: pixelFormat)
            } else {
                _pixelFormat = State(initialValue: viewModel.pixelFormat)
            }

            
            if let muxer = config.config().muxer {
                _muxer = State(initialValue: muxer)
                _videoFilename = State(initialValue: "\(config.config().basename).\(muxer.rawValue)")
            } else {
                _muxer = State(initialValue: viewModel.muxer)
                _videoFilename = State(initialValue: "\(config.config().basename).\(viewModel.muxer.rawValue)")
            }
        } else {
            _videoFilename = State(initialValue: "star-output-video.\(viewModel.muxer.rawValue)")
            _frameRate = State(initialValue: viewModel.frameRate)
            _frameRateString = State(initialValue: String(format: "%g", viewModel.frameRate.rawValue))
            _codec = State(initialValue: viewModel.codec)
            _encoder = State(initialValue: viewModel.encoder)
            _pixelFormat = State(initialValue: viewModel.pixelFormat)
            _muxer = State(initialValue: viewModel.muxer)
        }

        // check to see if encoder, pixelformat and muxer are in the list for this codex,
        // and if not, use different ones that are.

        if !self.codec.encoders.contains(self.encoder) {
            Log.d("encoder \(self.encoder) not applicibale for codec \(self.codec)")
            _encoder = State(initialValue: self.codec.encoders[0])
        }
        
        // note this in the UI
        if !self.encoder.pixelFormats.contains(self.pixelFormat) {
            Log.w("pixel format \(self.pixelFormat) not applicable for encoder \(self.encoder)")
            _pixelFormat = State(initialValue: encoder.pixelFormats[0])
        }

        // note this in the UI
        if !self.codec.supportedMuxers.contains(self.muxer) {
            _muxer = State(initialValue: codec.supportedMuxers[0])
        }
    }
    
    @State private var frameRateString: String
    @State private var frameRate: FrameRate 
    @State private var codec: FFmpegCodec 
    @State private var encoder: FFmpegEncoder
    @State private var pixelFormat: FFmpegPixelFormat
    @State private var muxer: FFmpegMuxer

    @State private var isRendering = false
    @State private var renderingError: Error? = nil
    @State private var renderSuccess = false

    @State private var videoFilename: String

    @State private var encodingProgress: Double = 0
    @State private var encodingFrameNumber = 0
    @State private var totalFrames = 0
    
    var body: some View {
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

    // shown when the video is rendering with a progress bar
    private var renderingView: some View {
        HStack {
            Space(width: 20)
            VStack {
                Space(height: 20)
                Text("Rendering \(videoFilename)")
                  .font(.title)
                Text("frame \(encodingFrameNumber) of \(totalFrames)")
                ProgressBarView(progress: $encodingProgress, barColor: .green)
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
                    Text("rendering error: \(renderingError)")
                      .font(.title)
                    Button("Dismiss") {
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
                Text("Successfully Rendered \(videoFilename)")
                  .font(.title)
                Button("Reveal In Finder") {
                    if let configManager = viewModel.config {
                        revealInFinder(path: "\(configManager.config().outputPath)/\(videoFilename)")
                    }
                }
                Button("Dismiss") {
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
                Text("Render video from \(viewModel.frames.count) frames")
                  .font(.title)
                
                HStack {
                    Picker("Frame Rate", selection: $frameRate) {
                        ForEach(FrameRate.allCases, id: \.self) { frameRate in
                            switch frameRate {
                            case .custom(_):
                                Text("custom")
                            default:
                                Text("\(String(format: "%g", frameRate.rawValue))")
                            }
                        }
                    }
                    switch frameRate {
                    case .custom(let customFrameRate):
                        TextField("",
                                  text: $frameRateString)
                        //                  .focused($focusedField, equals: .frameRate)
                          .frame(maxWidth: 60)
                          .onSubmit {
                              let filtered = viewModel.trashLevelString.filter { "0123456789.-".contains($0) }
                              if let newValue = Double(filtered),
                                 newValue >= 0,
                                 newValue <= 1000
                              {
                                  self.frameRate = .custom(newValue)
                                  //self.frameRateString = String(format: "%g", newValue)
                              }
                          }
                        
                    default:
                        Group { }
                    }
                    Text("frames per second")
                    Text(" - Total Length: ")
                    Text(self.totalLengthText)
                }
                  .onChange(of: frameRate) {
                      viewModel.userPreferences.frameRate = frameRate
                      viewModel.frameRate = frameRate
                      
                      switch frameRate {
                      case .custom(let customFrameRate):
                          self.frameRateString = String(format: "%g", customFrameRate)
                          
                      default:
                          break
                      }
                  }
                
                Text(frameRate.description)
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)
                
                Divider()
                
                Picker("Codec", selection: $codec) {
                    ForEach(FFmpegCodec.availableVideoCodecs, id: \.self) { codec in
                        Text(codec.description ?? "Not Named")
                    }
                }
                  .onChange(of: codec) {
                      viewModel.userPreferences.codec = codec
                      viewModel.codec = codec
                      encoder = codec.encoders[0]
                      viewModel.userPreferences.encoder = encoder
                      viewModel.encoder = encoder
                      pixelFormat = encoder.pixelFormats[0]
                      muxer = codec.supportedMuxers[0]
                  }

                Picker("Encoder", selection: $encoder) {
                    ForEach(codec.encoders, id: \.self) { encoder in
                        Text("\(encoder.rawValue) [\(encoder.description)]")
                    }
                }
                  .onChange(of: encoder) {
                      viewModel.userPreferences.encoder = encoder
                      viewModel.encoder = encoder
                      pixelFormat = encoder.pixelFormats[0]
                  }
                
                Picker("Pixel Format", selection: $pixelFormat) {
                    ForEach(encoder.pixelFormats, id: \.self) { pixelFormat in
                        Text(pixelFormat.rawValue)
                    }
                }
                  .onChange(of: pixelFormat) {
                      viewModel.userPreferences.pixelFormat = pixelFormat
                      viewModel.pixelFormat = pixelFormat
                  }

                Text("\(pixelFormat.numberOfComponents) components per pixel")
                Text("\(pixelFormat.bitsPerPixel) bits per pixel")
                Text("bit depths: \(pixelFormat.bitDepths)")
                
                Divider()

                Picker("Container", selection: $muxer) {
                    ForEach(codec.supportedMuxers, id: \.self) { muxer in
                        Text(muxer.rawValue)
                    }
                }
                  .onChange(of: muxer) {
                      // set in user prefs and the view model if it changes
                      viewModel.userPreferences.muxer = muxer
                      viewModel.muxer = muxer
                      
                      if let config = viewModel.config {
                          self.videoFilename = "\(config.config().basename).\(muxer.rawValue)"
                      } else {
                          self.videoFilename = "star-output-video.\(muxer.rawValue)"
                      }
                  }

                Text(muxer.description)
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)
                
                Divider()

                Text(videoFilename)
                
                HStack {
                    Spacer()
                    Button("Cancel") {
                        self.isVisible = false
                    }
                    Button("Render") {
                        self.isRendering = true
                        viewModel.renderVideo(named: videoFilename,
                                              frameRate: frameRate,
                                              encoder: encoder,
                                              pixelFormat: pixelFormat,
                                              muxer: muxer)
                        { currentFrame, totalFrames in
                            let progress = Double(currentFrame)/Double(totalFrames)
                            Task { @MainActor in
                                self.encodingProgress = progress
                                self.encodingFrameNumber = currentFrame
                                self.totalFrames = totalFrames
                            }
                        } completion: {
                            // success
                            //self.isVisible = false
                            Task { @MainActor in 
                                self.isRendering = false
                                self.renderSuccess  = true
                            }
                        } errorCallback: { error in
                            // error
                            //self.isVisible = false
                            Task { @MainActor in 
                                self.isRendering = false
                                self.renderingError = error
                            }
                        }
                    }
                }
                Spacer()
            }

            Space(width: 20)
        }
          .frame(minWidth: 300)
    }

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
