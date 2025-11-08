import SwiftUI
import StarCore
import logging

struct InitialInstructionsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var horizonDetectionEnabled = true
    @State private var tripodHeadWasMoving = false
    @State private var automaticProcessing = true
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return 
          VStack {
              Text("How should Star process this video?")
                .font(.largeTitle)
                .foregroundColor(.white)

              Grid {

                  GridRow {
                      HStack {
                          Spacer()
                          Text("With horizon detection")
                            .font(.title2)
                            .foregroundColor(.white)
                      }
                      Toggle("", isOn: $horizonDetectionEnabled)
                  }
                  GridRow {
                      HStack {
                          Spacer()
                          Text("Using moving tripod head")
                            .font(.title2)
                            .foregroundColor(horizonDetectionEnabled ? .white : .black)
                      }
                      Toggle("", isOn: $tripodHeadWasMoving)
                  }
                    .disabled(!horizonDetectionEnabled)
                  GridRow {
                      HStack {
                          Spacer()
                          Text("Automatically")
                            .font(.title2)
                            .foregroundColor(.white)
                      }
                      Toggle("", isOn: $automaticProcessing)
                  }
              }
                .fixedSize(horizontal: true, vertical: false)

              Space(height: 20)
              
              Text("Automatic processing removes all airplanes and satellites, as well as moving car headlights on the ground.  Works best with clear skies.")
                .font(.title3)
                .foregroundColor(.white)
              
              Text("Not using Automatic processing removes only the signals you want removed, allowing more control.  Supports moving clouds better.  Requires more user interaction before final rendering.")
                .font(.title3)
                .foregroundColor(.white)

              Space(height: 20)

              HStack {
                  Button {
                      viewModel.shouldShowInitialInstructions = false
                  } label: {
                      ZStack {
                          Color.white
                            .cornerRadius(20)

                          Text("Cancel")
                            .font(.title2)
                            .padding(20)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck

                  Button {
                      startProcessing()
                      
                  } label: {
                      ZStack {
                          Color.blue
                            .cornerRadius(20)

                          Text("Start Processing")
                            .font(.title2)
                            .padding(20)
                            .foregroundColor(.white)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
              }
                .fixedSize(horizontal: true, vertical: true)
          }
          .padding(20)
          .background(.gray)
          .cornerRadius(20)
    }
    

    private func startProcessing() {
        Log.d("Start")

        let pixelReplacementMethod: PixelReplacementMethod = automaticProcessing ? .automatic : .selective
        
        if let config = viewModel.config {
            var newConfig = config.config()
            newConfig.pixelReplacementMethod = pixelReplacementMethod
            newConfig.horizonDetectionEnabled = horizonDetectionEnabled
            newConfig.tripodHeadWasMoving = tripodHeadWasMoving
            config.update(newConfig)
        }
        viewModel.horizonDetectionEnabled = horizonDetectionEnabled
        viewModel.shouldShowInitialInstructions = false


        viewModel.showIgnoreLowerBar = false

        if viewModel.horizonDetectionEnabled {

            viewModel.processHorizonForAllFrames() {
                Log.d("FUCKING CLOSURE CALLED")
                // after we get horizons for all frames, then either
                switch pixelReplacementMethod {
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

            switch pixelReplacementMethod {
            case .automatic:
                // render all frames automatically
                viewModel.renderAllFramesAutomatic()
                
            case .selective:
                // or show a dialog to tell new users what to do next
                viewModel.showProcessingOptionsSheet = true
            }
        }
    }
}
