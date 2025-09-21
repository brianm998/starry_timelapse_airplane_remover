import SwiftUI

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
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return ZStack {
            Rectangle()
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .background(.gray)
              .opacity(0.5)

            VStack {
                Spacer()
                  .frame(maxHeight: 200)
                HStack {
                    Spacer()
                      .frame(maxWidth: 200)
                    VStack {
                        Text("You've just loaded a new image sequence")
                          .font(.largeTitle)
                          .foregroundColor(.white)

                        Spacer()
                          .frame(maxHeight: 10)

                        Text("""
                               Does this image sequence include the horizon?
                               Or is it pointing only at the sky?
                               If there is no ground in your image at all, turn off horizon detection below.
                               Horizion detection is used to distinguish between ground and sky so that when replacing pixels close to the horizon we can ensure a better match.
                               """)
                          .font(.title2)
                          .foregroundColor(.white)

                        HStack {
                            Text("Process ")
                              .foregroundColor(.white)
                            TextField("\(maxConcurrentHorizonCalculations)",
                                      text: $maxConcurrentHorizonCalculationsString)
//                              .focused($focusedField, equals: .trashLevel)
                              .frame(maxWidth: 60)
                              .onSubmit {
                                  let filtered = maxConcurrentHorizonCalculationsString.filter { "0123456789".contains($0) }
                                  if let newValue = Int(filtered),
                                     newValue >= 0
                                  {
                                      maxConcurrentHorizonCalculations = newValue
                                      maxConcurrentHorizonCalculationsString = "\(newValue)"
                                  }
//                                  self.focusedField = nil
                              }
                            Text(" at once")
                              .foregroundColor(.white)
                        }

                        HStack {
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
                                
                                viewModel.shouldShowInitialInstructions = false
                                viewModel.showProcessingOptionsSheet = true
                            } label: {
                                Text("No, this image sequence does not include a horizon.\nHorizon Detection is not necessary.")
                            }
                              .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                            // this one is transparent totally :(

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
                                
                                viewModel.shouldShowInitialInstructions = false

                                viewModel.showIgnoreLowerBar = false
                                viewModel.processHorizonForAllFrames()

                            } label: {
                                Text("Yes, this image sequence includes a horizon.\nRun Horizon Detection on it.")
                            }
                              .buttonStyle(.borderedProminent)
                            // this style is bad too :(
                        }
                    }
                      .padding(20)
                      .background(.gray)
                      .cornerRadius(20)

                    Spacer()
                      .frame(maxWidth: 200)
                }
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                Spacer()
                  .frame(maxHeight: 200)
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .onAppear {
                  if let config = viewModel.config {
                      var newConfig = config.config()
                      newConfig.maxConcurrentHorizonCalculations = maxConcurrentHorizonCalculations
                      config.update(newConfig)
                  }
             }
        }
    }
}
