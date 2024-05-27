import SwiftUI
import StarCore
import logging

// controls on the bottom right of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomRightView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
        HStack() {
            if viewModel.interactionMode == .edit {
                let frameView = viewModel.currentFrameView
                VStack(alignment: .trailing) {
                    let numChanged = viewModel.numberOfFramesChanged
                    if numChanged > 0 {
                        Text("\(numChanged) frames changed")
                          .foregroundColor(.yellow)
                    }
                    let numSaving = viewModel.frameSaveQueue?.saving.count ?? -1
                    if numSaving > 0 {
                        Text("saving \(numSaving) frames")
                          .foregroundColor(.green)
                    }
                }
                VStack {
                    Text("frame \(viewModel.currentIndex)")
                    if let _ = frameView.outlierViews {
                        if let numPositive = frameView.numberOfPositiveOutliers {
                            Text("\(numPositive) will paint")
                              .foregroundColor(numPositive == 0 ? .white : .red)
                        }
                        if let numNegative = frameView.numberOfNegativeOutliers {
                            Text("\(numNegative) will not paint")
                              .foregroundColor(numNegative == 0 ? .white : .green)
                        }
                        if let numUndecided = frameView.numberOfUndecidedOutliers,
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
                  SettingsSheetView(isVisible: self.$viewModel.settingsSheetShowing,
                                    fastSkipAmount: $viewModel.fastSkipAmount,
                                    videoPlaybackFramerate: self.$viewModel.videoPlaybackFramerate,
                                    fastAdvancementType: $viewModel.fastAdvancementType)
              }
              .sheet(isPresented: $viewModel.multiSelectSheetShowing) {
                  MultiSelectSheetView(isVisible: self.$viewModel.multiSelectSheetShowing,
                                       multiSelectionType: $viewModel.multiSelectionType,
                                       multiSelectionPaintType: $viewModel.multiSelectionPaintType,
                                       frames: $viewModel.frames,
                                       currentIndex: $viewModel.currentIndex,
                                       selectionStart: $viewModel.selectionStart,
                                       selectionEnd: $viewModel.selectionEnd,
                                       number_of_frames: $viewModel.number_of_frames)
              }
              .sheet(isPresented: $viewModel.paintSheetShowing) {
                  MassivePaintSheetView(isVisible: self.$viewModel.paintSheetShowing) { shouldPaint, startIndex, endIndex in
                      
                      viewModel.updatingFrameBatch = true
                      
                      for idx in startIndex ... endIndex {
                          // XXX use a task group?
                          if idx >= 0,
                             idx < viewModel.frames.count
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
                    Text("frame \(viewModel.currentIndex)")
                }
            }
        }
    }

    func toggleViews() -> some View {
        VStack(alignment: .leading) {
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
              .frame(maxWidth: 320)
              .pickerStyle(.segmented)

            HStack {
                Toggle("full resolution", isOn: $viewModel.showFullResolution)
                Toggle("show filmstip", isOn: $viewModel.showFilmstrip)
            }
        }
    }
}
