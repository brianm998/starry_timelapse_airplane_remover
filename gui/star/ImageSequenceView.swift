import SwiftUI
import StarCore


// the main view of an image sequence 
// user can scrub, play, edit frames, etc

struct ImageSequenceView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        return VStack {
            
            let shouldShowProgress = // XXX fuck this
              false && (
              viewModel.renderingCurrentFrame            ||
              viewModel.updatingFrameBatch               ||
              viewModel.renderingAllFrames)

            ZStack(alignment: .center) {
                // selected frame 
                FrameView()
                  .frame(maxWidth: .infinity, alignment: .center)
                
                // show progress bars on top of the image at the bottom
                ProgressBars()

                if viewModel.interactionMode == .edit {
                    // left panel
                    HStack {
                        ZStack(alignment: .leading) {
                            LeftPanel()
                        }
                        Spacer()
                    }

                    // right panel
                    HStack {
                        Spacer()
                        ZStack(alignment: .trailing) {
                            RightPanel()
                              .frame(alignment: .trailing)
                        }
                    }
                }
            }
            Spacer()
            // buttons below the selected frame 
            BottomControls()
//              .disabled(self.viewModel.inTransition || self.viewModel.loadingOutliers)
            
            if viewModel.interactionMode == .edit,
               viewModel.showFilmstrip
            {
                Spacer().frame(maxHeight: 30)
                // the filmstrip at the bottom
                FilmstripView()
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
