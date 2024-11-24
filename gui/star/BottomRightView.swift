import SwiftUI
import StarCore
import logging
import Combine

// controls on the bottom right of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomRightView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        
        HStack() {
            @Bindable var viewModel = viewModel

            if viewModel.interactionMode == .edit {
                let frameView = viewModel.currentFrameView
                
                VStack(alignment: .trailing) {
                    let numPurgatory = viewModel.frameSaveQueue.purgatoryCount
                    if numPurgatory > 0 {
                        Text("\(numPurgatory) frames in purgatory")
                          .foregroundColor(.purple)
                    }

                    let numPending = viewModel.frameSaveQueue.pendingSavingCount
                    if numPending > 0 {
                        Text("\(numPending) frames waiting to save")
                          .foregroundColor(.yellow)
                    }
                    
                    let numSaving = viewModel.frameSaveQueue.savingCount
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

                    Text("frame is \(frameState.message)")
                      .foregroundColor(frameState.color)

                    Spacer()
                      .frame(maxWidth: 20)
                }

                VStack {
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

                EditableFrameNumberView()

                ExpandUpButton($viewModel.showFilmstrip)
                
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
                    if viewModel.showIgnoreLowerBar {
                        Toggle("Show Ignore Bar", isOn: $viewModel.showIgnoreLowerBar)
                          .foregroundColor(.white)
                    }

                    EditableFrameNumberView()
                }
            }
        }
    }
}
