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
        // An overlay rather than another member of the `ZStack` above, so that the modal
        // cannot become part of this window's minimum size — the same reason the warning
        // banner in `ContentView` is one.  Conditioned on the run still being live, so a
        // run that finishes or is stopped takes the modal with it.
          .overlay {
              if viewModel.processingModalShowing,
                 viewModel.isProcessingFrames
              {
                  ProcessingModalView()
              }
          }
        // Also an overlay, for the same reason — and because the sheets are attached
        // inside `BottomRightView`'s edit-mode branch, which a sequence re-opened from a
        // config file is not in.  Stood down the moment a run starts, so the panel cannot
        // still be sitting over the frames describing a state its own button changed.
          .overlay {
              if viewModel.sequenceProgressModalShowing,
                 !viewModel.isProcessingFrames
              {
                  SequenceProgressModalView()
              }
          }
          .alert(localized("ui.error"), isPresented: $viewModel.showErrorAlert) {
              Button(localized("ui.ok")) {}
          } message: {
              Text(viewModel.errorMessage)
          }
        // Asked after a reference horizon is painted over an already-processed sequence,
        // because saying yes puts a span of frames back through the pipeline.  Attached
        // here, and not in the painter's own toolbar or the right panel that opens it:
        // saving closes the painter, and an alert hung off a view that is going away goes
        // with it.  This view outlives both, and is not inside an interaction-mode branch
        // — the trap the sheets in `BottomRightView` fell into.
        //
        // "Later" is the cancel role, so Escape lands on the answer that starts nothing.
          .alert(localized("ui.horizon_refinement_prompt_title"),
                 isPresented: $viewModel.showHorizonRefinementPrompt)
          {
              Button(localized("ui.horizon_refinement_later"), role: .cancel) {
                  viewModel.deferHorizonRefinement()
              }
              Button(localized("ui.horizon_refinement_now")) {
                  viewModel.reprocessHorizonsForUpdatedReferences()
              }
                .keyboardShortcut(.defaultAction)
          } message: {
              Text(viewModel.horizonRefinementPromptMessage)
          }
    }
}
