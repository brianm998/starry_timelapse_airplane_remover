import SwiftUI

struct InitialInstructionsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
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

                        Toggle("Horizon Detection Enabled",
                               isOn: $viewModel.horizonDetectionEnabled)
                          .foregroundColor(.white)

                        
                       // expand this text, and add some buttons?
                       // add don't show again, put in preferenes
                        Button() {
                            viewModel.shouldShowInitialInstructions = false
                            if viewModel.horizonDetectionEnabled {
                                viewModel.showIgnoreLowerBar = false
                                viewModel.processHorizonForAllFrames()
                            }
                        } label: {
                            if viewModel.horizonDetectionEnabled {
                                Text("Run Horizon Detection")
                            } else {
                                Text("Close")
                            }
                        }
                          .buttonStyle(ShrinkingButton(.clear))
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
        }
    }
}
