import SwiftUI
import StarCore


// the main view of an image sequence 
// user can scrub, play, edit frames, etc

struct ImageSequenceView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        VStack {
            let shouldShowProgress =
              viewModel.renderingCurrentFrame            ||
              viewModel.updatingFrameBatch               ||
              viewModel.renderingAllFrames
            
            
            // selected frame 
            ZStack {
                FrameView(interactionMode: self.$viewModel.interactionMode,
                          showFullResolution: self.$viewModel.showFullResolution)
                  .frame(maxWidth: .infinity, alignment: .center)
                  .overlay(
                    ProgressView() // XXX this overlay sucks, change it
                      .scaleEffect(8, anchor: .center) // this is blocky scaled up 
                      .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                      .frame(maxWidth: 200, maxHeight: 200)
                      .opacity(shouldShowProgress ? 0.8 : 0)
                  )

                  .overlay(
                    ProgressView() // XXX this overlay sucks, change it
                      .scaleEffect(18, anchor: .center) // this is blocky scaled up 
                      .progressViewStyle(CircularProgressViewStyle(tint: .green))
                      .frame(maxWidth: 200, maxHeight: 200)
                      .opacity(viewModel.inTransition || viewModel.loadingOutliers ? 0.8 : 0)
                  )
                
                // show progress bars on top of the image at the bottom
                ProgressBars()
            }
            Spacer()
            // buttons below the selected frame 
            BottomControls()
              .disabled(self.viewModel.inTransition || self.viewModel.loadingOutliers)
            
            if viewModel.interactionMode == .edit,
               viewModel.showFilmstrip
            {
                Spacer().frame(maxHeight: 30)
                // the filmstrip at the bottom
                FilmstripView(imageSequenceView: self)
                  .frame(maxWidth: .infinity)
                  .transition(.slide)
                Spacer().frame(minHeight: 15, maxHeight: 25)
            }
            
            // scub slider at the bottom
            if viewModel.imageSequenceSize > 0 {
                ScrubSliderView()
            }
        }

          .frame(maxWidth: .infinity, maxHeight: .infinity)
          .padding([.bottom, .leading, .trailing])
          .background(viewModel.backgroundColor)
        
        
          .alert(isPresented: $viewModel.showErrorAlert) {
              Alert(title: Text("Error"),
                    message: Text(viewModel.errorMessage),
                    primaryButton: .default(Text("Ok")) { viewModel.sequenceLoaded = false },
                    secondaryButton: .default(Text("Sure")) { viewModel.sequenceLoaded = false } )
              
          }
    }
}
