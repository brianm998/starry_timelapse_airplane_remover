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

              Space(height: 20)
              HStack {
                  Text("What processing method do you want to use for this image sequence?")
                    .font(.largeTitle)
                    .foregroundColor(.white)
                  
                  
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
                  // this one is transparent totally :(

                  Space(width: 80)
                  
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
              HStack {
                  Text("Does This Video include the horizon?")
                    .font(.largeTitle)
                    .foregroundColor(.white)
                  

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
                              Color.white
                                .cornerRadius(20)
                              
                              Text("No")
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
                  // this one is transparent totally :(

                  Space(width: 80)
                  
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
                              Color.blue
                                .cornerRadius(20)
                              
                              Text("Yes")
                                .foregroundColor(.white)
                                .font(.title2)
                                .padding(20)
                          } else {
                              Color.white
                                .cornerRadius(20)
                              
                              Text("Yes")
                                .font(.title2)
                                .padding(20)
                          }
                      }
                        .fixedSize(horizontal: true, vertical: true)
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
              }

              if viewModel.horizonDetectionEnabled {
                  Text("This sequence has a horizon visible")
                    .foregroundColor(.white)
              } else {
                  Text("This sequence has no visible horizon")
                    .foregroundColor(.white)
              }

              switch self.pixelReplacementMethod {
              case .automatic:
                  // render all frames automatically
                  Text("Will process automatically")
                    .foregroundColor(.white)
                  
              case .selective:
                  // or show a dialog to tell new users what to do next
                  Text("Will process with both user and machine learning selection")
                    .foregroundColor(.white)
              }
              
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
                      
                      Text("Start Processing")
                        .foregroundColor(.white)
                        .font(.title2)
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
