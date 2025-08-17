import SwiftUI
import StarCore
import logging

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

            // XXX testing for why sometimes this view doesn't get events
            // XXX testing for why sometimes this view doesn't get events
            // XXX testing for why sometimes this view doesn't get events
            /*
            Button() {
                Log.i("FUCK YES IT DOES")
            } label: {
                Text("Does this shit still work?")
            }
              .buttonStyle(PlainButtonStyle())
              .cursor(.extractTrashPointing)
             */
            // XXX testing for why sometimes this view doesn't get events
            // XXX testing for why sometimes this view doesn't get events
            // XXX testing for why sometimes this view doesn't get events
            
            ScrollView() {
                VStack(alignment: .leading) {

                    self.processingButtons

                    ProcessingProgressBarView()
                      .frame(maxWidth: 200, alignment: .leading)
                     //.frame(maxWidth: .none)
                    
                    Space(height: 10)
                    
                    self.processingStateView

                    Space(height: 10)
                    
                    self.frameModeView
                    
                }
                //                          .frame(maxWidth: 200)
            }
              .defaultScrollAnchor(.bottom)
           //   .frame(maxHeight: .infinity, alignment: .bottom)
            
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
          .background(Color(white: 0.22).zIndex(0))
          .frame(maxHeight: .infinity, alignment: .bottom)
        
    }

    var processButtonDisabled: Bool {
        let unprocessed = viewModel.frameStateMap[.unprocessed]?.count ?? 0
        return unprocessed == 0 || viewModel.renderingAllFrames || viewModel.isProcessingFrames || viewModel.isRenderingVideo
    }

    var updateButtonDisabled: Bool {
        let userModified = viewModel.frameStateMap[.userModified]?.count ?? 0
        return userModified == 0 || viewModel.renderingAllFrames || viewModel.isProcessingFrames || viewModel.isRenderingVideo
    }

    var renderButtonDisabled: Bool {
        let complete = viewModel.frameStateMap[.complete]?.count ?? 0
        return complete != viewModel.frames.count || viewModel.renderingAllFrames || viewModel.isProcessingFrames || viewModel.isRenderingVideo
    }
    
    var processingButtons: some View {
        VStack(alignment: .leading) {
            let unprocessed = viewModel.frameStateMap[.unprocessed]?.count ?? 0

            Button() {
                viewModel.showProcessingOptionsSheet = true
                //viewModel.processFrames(from: 0)
                 /*
                  XXX show a UI here which allows the user to choose:

                  - the number of neigbhors
                  - the pixel threshold
                  - now many to process at once
                  - processessing level (mild, strong, etc)

                  with a description of what each one means
                 */
            } label: {
                Text("Process \(unprocessed) frames")
            }
              .disabled(processButtonDisabled)
              .if(!processButtonDisabled) { 
                  $0.buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
            
            
            let userModified = viewModel.frameStateMap[.userModified]?.count ?? 0
            
            Button() {
                // XXX this has no max number of processes :(
                viewModel.renderAllFrames()
            } label: {
                Text("Update \(userModified) frames")
            }
              .disabled(updateButtonDisabled)
              .if(!updateButtonDisabled) { view in
                  view
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
              }

            let complete = viewModel.frameStateMap[.complete]?.count ?? 0

            Button() {
                Log.d("render video")
                viewModel.renderVideoSheetShowing = true
                /*

                 need to keep track of ffmpeg parameters when we load a video
                 (get rid of script to render)

                 default ffmpeg parameters to prores high quailty in config

                 have ui that allows users to change codec and frame rate, etc.

                 show render progress in UI somehow
                 
                 */

                viewModel.isRenderingVideo = false
                
            } label: {
                Text("render video from \(viewModel.frames.count) frames")
            }
              .disabled(renderButtonDisabled)
              .if(!renderButtonDisabled) { view in
                  view
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
        }
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
//                } else {
//                    Group { }
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

extension View {                // XXX move this
    @ViewBuilder func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

struct ProcessingProgressBarView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    let unprocessedColor: Color = .gray
    let processingColor: Color = .yellow
    let completeColor: Color = .green

    var body: some View {
        return GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let totalFrames = max(1, viewModel.frames.count)
            
            let unprocessed = CGFloat(viewModel.frameStateMap[.unprocessed]?.count ?? 0)
            let processing = CGFloat(viewModel.numberOfFramesProcessingNow)
            let complete = CGFloat(viewModel.frameStateMap[.complete]?.count ?? 0)

            
            let unprocessedWidth = totalWidth * (unprocessed / CGFloat(totalFrames))
            let processingWidth = totalWidth * (processing / CGFloat(totalFrames))
            let completeWidth = totalWidth * (complete / CGFloat(totalFrames))

            HStack(spacing: 0) {
                Rectangle()
                    .fill(completeColor)
                    .frame(width: completeWidth)

                Rectangle()
                    .fill(processingColor)
                    .frame(width: processingWidth)

                Rectangle()
                    .fill(unprocessedColor)
                    .frame(width: unprocessedWidth)

            }
            .cornerRadius(4)
            .frame(height: 10)
        }
        .frame(height: 10)
    }
}

