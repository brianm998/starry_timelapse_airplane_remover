import SwiftUI
import StarCore

struct LeftPanel: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0
    
    var body: some View {
        Group {
            if viewModel.leftPanelShowing {
                self.openView
            } else {
                self.closedView
            }
        }
    }

    var openView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .trailing) {
            ScrollView() {
                VStack(alignment: .leading) {

                    self.processingStateView

                    Spacer()
                      .frame(maxHeight: 10)
                    
                    self.frameModeView
                    
                }
                //                          .frame(maxWidth: 200)
            }
              .defaultScrollAnchor(.bottom)
              .frame(maxHeight: .infinity, alignment: .bottom)
            
            Spacer()
            
            Button() {
                viewModel.leftPanelShowing = false
            } label: {
                Image(systemName: "chevron.left.2")
                  .foregroundColor(.gray)
            }
              .buttonStyle(PlainButtonStyle())
              .cursor(.resizeLeft)
        }
          .padding(10)
          .background(Color(white: 0.22))
          .frame(maxHeight: .infinity, alignment: .bottom)
        
    }

    var processingStateView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            Text("Processing stats")
              .foregroundColor(.white)
            Spacer()
              .frame(maxHeight: 4)
            Grid(alignment: .leading) {
                if viewModel.showAllFrameProcessingStates {
                    // show all the detailed processing states
                    ForEach(FrameProcessingState.allCases, id: \.self) { state in
                        GridRow {
                            let count = viewModel.frameStateMap[state]?.count ?? 0
                            let color: Color = count == 0 ? .gray : .white
                            Text("\(count)")
                              .foregroundColor(color)
                            Text(state.message)
                              .foregroundColor(color)
                        }
                    }
                } else {
                    // just show unprocessed, processing, and complete
                    GridRow {
                        let count = viewModel.frameStateMap[.unprocessed]?.count ?? 0
                        let color: Color = count == 0 ? .gray : .white
                        Text("\(count)")
                          .foregroundColor(color)
                        Text(FrameProcessingState.unprocessed.message)
                          .foregroundColor(color)
                    }

                    GridRow {
                        let color: Color = viewModel.numberOfFramesProcessingNow == 0 ? .gray : .white
                        Text("\(viewModel.numberOfFramesProcessingNow)")
                          .foregroundColor(color)
                        Text("processing")
                          .foregroundColor(color)
                    }

                    GridRow {
                        let count = viewModel.frameStateMap[.complete]?.count ?? 0
                        let color: Color = count == 0 ? .gray : .white
                        Text("\(count)")
                          .foregroundColor(color)
                        Text(FrameProcessingState.complete.message)
                          .foregroundColor(color)
                    }
                }
            }

            Spacer()
              .frame(maxHeight: 10)
            
            ExpandUpButton($viewModel.showAllFrameProcessingStates)
        }
    }
    
    var frameModeView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            Text("Show:")
              .foregroundColor(.white)
            
            VerticalLimitedSelectionPicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                let shouldShow = (!viewModel.showAllFrameViewModes && (value == .original || value == .processed)) || viewModel.showAllFrameViewModes
                if shouldShow {
                    if viewModel.currentFrameView.hasImage(type: value) {
                        Text(value.longName)
                          .foregroundColor(isEnabled ? .black : .yellow)
                          .padding(4)
                          .onTapGesture { _ in
                              viewModel.frameViewMode = value
                          }
                    } else {
                        Text(value.longName)
                          .foregroundColor(/*isEnabled ? .white : */ .gray)
                          .padding(4)
                    }
                } else {
                    Group { }
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

            ExpandUpButton($viewModel.showAllFrameViewModes)
              .cursor(.resizeUp)
        }
    }
    
    var closedView: some View {
        VStack(alignment: .leading) {
            // hidden with arrow to allow showing it
            Button() {
                viewModel.leftPanelShowing = true 
            } label: {
                Image(systemName: "chevron.right.2")
                  .foregroundColor(.gray)
            }
              .buttonStyle(PlainButtonStyle())
              .cursor(.resizeRight)
        }
          .padding(10)
          .background(Color(white: 0.22))
          .frame(maxHeight: .infinity, alignment: .bottomTrailing)
        
    }
}

