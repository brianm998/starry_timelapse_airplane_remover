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
    
    var body: some View {
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

                
                HStack {
                    Spacer()
                    Button("Cancel") {
                        self.isVisible = false
                    }
                    Button("Render") {
                        Log.d("XXX FUCKING RENDER HERE with frame rate \(frameRate.rawValue) fps, codec \(codec.rawValue) pixel format \(pixelFormat.rawValue)")
                        self.isVisible = false
                    }
                }
                Spacer()
            }

            Space(width: 20)
        }
          .frame(minWidth: 300)
    }
}

