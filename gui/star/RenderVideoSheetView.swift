import AppKit
import SwiftUI
import StarCore
import logging

struct RenderVideoSheetView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    @Binding var isVisible: Bool

    @State private var frameRateString = "24"
    @State private var frameRate: FrameRate = .fps_24
    @State private var codec: FFmpegCodec = .prores
    @State private var pixelFormat: FFmpegPixelFormat = .yuv444p10le
    @State private var muxer: FFmpegMuxer = .mov

    @State private var isRendering = false
    @State private var renderingError: Error? = nil
    @State private var renderSuccess = false

    @State private var videoFilename: String? = nil

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
              .onAppear {
                  if let config = viewModel.config {
                      videoFilename = "\(config.config().basename).\(muxer.rawValue)"
                  } else {
                      videoFilename = "star-output-video.\(muxer.rawValue)"
                  }
              }
        }
    }

    private var renderingView: some View {
        HStack {
            Space(width: 20)
            VStack {
                Space(height: 20)
                if let videoFilename {
                    Text("Rendering \(videoFilename)")
                      .font(.title)
                } else {
                    Text("Rendering..")
                      .font(.title)
                }
                Text("frame \(encodingFrameNumber) of \(totalFrames)")
                ProgressBarView(progress: $encodingProgress, barColor: .green)
                Space(height: 20)
            }

            Space(width: 20)
        }
    }
    
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
    
    private var renderingSuccessView: some View {
        HStack {
            Space(width: 20)
            VStack {
                Space(height: 20)
                if let videoFilename {
                    Text("Successfully Rendered \(videoFilename)")
                      .font(.title)
                } else {
                    Text("Successfully Rendered")
                      .font(.title)
                }
                if let videoFilename {
                    Button("Reveal In Finder") {
                        revealInFinder(path: videoFilename)
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
    
    // the view shown initially
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
                }
                .onChange(of: frameRate) {
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
                        Text(codec.name ?? "Not Named")
                    }
                }
                  .onChange(of: codec) {
                      pixelFormat = codec.pixelFormats[0]
                      muxer = codec.supportedMuxers[0]
                  }

                Text(codec.description)
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)
                
                Divider()
                
                Picker("Pixel Format", selection: $pixelFormat) {
                    ForEach(codec.pixelFormats, id: \.self) { pixelFormat in
                        Text(pixelFormat.rawValue)
                    }
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

                if let videoFilename {
                    Text(videoFilename)
                }
                
                HStack {
                    Spacer()
                    Button("Cancel") {
                        self.isVisible = false
                    }
                    Button("Render") {
                        if let videoFilename {
                            self.isRendering = true
                            viewModel.renderVideo(named: videoFilename,
                                                  frameRate: frameRate,
                                                  codec: codec,
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
                }
                Spacer()
            }

            Space(width: 20)
        }
          .frame(minWidth: 300)
    }
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
