import SwiftUI
import StarCore
import logging
import Combine

// controls on the bottom right of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomRightView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Environment(FrameGraphViewModel.self) var frameGraphViewModel: FrameGraphViewModel

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
                        Text(localized("ui.n_outliers", outlierCount))
                          .foregroundColor(.orange)
                        Text(localized("ui.from_n_frames", frameCount))
                          .foregroundColor(.orange)
                    }
                    VStack {
                        let featureString = String(format: "%d", Int(featureTime))
                        Text(localized("ui.feature_time", featureString))
                          .foregroundColor(.orange)
                        let classificationString = String(format: "%d", Int(classificationTime))
                        Text(localized("ui.classification_time", classificationString))
                          .foregroundColor(.orange)
                    }
                }
                
                if harvesterCount > 0 {
                    VStack {
                        Text(localized("ui.n_harvesters_running", harvesterCount))
                          .foregroundColor(.orange)
                        HStack {
                            if allOutlierGroupCount > 0 {
                                VStack {
                                    Text(localized("ui.n_groups_processed", allOutlierGroupCount))
                                      .foregroundColor(.orange)
                                    let formatString = String(format: "%.2f", allTotalOutlierProcessingTime/Double(allOutlierGroupCount))
                                    Text(localized("ui.averaging_secs", formatString))
                                      .foregroundColor(.orange)
                                }
                            }
                            if isolatedOutlierGroupCount > 0 {
                                VStack {
                                    Text(localized("ui.n_groups_processed_isolated", isolatedOutlierGroupCount))
                                      .foregroundColor(.orange)
                                    let formatString = String(format: "%.2f", isolatedTotalOutlierProcessingTime/Double(isolatedOutlierGroupCount))
                                    Text(localized("ui.averaging_secs", formatString))
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
                        Text(localized("ui.n_frames_in_purgatory", numPurgatory))
                          .foregroundColor(.purple)
                    }

                    let numPending = viewModel.frameSaveQueue.pendingSavingCount
                    if numPending > 0 {
                        Text(localized("ui.n_frames_waiting_to_save", numPending))
                          .foregroundColor(.yellow)
                    }
                    
                    let numSaving = viewModel.frameSaveQueue.savingCount
                    if numSaving > 0 {
                        Text(localized("ui.saving_n_frames", numSaving))
                          .foregroundColor(.green)
                    }
                }

                if viewModel.isProcessingFrames {
                    ProgressView()
                      .colorScheme(.dark)
                    Text(localized("ui.n_frames_processing", frameGraphViewModel.numberOfFramesProcessingNow))
                      .foregroundColor(.white)
                    Button {
                        viewModel.cancelProcessing()
                        Task { await frameGraphBuilder.cancelAllOperations() }
                    } label: {
                        Text(localized("ui.stop"))
                          .foregroundColor(.white)
                          .padding(.horizontal, 8)
                          .padding(.vertical, 4)
                          .background(Color.red.opacity(0.8))
                          .cornerRadius(6)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .help(localized("ui.cancel_all_pending_processing_operations"))
                }

                switch viewModel.sequenceProcessingState {
                case .unprocessed:
                    Group { }
                case .horizonDetection:
                    ProgressView()
                      .colorScheme(.dark)
                    VStack {
                        Text(localized("ui.detecting_horizons"))
                          .foregroundColor(.white)
                        let remaining = viewModel.frames.count - viewModel.count(for: .horizonDetected)
                        Text(localized("ui.n_frames_left", remaining))
                          .foregroundColor(.white)
                    }
                case .starKeypoints:
                    ProgressView()
                      .colorScheme(.dark)
                    let remaining = viewModel.frames.count
                      - viewModel.count(for: .complete)
                      - viewModel.count(for: .starKeypointsFound)
                    VStack {
                        Text(localized("ui.star_keypoints"))
                          .foregroundColor(.white)
                        Text(localized("ui.n_frames_left", remaining))
                          .foregroundColor(.white)
                    }
                case .earthKeypoints:
                    ProgressView()
                      .colorScheme(.dark)
                    let remaining = viewModel.frames.count
                      - viewModel.count(for: .complete)
                      - viewModel.count(for: .earthKeypointsFound)
                    VStack {
                        Text(localized("ui.earth_keypoints"))
                          .foregroundColor(.white)
                        Text(localized("ui.n_frames_left", remaining))
                          .foregroundColor(.white)
                    }
                case .firstAlignment:
                    ProgressView()
                      .colorScheme(.dark)
                    VStack {
                        Text(localized("ui.first_alignment"))
                          .foregroundColor(.white)
                        let remaining = viewModel.frames.count
                          - viewModel.count(for: .complete)
                          - viewModel.count(for: .starAlignmentFailed)
                        Text(localized("ui.n_frames_left", remaining))
                          .foregroundColor(.white)
                    }
                case .secondAlignment:
                    ProgressView()
                      .colorScheme(.dark)
                    VStack {
                        Text(localized("ui.second_alignment"))
                          .foregroundColor(.white)
                        let remaining = viewModel.frames.count - viewModel.count(for: .complete)
                        Text(localized("ui.n_frames_left", remaining))
                          .foregroundColor(.white)
                    }
                case .done:
                    Text(localized("ui.alignment_done"))
                      .foregroundColor(.green)

                case .error(let errorString):
                    Text(localized("ui.alignment_error", errorString))
                      .foregroundColor(.red)
                }

                if let frameState = frameView.frameState {

                    Text(localized("ui.frame_is_state", frameState.message))
                      .foregroundColor(frameState.color)

                    Spacer()
                      .frame(maxWidth: 20)
                }

                VStack {
                    if frameView.loadingOutlierViews {
                        Text(localized("ui.loading_outlier_views"))
                          .foregroundColor(.green)
                    }
                    if frameView.loadingTrashViews {
                        Text(localized("ui.loading_outlier_trash_views"))
                          .foregroundColor(.orange)
                    }
                }

                /*

                 // XXX redo this with a better metrix
                 
                if frameView.frameObserver.starAlignmentResults != nil ||
                   frameView.frameObserver.earthAlignmentResults != nil
                {
                    Text(localized("ui.alignment"))
                      .foregroundColor(.white)
                }
                
                VStack(alignment: .trailing) {
                    if let results = frameView.frameObserver.starAlignmentResults {
                        Text(localized("ui.star_aligned_ratio", results.numberAligned.count, results.total))
                        .foregroundColor(results.numberAligned.count == results.total ? .white : .red)
                    }
                    if let results = frameView.frameObserver.earthAlignmentResults {
                        Text(localized("ui.earth_aligned_ratio", results.numberAligned.count, results.total))
                        .foregroundColor(results.numberAligned.count == results.total ? .white : .red)
                    }
                }
                 */
                
                VStack {
                    if let _ = frameView.outlierViews {
                        
                        if let numPositive = frameView.frameObserver.numberOfPositiveOutliers {
                            Text(localized("ui.n_will_remove", numPositive))
                              .foregroundColor(numPositive == 0 ? .white : .red)
                        }
                        if let numNegative = frameView.frameObserver.numberOfNegativeOutliers {
                            Text(localized("ui.n_will_keep", numNegative))
                              .foregroundColor(numNegative == 0 ? .white : .green)
                        }
                        if let numUndecided = frameView.frameObserver.numberOfUndecidedOutliers,
                           numUndecided > 0
                        {
                            Text(localized("ui.n_undecided", numUndecided))
                              .foregroundColor(.orange)
                        }
                        if let numTrash = frameView.frameObserver.numberOfTrashOutliers,
                           numTrash > 0
                        {
                            Text(localized("ui.n_in_trash", numTrash))
                              .foregroundColor(.yellow)
                        }
                    }
                }

                Space(width: 5)
                
                EditableFrameNumberView()


                Button() {
                    withAnimation {
                        viewModel.shouldShowProcessingSettings = true
                    }
                } label: {
                    Text("⚙")
                      .font(.system(size: 60))
                      .foregroundColor(.white)
                      .help(localized("ui.show_settings"))
                }
                  .buttonStyle(PlainButtonStyle())

                
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
                                       viewModel: viewModel,
                                       autoStart: viewModel.renderVideoAutoStart)
                    .onDisappear {
                        // reset so a later manual open shows the choice view
                        viewModel.renderVideoAutoStart = false
                    }
              }
              .sheet(isPresented: $viewModel.preProcessingRenderPromptShowing) {
                  PreProcessingRenderPromptView()
              }
              .sheet(isPresented: $viewModel.postProcessingRenderPromptShowing) {
                  PostProcessingRenderPromptView()
              }
              .sheet(isPresented: $viewModel.shouldShowProcessingSettings) {
                  ProcessingSettingsView(viewModel: viewModel)
              }
              .sheet(isPresented: $viewModel.shouldShowInitialInstructions) {
                  StartupView()
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
                          .colorScheme(.dark)
                        Text(localized("ui.processing_n_more_frames", viewModel.frames.count - viewModel.numberOfFramesProcessed))
                          .foregroundColor(.white)
                        Button {
                            viewModel.cancelProcessing()
                            Task { await frameGraphBuilder.cancelAllOperations() }
                        } label: {
                            Text(localized("ui.stop"))
                              .foregroundColor(.white)
                              .padding(.horizontal, 8)
                              .padding(.vertical, 4)
                              .background(Color.red.opacity(0.8))
                              .cornerRadius(6)
                        }
                        .buttonStyle(PlainButtonStyle())
                        .help(localized("ui.cancel_all_pending_processing_operations"))
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
