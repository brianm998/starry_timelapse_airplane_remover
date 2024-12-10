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
                        
                      // this copy could be better, more consise and to the point
                        Text("""
                               Before processing a new image sequence, it is a good idea to set a bottom area to not process.
                               This can speed up proccessing, ignoring the ground in the video.
                               You are now seeing the edit frame mode, where you can adjust the red area at the bottom of the frame.
                               Drag on the orange top or arrows on the side of it to adjust what part of the frame is processed.
                               If this image sequence was shot on a moving tripod head, then it's a good idea to scrub through the video ('s' on keyboard)
                               and make sure that none of the sky area ends up in the red box.
                               """)
                          .font(.title2)
                          .foregroundColor(.white)
                       // expand this text, and add some buttons?
                       // add don't show again, put in preferenes
                        Button() {
                            viewModel.shouldShowInitialInstructions = false
                        } label: {
                            Text("Close")
                        }
                          .buttonStyle(ShrinkingButton())
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
