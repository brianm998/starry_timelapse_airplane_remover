import SwiftUI
import StarCore

public enum FastAdvancementType: String, Equatable, CaseIterable {
    case normal
    case skipEmpties
    case toNextPositive
    case toNextNegative
    case toNextUnknown
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

struct RightPanel: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    enum FocusedField: Hashable {
        case trashLevel
        case smallTrashMax
        case minimumClassificationSize
        case numberOfFramesToProcess
        case numberOfFramesToProcessConcurrently
    }

    @FocusState private var focusedField: FocusedField?
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return Group {
            if viewModel.rightPanelShowing {
                VStack(alignment: .leading) {
                    ScrollView {
                        VStack(alignment: .leading) {

                            Text("Fast Advancement Type")
                              .foregroundColor(.white)

                            Picker("", selection: $viewModel.fastAdvancementType) {
                                ForEach(FastAdvancementType.allCases, id: \.self) { value in
                                    Text(value.localizedName).tag(value)
                                }
                            }
                              .help("""
                                      How the fast forward and fast reverse buttons work:

                                      normal         - move by some fixed number of frames
                                      skipEmpties    - skip all frames without any outliers
                                      toNextPositive - skip to the next frame with positive outliers
                                      toNextNegative - skip to the next frame with negative outliers
                                      toNextUnknown  - skip to the next frame with unknown outliers
                                      """)
                              .frame(maxWidth: 140)

                            switch viewModel.fastAdvancementType {
                            case .normal:
                                Text("Fast Forward and Reverse move by \(viewModel.fastSkipAmount) frames")
                                  .frame(maxWidth: 140)
                                  .multilineTextAlignment(.leading)
                                  .foregroundColor(.white)
                            case .skipEmpties:
                                Text("Skip all frames without outliers")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextPositive:
                                Text("Skip to next frame with a positive outlier")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextNegative:
                                Text("Skip to next frame with a negative outlier")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextUnknown:
                                Text("Skip to next frame with a unknown outlier")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            }

//                    Toggle(skipEmpties ? "change to # of frames" : "change to skip empties",
//                           isOn: $skipEmpties)

                    // XXX add advance to has undecided
                    // XXX add advance to has paintable
                    // XXX add advance to has not paintable
                    
                            if viewModel.fastAdvancementType == .normal {
                                Text("Fast Skip")
                                  .foregroundColor(.white)
                                Picker("", selection: $viewModel.fastSkipAmount) {
                                    ForEach(0 ..< 51) {
                                        Text("\($0) frames")
                                    }
                                }.frame(maxWidth: 140)
                            }

                            VerticalStarPicker("Tool", selection: $viewModel.selectionMode) { value, isEnabled, isSelected in
                                HStack {
                                    Image(value.iconName)
                                      .resizable()
                                      .frame(width: 35, height: 35)
                                    Text(value.displayName)
                                      .foregroundColor(isSelected ? .black : .white)
                                      .tag(value)
                                }
                            }
                              .help("""
                                      What happens when outlier groups are selected?
                                      paint   - they will be marked for painting
                                      clear   - they will be marked for not painting
                                      details - they will be shown in the info window
                                      """)      // XXX does this work here?

                            Toggle("multi choice", isOn: $viewModel.multiChoice)
                              .foregroundColor(.white)

                            Toggle("Show Ignore Bar", isOn: $viewModel.showIgnoreLowerBar)
                              .foregroundColor(.white)
                            
                            Toggle("Show Trash", isOn: $viewModel.shouldShowTrash)
                              .foregroundColor(.white)

                            Text("Trash Level")
                              .foregroundColor(.yellow)
                            TextField("\(viewModel.trashLevel)",
                                      text: $viewModel.trashLevelString)
                              .focused($focusedField, equals: .trashLevel)
                              .frame(maxWidth: 60)
                              .onSubmit {
                                  let filtered = viewModel.trashLevelString.filter { "0123456789.-".contains($0) }
                                  if let newValue = Double(filtered),
                                     newValue >= -1,
                                     newValue <= 1
                                  {
                                      viewModel.trashLevel = newValue
                                      viewModel.trashLevelString = "\(newValue)"
                                  }
                                  self.focusedField = nil
                              }
                            
                            Text("Small Trash Max")
                              .foregroundColor(.yellow)
                            TextField("\(viewModel.smallTrashMax)",
                                      text: $viewModel.smallTrashMaxString)
                              .frame(maxWidth: 60)
                              .focused($focusedField, equals: .smallTrashMax)
                              .onSubmit {
                                  let filtered = viewModel.smallTrashMaxString.filter { "0123456789".contains($0) }
                                  if let newValue = Int(filtered) {
                                      viewModel.smallTrashMax = newValue
                                      viewModel.smallTrashMaxString = "\(newValue)"
                                  }
                                  self.focusedField = nil
                              }
                            
                            Text("Minimum Classification Size")
                              .foregroundColor(.orange)
                            TextField("\(viewModel.minimumClassificationSize)",
                                      text: $viewModel.minimumClassificationSizeString)
                              .frame(maxWidth: 60)
                              .focused($focusedField, equals: .minimumClassificationSize)
                              .onSubmit {
                                  let filtered = viewModel.minimumClassificationSizeString.filter { "0123456789".contains($0) }
                                  if let newIntValue = Int(filtered),
                                     newIntValue >= 0
                                  {
                                      viewModel.minimumClassificationSize = newIntValue
                                      viewModel.minimumClassificationSizeString = "\(newIntValue)"
                                  }
                                  self.focusedField = nil
                              }

                            Toggle("Only Unclassified", isOn: $viewModel.classifyOnlyUnclassified)
                              .foregroundColor(.orange)
                            
                            // frame rate 
                            let frame_rates = [1, 2, 3, 5, 10, 15, 20, 25, 30, 60, 90]
                            Text("Frame Rate")
                              .foregroundColor(.white)
                            Picker("", selection: $viewModel.videoPlaybackFramerate) {
                                ForEach(frame_rates, id: \.self) {
                                    Text("\($0) fps")
                                }
                            }.frame(maxWidth: 100)

                            
                            // outlier opacity slider
                            Text("Outlier Group Opacity")
                              .foregroundColor(.white)
                            
                            Slider(value: $viewModel.outlierOpacity, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)
                            
                            Text("Trash Opacity")
                              .foregroundColor(.white)
                            
                            Slider(value: $viewModel.trashOpacity, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)
                            
                            Text("Frame Opacity")
                              .foregroundColor(.white)
                            
                            Slider(value: $viewModel.frameOpacity, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)

                            Toggle("show full resolution", isOn: $viewModel.showFullResolution)
                              .foregroundColor(.white)

                            let frameView = viewModel.currentFrameView

                            EditableNumberOfFramesToProcessConcurrentlyView(focusedField: $focusedField)

                            Toggle("reprocess fully", isOn: $viewModel.reprocessFrames)
                              .foregroundColor(.white)
                            
                            Button() {
                                Task {
                                    if let frame = viewModel.currentFrame {
                                        // XXX reprocess
                                        if viewModel.reprocessFrames {
                                            await viewModel.clearProcessing(from: frame)
                                        }
                                        viewModel.processFrames(from: frame.frameIndex,
                                                                to: frame.frameIndex+viewModel.numberOfFramesToProcess)
                                    }
                                }
                            } label: {
                                if viewModel.reprocessFrames {
                                    Text("Re-Process the next")
                                } else {
                                    Text("Process the next")
                                }
                            }
                              .disabled(//viewModel.isProcessingAllFrames ||
                                          viewModel.renderingCurrentFrame)


                            EditableNumberOfFramesToProcessView(focusedField: $focusedField)

                            Picker("", selection: $viewModel.detectionType) {
                                ForEach(DetectionType.allCases, id: \.self) { value in
                                    Text(value.rawValue).tag(value)
                                }
                            }
                              .frame(maxWidth: 120)
                              .onChange(of: viewModel.detectionType) {
                                  Task {
                                      await constants.set(detectionType: viewModel.detectionType)

                                      // stick it in user preferences
                                      self.viewModel.userPreferences.processingType = viewModel.detectionType
                                  }
                              }

                            Button() {
                                Task {
                                    if let frame = viewModel.currentFrame {
                                        try? await viewModel.render(frame: frame, now: true)
                                    }
                                }
                            } label: {
                                Text("Render Updates")
                            }
                              .disabled(frameView.outlierViews == nil ||
                                        viewModel.renderingCurrentFrame)
                        }
                    }
                      .defaultScrollAnchor(.bottom)

                    Spacer()
                    
                    Button() {
                        viewModel.rightPanelShowing = false
                    } label: {
                        Image(systemName: "chevron.right.2")
                          .foregroundColor(.gray)
                    }
                      .buttonStyle(PlainButtonStyle())
                      .cursor(.resizeRight)

                }
                  .padding(10)
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
                      .cursor(.resizeLeft)
                }
                  .padding(10)
                  .background(Color(white: 0.22))
                  .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}


struct EditableNumberOfFramesToProcessConcurrentlyView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let focusedField: FocusState<RightPanel.FocusedField?>.Binding
    
    @State private var editFrameNumberMode = false
    @State private var editFrameNumberModeString = ""
    
    var body: some View {
        let frameNumberString = String(format: "%d", viewModel.numberOfFramesToProcessConcurrently)
        if self.editFrameNumberMode {
            HStack {
                Text("process")
                  .foregroundColor(.white)
                TextField("\(frameNumberString)",
                          text: $editFrameNumberModeString)
                  .focused(focusedField, equals: RightPanel.FocusedField.numberOfFramesToProcessConcurrently)
                  .frame(maxWidth: 38)
                  .cursor(.arrow)
                  .onSubmit {
                      let filtered = editFrameNumberModeString.filter { "0123456789".contains($0) }
                      if let newIntValue = Int(filtered),
                         newIntValue >= 0,
                         newIntValue < self.viewModel.imageSequenceSize
                      {
                          self.viewModel.numberOfFramesToProcessConcurrently = newIntValue

                          // stick it in user preferences
                          self.viewModel.userPreferences.concurrentFrames = newIntValue

                          // update the global we use for this
                          Task { await maxFramesProcessing.set(value: newIntValue) }
                          
                          self.editFrameNumberMode = false
                          self.editFrameNumberModeString = ""
                      }
                  }
                Text("frames at once")
                  .foregroundColor(.white)
            }
        } else {
            Text("process \(frameNumberString) frames at once")
              .foregroundColor(.white)
              .cursor(.iBeam)
              .onTapGesture(count: 1) {
                  self.editFrameNumberMode = true
                  focusedField.wrappedValue = RightPanel.FocusedField.numberOfFramesToProcessConcurrently
              }
        }
    }
}

struct EditableNumberOfFramesToProcessView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let focusedField: FocusState<RightPanel.FocusedField?>.Binding

    @State private var editFrameNumberMode = false
    @State private var editFrameNumberModeString = ""
    
    var body: some View {
        let frameNumberString = String(format: "%d", viewModel.numberOfFramesToProcess)
        if self.editFrameNumberMode {
            HStack {
                TextField("\(frameNumberString)",
                          text: $editFrameNumberModeString)
                  .focused(focusedField, equals: RightPanel.FocusedField.numberOfFramesToProcess)
                  .frame(maxWidth: 38)
                  .onSubmit {
                      let filtered = editFrameNumberModeString.filter { "0123456789".contains($0) }
                      if let newIntValue = Int(filtered),
                         newIntValue >= 0,
                         newIntValue < self.viewModel.imageSequenceSize
                      {
                          self.viewModel.numberOfFramesToProcess = newIntValue
                          
                          self.editFrameNumberMode = false
                          self.editFrameNumberModeString = ""
                      }
                  }
                if self.viewModel.numberOfFramesToProcess == 1 {
                    Text("frame as")
                      .foregroundColor(.white)
                } else {
                    Text("frames as")
                      .foregroundColor(.white)
                }
            }
        } else {
            Text("\(frameNumberString) frames as")
              .foregroundColor(.white)
              .cursor(.iBeam)
              .onTapGesture(count: 1) {
                  self.editFrameNumberMode = true
                  focusedField.wrappedValue = RightPanel.FocusedField.numberOfFramesToProcess
              }
        }
    }
}
