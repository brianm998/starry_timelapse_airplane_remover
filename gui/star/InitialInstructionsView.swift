import SwiftUI
import StarCore
import logging

struct InitialInstructionsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var maxConcurrentHorizonCalculationsString = ""
    @State private var maxConcurrentHorizonCalculations: Int = 20 {
        didSet {
            if let config = viewModel.config {
                var newConfig = config.config()
                newConfig.maxConcurrentHorizonCalculations = maxConcurrentHorizonCalculations
                config.update(newConfig)
            }
        }
    }

    @State private var pixelReplacementMethod: PixelReplacementMethod = .automatic {
        didSet {
            if let config = viewModel.config {
                var newConfig = config.config()
                newConfig.pixelReplacementMethod = pixelReplacementMethod
                config.update(newConfig)
            }
        }
    }
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return 
          VStack {
              Text("You've just loaded a new image sequence")
                .font(.largeTitle)
                .foregroundColor(.white)

              Spacer()
                .frame(maxHeight: 10)


              ScrollView {
                  Text(
"""
Star offers horizon detection which increases the output quality of videos that include both sky and the earth.

It is best to keep it on unless your video is sky only.  If your video is only sky, then horizon detection is not necessary and will just slow things down.
"""
                  )
              }
                .font(.body)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)


              Text("Is this video of the sky only?")
                .font(.largeTitle)
                .foregroundColor(.white)
              

              HStack {
                  Button() {
                      viewModel.horizonDetectionEnabled = true
                      if let config = viewModel.config {
                          // force the config to save itself now
                          // otherwise the horizonDetectionEnabled may
                          // still be nil
                          var newConfig = config.config()
                          newConfig.horizonDetectionEnabled = viewModel.horizonDetectionEnabled
                          config.update(newConfig)
                      }
                      
                  } label: {
                      ZStack {
                          if viewModel.horizonDetectionEnabled {
                              Color.white
                                .cornerRadius(20)
                              
                              Text("Yes")
                                .font(.title2)
                                .padding(20)
                          } else {
                              Color.blue
                                .cornerRadius(20)
                              
                              Text("No")
                                .foregroundColor(.white)
                                .font(.title2)
                                .padding(20)
                          }
                      }
                        .fixedSize(horizontal: true, vertical: true)
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                  
                  Button() {
                      viewModel.horizonDetectionEnabled = false
                      if let config = viewModel.config {
                          // force the config to save itself now
                          // otherwise the horizonDetectionEnabled may
                          // still be nil
                          var newConfig = config.config()
                          newConfig.horizonDetectionEnabled = viewModel.horizonDetectionEnabled
                          config.update(newConfig)
                      }
                      
                  } label: {
                      ZStack {
                          if viewModel.horizonDetectionEnabled {
                              Color.blue
                                .cornerRadius(20)
                              
                              Text("No")
                                .foregroundColor(.white)
                                .font(.title2)
                                .padding(20)
                          } else {
                              Color.white
                                .cornerRadius(20)
                              
                              Text("No")
                                .font(.title2)
                                .padding(20)
                          }
                      }
                        .fixedSize(horizontal: true, vertical: true)
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
              }

              ScrollView {
                  Text(
"""
Star has offers two similar, but different ways to process this sequence of images:
1. Automatic
2. Selective

Both use the same initial set of processing steps:

 - horizon detection
 - neighboring images star and earth aligned for each frame
 - aligned images combined with custom median logic at each pixel

 Then, Automatic simply uses the combined aligned images as the direct output.  This will likely make small changes to all pixels in every frame.

Automatic mode is good because:
 - no user interaction is required for each frame
 - it treats gets literally all airplane and satellite signals as noise and removes it
 - it also reduces the regular noise floor of each frame, making them cleaner
 - less computer processing is required than selective mode
 
Automatic is not right if:
 - There are much clouds in the sky
 - you want to keep some signals in the video like meteors, satellites, etc.

Selective mode does more processing after computing the combined aligned image for each frame.
This processing eventually results in a layer mask which is used by Star to apply just certain parts of the combined aligned image to the frame being processed.

Selective mode is good because:
 - the user is able to specify exactly what changes to make to each frame
 - more of the original pixels are kept as is
 - clouds in the sky can be ok

Selective mode is not right if:
 - your video has no clouds in the sky and you want all human produced noise removed (use Automatic mode)
 - you don't want to have to verify the edits on each frame

"""
                  )
              }
                .font(.body)
                .foregroundColor(.white)
                .fixedSize(horizontal: false, vertical: true)
              
              Space(height: 20)
              
              Text("What processing method do you want to use for this image sequence?")
                .font(.largeTitle)
                .foregroundColor(.white)
              
              HStack {
                  
                  Button() {
                      self.pixelReplacementMethod = .automatic
                  } label: {
                      ZStack {
                          switch self.pixelReplacementMethod {
                          case .automatic:
                              Color.blue
                                .cornerRadius(20)

                              Text("Automatic")
                                .foregroundColor(.white)
                                .font(.title2)
                                .padding(20)
                              
                          case .selective:
                              Color.white
                                .cornerRadius(20)
                              Text("Automatic")

                                .font(.title2)
                                .padding(20)
                          }
                      }
                        .fixedSize(horizontal: true, vertical: true)
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                  
                  Button() {
                      self.pixelReplacementMethod = .selective
                  } label: {
                      ZStack {
                          switch self.pixelReplacementMethod {
                          case .selective:
                              Color.blue
                                .cornerRadius(20)

                              Text("Selective")
                                .foregroundColor(.white)
                                .font(.title2)
                                .padding(20)
                              
                          case .automatic:
                              Color.white
                                .cornerRadius(20)
                              Text("Selective")

                                .font(.title2)
                                .padding(20)
                          }
                      }
                        .fixedSize(horizontal: true, vertical: true)
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
              }
              //                }
              //                  .padding(20)
              //                  .background(.gray)
              //                  .cornerRadius(20)

              Space(height: 20)

              Button() {
                  viewModel.shouldShowInitialInstructions = false
                  viewModel.showIgnoreLowerBar = false

                  if viewModel.horizonDetectionEnabled {

                      viewModel.processHorizonForAllFrames() {
                          Log.d("FUCKING CLOSURE CALLED")
                          // after we get horizons for all frames, then either
                          switch self.pixelReplacementMethod {
                          case .automatic:
                              // render all frames automatically
                              viewModel.renderAllFramesAutomatic()
                              
                          case .selective:
                              // or show a dialog to tell new users what to do next
                              viewModel.showProcessingOptionsSheet = true
                          }
                      }
                  } else {

                      viewModel.ignoreLowerPixels = 0

                      switch self.pixelReplacementMethod {
                      case .automatic:
                          // render all frames automatically
                          viewModel.renderAllFramesAutomatic()
                          
                      case .selective:
                          // or show a dialog to tell new users what to do next
                          viewModel.showProcessingOptionsSheet = true
                      }
                  }
              } label: {
                  ZStack {
                      Color.blue
                        .cornerRadius(20)

                      HStack {

                          Text("Start Processing")
                            .foregroundColor(.white)
                            .font(.title2)

                          switch self.pixelReplacementMethod {
                          case .automatic:
                              // render all frames automatically
                              Text("automatically")
                                .font(.title2)
                                .foregroundColor(.white)
                              
                          case .selective:
                              // or show a dialog to tell new users what to do next
                              Text("with both user and machine learning selection")
                                .font(.title2)
                                .foregroundColor(.white)
                          }                                                    
                          
                          if viewModel.horizonDetectionEnabled {
                              Text("using horizon detection")
                                .font(.title2)
                                .foregroundColor(.white)
                          }
                      }
                        .fixedSize(horizontal: true, vertical: true)
                        .padding(20)
                  }
                    .fixedSize(horizontal: true, vertical: true)
              }
                .buttonStyle(PlainButtonStyle()) // XXX these styles suck
          }
          .padding(20)
          .background(.gray)
          .cornerRadius(20)
          .fixedSize(horizontal: false, vertical: false) // let it grow vertically, not horizonta
        
        //            Spacer()
        //              .frame(maxWidth: 200)


        
        //        .frame(maxWidth: .infinity, maxHeight: .infinity)
        //        Spacer()
        //          .frame(maxHeight: 200)


        //.frame(maxWidth: .infinity, maxHeight: .infinity)
          .onAppear {
              if let config = viewModel.config {
                  var newConfig = config.config()
                  newConfig.maxConcurrentHorizonCalculations = maxConcurrentHorizonCalculations
                  config.update(newConfig)
              }
          }
    }
}
