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
//                ZStack(alignment: .center) {
                    FrameView(interactionMode: $viewModel.interactionMode,
                              showFullResolution: $viewModel.showFullResolution)
                      .frame(maxWidth: .infinity, alignment: .center)
                    
                    // show progress bars on top of the image at the bottom
                    ProgressBars()
//                }

                // left panel
                    if viewModel.interactionMode == .edit {
                        HStack {
                            ZStack(alignment: .leading) {
                                self.leftPanel
                            }
                            Spacer()
                        }
                }
                


                // right panel
                if viewModel.interactionMode == .edit {
                    HStack {
                        Spacer()
                        ZStack(alignment: .trailing) {
                            self.rightPanel
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

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    var leftPanel: some View {
        @Bindable var viewModel = viewModel
        return Group {
            if viewModel.leftPanelShowing {
                VStack(alignment: .leading) {
                    ScrollView() {
                        Text("Show:")
                          .foregroundColor(.white)

                        VerticalLimitedSelectionPicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                            if viewModel.currentFrameView.hasImage(type: value) {
                                Text(value.shortName)
                                  .foregroundColor(isEnabled ? .black : .gray)
                                  .padding(4)
                                  .onTapGesture { _ in
                                      viewModel.frameViewMode = value
                                  }
                            } else {
                                Text(value.shortName)
                                  .foregroundColor(/*isEnabled ? .white : */ .gray)
                                  .padding(4)
                            }
                        }
                          .background(Color(red: foobar, green: foobar, blue: foobar2))
                          .opacity(1.0)
                          .disabled(viewModel.videoPlaying)
                          .help("""
                                  Show each frame as either the original   
                                  or with star processing applied.
                                  """) // XXX does this work anymore?
                          .cornerRadius(5)
                        
                        Spacer()
                          .frame(maxHeight: 10)
                        
                        
                    }
                      .defaultScrollAnchor(.bottom)
                      .frame(maxHeight: .infinity, alignment: .bottom)
                    
                    Button() {
                        viewModel.leftPanelShowing = false
                    } label: {
                        Image(systemName: "chevron.left.2")
                          .foregroundColor(.black)
                    }
                      .buttonStyle(PlainButtonStyle())
                }
                  .background(Color(white: 0.22))
                  .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                VStack(alignment: .leading) {
                    // hidden with arrow to allow showing it
                    Button() {
                        viewModel.leftPanelShowing = true 
                    } label: {
                        Image(systemName: "chevron.right.2")
                          .foregroundColor(.gray)
                    }
                      .buttonStyle(PlainButtonStyle())
                }
                  .frame(maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }

    var rightPanel: some View {
        @Bindable var viewModel = viewModel
        return Group {
            if viewModel.rightPanelShowing {
                VStack(alignment: .leading) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            VerticalStarPicker("selection mode", selection: $viewModel.selectionMode) { value, _ in
                                Text(value.localizedName).tag(value)
                            }
                              .help("""
                                      What happens when outlier groups are selected?
                                      paint   - they will be marked for painting
                                      clear   - they will be marked for not painting
                                      details - they will be shown in the info window
                                      """)      // XXX does this work here?
                            
                            // outlier opacity slider
                            Text("Outlier Group Opacity")
                              .foregroundColor(.white)
                            
                            Slider(value: $viewModel.outlierOpacity, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)
                            
                            Text("Frame Opacity")
                              .foregroundColor(.white)
                            
                            Slider(value: $viewModel.frameOpacity, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)
                        }
                    }
                      .defaultScrollAnchor(.bottom)
                    Button() {
                        viewModel.rightPanelShowing = false
                    } label: {
                        Image(systemName: "chevron.right.2")
                          .foregroundColor(.black)
                    }
                      .buttonStyle(PlainButtonStyle())
                }
                  .frame(maxHeight: .infinity, alignment: .bottomLeading)
                  .background(Color(white: 0.22))
            } else {
              // hidden with arrow to allow showing it
              VStack {
                Button() {
                    viewModel.rightPanelShowing = true 
                } label: {
                    Image(systemName: "chevron.left.2")
                      .foregroundColor(.gray)
                }
                  .buttonStyle(PlainButtonStyle())
              }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}
