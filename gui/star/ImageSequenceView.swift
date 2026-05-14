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
                HStack(spacing: 0) {
                    if viewModel.interactionMode == .edit {
                        // left panel with processing controls
                        LeftPanel()
                    } else if viewModel.interactionMode == .grid {
                        // left panel with view mode selector
                        GridLeftPanel()
                    }

                    switch viewModel.interactionMode {
                    case .grid:
                        // full-width grid of thumbnails
                        GridView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)

                    case .scrub, .edit:
                        ZStack(alignment: .center) {
                            // selected frame
                            FrameView()
                              .frame(maxWidth: .infinity, alignment: .center)

                            // show progress bars on top of the image at the bottom
                            ProgressBars()
                        }
                    }

                    if viewModel.interactionMode == .edit {
                        // right panel with editing tools
                        RightPanel()
                    } else if viewModel.interactionMode == .grid {
                        // right panel with frame info
                        GridRightPanel()
                    }
                }

                // show left-panel collapse button in grid mode when panel is hidden
                if viewModel.interactionMode == .grid,
                   !viewModel.rightPanelShowing
                {
                    HStack {
                        Spacer()
                        Button {
                            viewModel.rightPanelShowing = true
                        } label: {
                            Image(systemName: "chevron.left")
                                .foregroundColor(.white)
                        }
                        .buttonStyle(.plain)
                        .padding(.trailing, 8)
                    }
                }

                Spacer()
                // buttons below the selected frame
                BottomControls()

                if (viewModel.interactionMode == .edit || viewModel.interactionMode == .grid),
                   viewModel.showFilmstrip
                {
                    Spacer().frame(maxHeight: 30)
                    // the filmstrip at the bottom
                    FilmstripView()
                      .frame(maxWidth: .infinity)
                      .transition(.slide)
                    Spacer().frame(minHeight: 15, maxHeight: 25)
                }

                // scrub slider at the bottom (not needed in grid mode)
                if viewModel.imageSequenceSize > 0,
                   viewModel.interactionMode != .grid
                {
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
