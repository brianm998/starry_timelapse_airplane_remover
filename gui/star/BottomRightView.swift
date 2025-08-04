import SwiftUI
import StarCore
import logging
import Combine

// controls on the bottom right of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomRightView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    // stuff from harvester testing
    @State var harvesterCount: Int = 0
    @State var allOutlierGroupCount: Int = 0
    @State var allTotalOutlierProcessingTime: TimeInterval = 0
    @State var isolatedOutlierGroupCount: Int = 0
    @State var isolatedTotalOutlierProcessingTime: TimeInterval = 0

    // stuff from time testing
    @State var featureTime: TimeInterval = 0
    @State var classificationTime: TimeInterval = 0
    @State var outlierCount: Int = 0
    @State var frameCount: Int = 0
        
    var body: some View {
        
        HStack() {
            @Bindable var viewModel = viewModel

            if viewModel.interactionMode == .edit {

                if featureTime > 0,
                   classificationTime > 0
                {
                    VStack {
                        Text("\(outlierCount) outliers")
                          .foregroundColor(.orange)
                        Text("from \(frameCount) frames")
                          .foregroundColor(.orange)
                    }
                    VStack {
                        let featureString = String(format: "%d", Int(featureTime))
                        Text("featureTime \(featureString)s")
                          .foregroundColor(.orange)
                        let classificationString = String(format: "%d", Int(classificationTime))
                        Text("classificationTime \(classificationString)s")
                          .foregroundColor(.orange)
                    }
                }
                
                if harvesterCount > 0 {
                    VStack {
                        Text("\(harvesterCount) data harvesters running")
                          .foregroundColor(.orange)
                        HStack {
                            if allOutlierGroupCount > 0 {
                                VStack {
                                    Text("\(allOutlierGroupCount) groups processed")
                                      .foregroundColor(.orange)
                                    let formatString = String(format: "%.2f", allTotalOutlierProcessingTime/Double(allOutlierGroupCount))
                                    Text("averaging \(formatString) secs")
                                      .foregroundColor(.orange)
                                }
                            }
                            if isolatedOutlierGroupCount > 0 {
                                VStack {
                                    Text("\(isolatedOutlierGroupCount) groups processed")
                                      .foregroundColor(.orange)
                                    let formatString = String(format: "%.2f", isolatedTotalOutlierProcessingTime/Double(isolatedOutlierGroupCount))
                                    Text("averaging \(formatString) secs")
                                      .foregroundColor(.orange)
                                }
                            }
                        }
                    }
                }
                
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

                if viewModel.isProcessingFrames {
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
                    if frameView.loadingOutlierViews {
                        Text("loading outlier views")
                          .foregroundColor(.green)
                    }
                    if frameView.loadingTrashViews {
                        Text("loading outlier trash views")
                          .foregroundColor(.orange)
                    }
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
                        if let numTrash = frameView.frameObserver.numberOfTrashOutliers,
                           numTrash > 0
                        {
                            Text("\(numTrash) in trash")
                              .foregroundColor(.yellow)
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
                                       multiSelectionRemovalType: $viewModel.multiSelectionRemovalType,
                                       frames: $viewModel.frames,
                                       currentIndex: $viewModel.currentIndex,
                                       selectionStart: $viewModel.selectionStart,
                                       selectionEnd: $viewModel.selectionEnd,
                                       number_of_frames: $viewModel.number_of_frames)
              }
              .sheet(isPresented: $viewModel.renderVideoSheetShowing) {
                  RenderVideoSheetView(isVisible: $viewModel.renderVideoSheetShowing,
                                       viewModel: viewModel)
              }
            } else {
                Spacer()
                  .border(.purple)

                // show current frame number on the side
                // but not when animating
                if viewModel.videoPlaying {
                    Text("")
                } else {
                    if viewModel.isProcessingFrames {
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
          .onAppear {
        /*
              Task {
                  await classificationTimingDataHolder.setCallback() { a, b, c, d in
                      Task { @MainActor in 
                          self.featureTime = a
                          self.classificationTime = b
                          self.outlierCount = c
                          self.frameCount = d
                      }
                  }
                  await frameDataHarvesterDataHolder.setCallback() { a, b, c, d, e in
                      Task { @MainActor in 
                          self.harvesterCount = a
                          self.allOutlierGroupCount = b
                          self.allTotalOutlierProcessingTime = c
                          self.isolatedOutlierGroupCount = d
                          self.isolatedTotalOutlierProcessingTime = e
                      }
                  }
              }
                  */
          }
          .onDisappear {
              Task {
                  //await classificationTimingDataHolder.setCallback(nil)
                  //await frameDataHarvesterDataHolder.setCallback(nil)
              }
          }
    }
}
