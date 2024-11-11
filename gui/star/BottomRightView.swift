import SwiftUI
import StarCore
import logging
import Combine

// controls on the bottom right of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomRightView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        
        HStack() {
            @Bindable var viewModel = viewModel

            if viewModel.interactionMode == .edit {
                let frameView = viewModel.currentFrameView
                
                VStack(alignment: .trailing) {
                    let numChanged = viewModel.numberOfFramesChanged
                    if numChanged > 0 {
                        Text("\(numChanged) frames changed")
                          .foregroundColor(.yellow)
                    }
                    let numSaving = viewModel.frameSaveQueueSize
                    if numSaving > 0 {
                        Text("saving \(numSaving) frames")
                          .foregroundColor(.green)
                    }
                }

                if viewModel.isProcessingAllFrames {
                    ProgressView()
                    Text("processing \(viewModel.frames.count - viewModel.numberOfFramesProcessed) more frames")
                      .foregroundColor(.white)
                }

                if let frameState = frameView.frameState {
                    if !viewModel.isProcessingAllFrames,
                       frameState != .complete,
                       frameView.outlierViews != nil,
                       !viewModel.renderingCurrentFrame
                    {
                        Button() {
                            Task {
                                if let frame = viewModel.currentFrame {
                                    await viewModel.render(frame: frame, closure: nil)
                                }
                            }
                        } label: {
                            Text("Render Frame")
                        }
                    }
                    
                    Text("frame is \(frameState.message)")
                      .foregroundColor(frameState.color)
                    Spacer()
                      .frame(maxWidth: 20)
                }

                VStack {
                    EditableFrameNumberView()
                    if let _ = frameView.outlierViews {
                        
                        if let numPositive = frameView.frameObserver.numberOfPositiveOutliers {
                            Text("\(numPositive) will paint")
                              .foregroundColor(numPositive == 0 ? .white : .red)
                        }
                        if let numNegative = frameView.frameObserver.numberOfNegativeOutliers {
                            Text("\(numNegative) will not paint")
                              .foregroundColor(numNegative == 0 ? .white : .green)
                        }
                        if let numUndecided = frameView.frameObserver.numberOfUndecidedOutliers,
                           numUndecided > 0
                        {
                            Text("\(numUndecided) undecided")
                              .foregroundColor(.orange)
                        }
                    }
                }

                let gearAction = {
                    Log.d("GEAR")
                    viewModel.settingsSheetShowing = !viewModel.settingsSheetShowing
                }
                Button(action: gearAction) {
                    buttonImage("gearshape.fill", size: 44)
                      .foregroundColor(.gray)
                }
                  .buttonStyle(PlainButtonStyle())           
                  .help("settings")
                
                toggleViews()
              .sheet(isPresented: $viewModel.settingsSheetShowing) {
                  SettingsSheetView(isVisible: $viewModel.settingsSheetShowing,
                                    fastSkipAmount: $viewModel.fastSkipAmount,
                                    videoPlaybackFramerate: $viewModel.videoPlaybackFramerate,
                                    fastAdvancementType: $viewModel.fastAdvancementType)
              }
              .sheet(isPresented: $viewModel.multiChoiceSheetShowing) {
                  if let multiChoiceOutlierView = viewModel.multiChoiceOutlierView {
                      MultiChoiceSheetView(isVisible: $viewModel.multiChoiceSheetShowing,
                                           multiChoicePaintType: $viewModel.multiChoicePaintType,
                                           multiChoiceType: $viewModel.multiChoiceType,
                                           frames: $viewModel.frames,
                                           currentIndex: $viewModel.currentIndex,
                                           number_of_frames: $viewModel.number_of_frames,
                                           multiChoiceOutlierView: multiChoiceOutlierView)
                  }
              }
              .sheet(isPresented: $viewModel.multiSelectSheetShowing) {
                  MultiSelectSheetView(isVisible: $viewModel.multiSelectSheetShowing,
                                       multiSelectionType: $viewModel.multiSelectionType,
                                       multiSelectionPaintType: $viewModel.multiSelectionPaintType,
                                       frames: $viewModel.frames,
                                       currentIndex: $viewModel.currentIndex,
                                       selectionStart: $viewModel.selectionStart,
                                       selectionEnd: $viewModel.selectionEnd,
                                       number_of_frames: $viewModel.number_of_frames)
              }
            } else {
                Spacer()
                  .border(.purple)

                // show current frame number on the side
                // but not when animating
                if viewModel.videoPlaying {
                    Text("")
                } else {
                    if viewModel.isProcessingAllFrames {
                        ProgressView()
                        Text("processing \(viewModel.frames.count - viewModel.numberOfFramesProcessed) more frames")
                      .foregroundColor(.white)
                    }                    
                    EditableFrameNumberView()
                }
            }
        }
    }

    func toggleViews() -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading) {
            HStack {
                Toggle("full resolution", isOn: $viewModel.showFullResolution)
                  .foregroundColor(.white)
                Toggle("show filmstip", isOn: $viewModel.showFilmstrip)
                  .foregroundColor(.white)
                Toggle("multi choice", isOn: $viewModel.multiChoice)
                  .foregroundColor(.white)
            }
        }
    }
}
