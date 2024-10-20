import SwiftUI
import StarCore
import logging
import Combine

// controls on the bottom right of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomRightView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    var body: some View {
        
        return HStack() {
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

                let paintAction = {
                    Log.d("PAINT")
                    viewModel.paintSheetShowing = !viewModel.paintSheetShowing
                }
                Button(action: paintAction) {
                    buttonImage("square.stack.3d.forward.dottedline", size: 44)
                    
                }
                  .buttonStyle(PlainButtonStyle())           
                  .help("effect multiple frames")
                
                let gearAction = {
                    Log.d("GEAR")
                    viewModel.settingsSheetShowing = !viewModel.settingsSheetShowing
                }
                Button(action: gearAction) {
                    buttonImage("gearshape.fill", size: 44)
                    
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
              .sheet(isPresented: $viewModel.paintSheetShowing) {
                  MassivePaintSheetView(isVisible: $viewModel.paintSheetShowing) { shouldPaint, startIndex, endIndex in
                      
                      viewModel.updatingFrameBatch = true
                      
                      for idx in startIndex ... endIndex {
                          // XXX use a task group?
                          if idx >= 0,
                             idx < viewModel.imageSequenceSize
                          {
                              viewModel.setAllFrameOutliers(in: viewModel.frames[idx], to: shouldPaint)
                          }
                      }
                      viewModel.updatingFrameBatch = false
                      
                      Log.d("shouldPaint \(shouldPaint), startIndex \(startIndex), endIndex \(endIndex)")
                  }
              }
            } else {
                Spacer()
                  .border(.purple)

                // show current frame number on the side
                // but not when animating
                if viewModel.videoPlaying {
                    Text("")
                } else {
                    EditableFrameNumberView()
                }
            }
        }
    }

    func toggleViews() -> some View {
        @Bindable var viewModel = viewModel

        return VStack(alignment: .leading) {
            Picker("selection mode", selection: $viewModel.selectionMode) {
                ForEach(SelectionMode.allCases, id: \.self) { value in
                    Text(value.localizedName).tag(value)
                }
            }
              .help("""
                      What happens when outlier groups are selected?
                      paint   - they will be marked for painting
                      clear   - they will be marked for not painting
                      details - they will be shown in the info window
                      """)
              .frame(maxWidth: 360)
              .pickerStyle(.segmented)

            HStack {
                Toggle("full resolution", isOn: $viewModel.showFullResolution)
                Toggle("show filmstip", isOn: $viewModel.showFilmstrip)
                Toggle("multi choice", isOn: $viewModel.multiChoice)
            }
        }
    }
}
