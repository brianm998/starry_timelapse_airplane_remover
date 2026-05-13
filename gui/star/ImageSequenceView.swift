import SwiftUI
import StarCore


// the main view of an image sequence 
// user can scrub, play, edit frames, etc

struct ImageSequenceView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return ZStack {
            VStack {
                HStack {
                    if viewModel.interactionMode == .edit {
                        // left panel
                        LeftPanel()
                    }
                    ZStack(alignment: .center) {
                        // selected frame 
                        FrameView()
                          .frame(maxWidth: .infinity, alignment: .center)
                        
                        // show progress bars on top of the image at the bottom
                        ProgressBars()
                    }
                    if viewModel.interactionMode == .edit {
                        // right panel
                        RightPanel()
                    }
                }
                Spacer()
                // buttons below the selected frame 
                BottomControls()
                
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
                
                // scrub slider at the bottom
                if viewModel.imageSequenceSize > 0 {
                    ScrubSliderView()
                }
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding([.bottom, .leading, .trailing])
              .background(viewModel.backgroundColor)

            TabCatcher { viewModel.toggleSidePanels() }
                .frame(width: 0, height: 0)
                .allowsHitTesting(false)
        }
          .alert("Error", isPresented: $viewModel.showErrorAlert) {
              Button("OK") {}
          } message: {
              Text(viewModel.errorMessage)
          }
    }
}
