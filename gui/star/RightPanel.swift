import SwiftUI
import StarCore
import logging

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
    @Environment(LoggingViewModel.self) var loggingViewModel: LoggingViewModel

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    @FocusState private var focusedField: FocusedField?
    
    var body: some View {
        @Bindable var viewModel = viewModel
        @Bindable var loggingViewModel = loggingViewModel
        let config = viewModel.config.config()
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
                                    if isEnabled {
                                        Image(value.iconName)
                                          .resizable()
                                          .frame(width: 35, height: 35)
                                    } else {
                                        Image(value.iconName)
                                          .resizable()
                                          .renderingMode(.template)
                                          .foregroundColor(.gray)
                                          .frame(width: 35, height: 35)
                                    }
                                    Text(value.displayName)
                                      .foregroundColor(isSelected ?
                                                         .black :
                                                         isEnabled ? 
                                                         .white :
                                                         .gray)
                                      .tag(value)
                                }
                            }
                              .disabled(!viewModel.currentFrameUsesOutliers)
                              .help("""
                                      What happens when outlier groups are selected?
                                      paint   - they will be marked for painting
                                      clear   - they will be marked for not painting
                                      details - they will be shown in the info window
                                      """)      // XXX does this work here?


                            Toggle("multi choice", isOn: $viewModel.multiChoice)
                              .foregroundColor(.white)
   
                            // ── Horizon painting ───────────────────────
                            Button {
                                viewModel.isShowingHorizonPainter.toggle()
                            } label: {
                                Label(
                                    viewModel.isShowingHorizonPainter
                                        ? "Close Horizon Painter"
                                        : "Paint Horizon Reference",
                                    systemImage: viewModel.isShowingHorizonPainter
                                        ? "xmark.circle"
                                        : "mountain.2"
                                )
                            }
                            .buttonStyle(.bordered)
                            .tint(viewModel.isShowingHorizonPainter ? .red : .blue)
                            .help("""
                                  Open the horizon painting tool to define a reference
                                  horizon mask for this frame.
                                  Press H to toggle. Use [ / ] to resize the brush.
                                  Press - to switch between paint and erase mode.
                                  """)

                            Toggle("Show Trash", isOn: $viewModel.shouldShowTrash)
                              .foregroundColor(.white)
                              .disabled(!viewModel.currentFrameUsesOutliers)

                            /*
                             XXX for some unknown reason, these grab focus and refuse
                             XXX to let it go :(
                             
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

                             */
                            
                            Toggle(
                              "Only Unclassified",
                              isOn: $viewModel.classifyOnlyUnclassified
                            )
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


                            VStack(alignment: .leading) {
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
                            }
                              .disabled(!viewModel.currentFrameUsesOutliers)


                            HStack {
                                Text("Zoom")
                                  .foregroundColor(.white)
                                Spacer()
                                // Editable max zoom here
                                EditableMaxZoomView(
                                  focusedField: $focusedField,
                                  textColor: .white,
                                  alwaysOpen: false
                                )
                            }
                              .frame(maxWidth: 140)
                            Slider(value: $viewModel.currentZoomScale,
                                   in: viewModel.minZoomScale...viewModel.maxZoomScale)
                              .frame(maxWidth: 140, alignment: .bottom)
                            
                            Toggle("show full resolution", isOn: $viewModel.showFullResolution)
                              .foregroundColor(.white)

                            self.pixelReplacementModeView
                            
                            let frameView = viewModel.currentFrameView

                            AlignedNeighborFrameOverrideView(
                              focusedField: $focusedField
                            )

                            if !config.tripodHeadWasMoving {
                                StaticNeighborFrameOverrideView(
                                  focusedField: $focusedField
                                )
                            }

                            EditableNumberOfFramesToProcessConcurrentlyView(
                              focusedField: $focusedField,
                              textColor: .white,
                              alwaysOpen: false
                            )

                            Picker("redo", selection: $viewModel.reprocessingType) {
                                ForEach(FrameReprocessingType.allCases, id: \.self) { value in
                                    Text(value.rawValue).tag(value)
                                }
                            }
                              .foregroundColor(.white)
                              .frame(maxWidth: 120)
                                            
                            Button() {
                                Task {
                                    if let frame = viewModel.currentFrame {
                                        // XXX reprocess
                                        viewModel.processFrames(
                                          from: frame.frameIndex,
                                          to: frame.frameIndex+viewModel.numberOfFramesToProcess-1,
                                          performClean: true // uses viewModel.reprocessingType
                                        )
                                    }
                                }
                            } label: {
                                switch viewModel.reprocessingType {
                                case .none:
                                    Text("Process the next")
                                case .allHorizons:
                                    Text("Re-Process All Horizons")
                                default:
                                    Text("Re-Process the next")
                                }
                            }
                              .disabled(viewModel.renderingCurrentFrame)

                            if viewModel.reprocessingType != .allHorizons {
                                EditableNumberOfFramesToProcessView(
                                  focusedField: $focusedField,
                                  textColor: .white,
                                  alwaysOpen: false
                                )

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

                            // used for debugging stuck operation queue
/*
                            Button {
                                Task { 
                                   await frameGraphBuilder.debugPrint()
                                }
                            } label: {
                                Text("Log Operation Queue")
                            }
  */                          
                            // enable logging
                            HStack(spacing: 0) {
                                Toggle(isOn: $loggingViewModel.fileLogEnabled) {
                                    Text("")
                                      .foregroundColor(loggingViewModel.fileLogEnabled ? .black : .gray)
                                }
                                Text("Log to file at level:")
                                  .foregroundColor(loggingViewModel.fileLogEnabled ? .green : .white)
                            }
                            Picker(selection: $loggingViewModel.fileLogLevel) {
                                ForEach(Log.Level.allCases, id: \.self) { level in
                                    Text("\(level.emo) \(level.rawValue)")
                                }
                            } label: { }
                              .pickerStyle(.menu)
                              .fixedSize(horizontal: true, vertical: false)
                              .disabled(!loggingViewModel.fileLogEnabled)
                            
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
    
    var pixelReplacementModeView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            if viewModel.currentFrameHasOverriddenCleanMethod {
                Text("Custom")
                  .foregroundColor(.white)
            } else {
                Text("Default")
                  .foregroundColor(.white)
            }
            Picker("Clean:",
                   selection: $viewModel.currentFrameHighLevelCleanMethod)
            {
                ForEach(HighLevelCleanMethod.allCases, id: \.id) { value in
                    HStack {
                        switch value {
                        case .automatic:
                            AutoIcon()
                              .foregroundColor(.white)
                            Text("Automatic")
                              .foregroundColor(.white)
                            
                        case .selective:
                            SelectiveIcon()
                              .foregroundColor(.white)
                            Text("Selective")
                              .foregroundColor(.white)
                        }
                    }
                }
            }
              .foregroundColor(.white)
              .pickerStyle(.inline)

//            Text(AutoPreservationMode.topTitle)
//              .foregroundColor(.white)
            Picker("Auto Select",
                   selection: $viewModel.currentFrameAutoPreservationMode)
            {
                ForEach(AutoPreservationMode.allCases, id: \.id) { value in
                    HStack {
                        switch value {
                        case .yes:
                            AutoSelectiveIcon()
                              .foregroundColor(.white)
                        case .no:
                            AutoIcon()
                              .foregroundColor(.white)
                        }
                        Text(value.titleText)
                          .foregroundColor(.white)
                    }
                }
            }
              .foregroundColor(.white)
              .pickerStyle(.inline)
              .disabled(viewModel.currentFrameHighLevelCleanMethod != .automatic)


        }
          .fixedSize(horizontal: true, vertical: false)
    }
}

struct EditableMaxZoomView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding
    let textColor: Color
    let alwaysOpen: Bool
    @State private var zoomDouble: Double = 1
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return EditableNumberView(
          value: $zoomDouble,
          minValue: Double(viewModel.minZoomScale),
          maxValue: 10,
          fullTextProvider: { "Max: \($0)" },
          prefixText: "Max: ",
          suffixTextProvider: { _ in "" },
          textColor: textColor,
          focusedField: focusedField,
          focusField: .maxZoomLevel,
          alwaysOpen: alwaysOpen
          // no extra commit side‐effects here
        )
          .onAppear {
              zoomDouble = Double(viewModel.maxZoomScale)
          }
          .onChange(of: zoomDouble) {
              viewModel.maxZoomScale = CGFloat(zoomDouble)
              if viewModel.currentZoomScale > viewModel.maxZoomScale {
                  viewModel.currentZoomScale = viewModel.maxZoomScale
              }
          }
          .onChange(of: viewModel.maxZoomScale) {
              zoomDouble = Double(viewModel.maxZoomScale)
          }
    }
}

// "Pixel Threshold"
struct EditablePixelThresholdView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding
    let textColor: Color
    let alwaysOpen: Bool
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return EditableNumberView(
          value: $viewModel.pixelThreshold,
          minValue: 0.001,
          maxValue: 10,
          fullTextProvider: { "Pixel threshold: \($0)" },
          prefixText: "Pixel threshold: ",
          suffixTextProvider: { _ in "" },
          textColor: textColor,
          focusedField: focusedField,
          focusField: .pixelThreshold,
          alwaysOpen: alwaysOpen            
          // no extra commit side‐effects here
        )
    }
}

// “Number of Neighbor Frames”
struct EditableNumberOfNeighborFrames: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding
    let textColor: Color
    let alwaysOpen: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        return EditableNumberView(
          value: $viewModel.numberOfAlignedNeighborFrames,
          minValue: 1,
          maxValue: viewModel.imageSequenceSize,
          fullTextProvider: { "align with \($0) neighbor frames" },
          prefixText: "process with",
          suffixTextProvider: { _ in "neighbor frames" },
          textColor: textColor,
          focusedField: focusedField,
          focusField: .numberOfNeighborFrames,
          alwaysOpen: alwaysOpen
          // no extra commit side‐effects here
        )
    }
}

// “Number of Frames To Process Concurrently”

struct EditableNumberOfFramesToProcessConcurrentlyView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding
    let textColor: Color
    let alwaysOpen: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        return EditableNumberView(
            value: $viewModel.numberOfFramesToProcessConcurrently,
            minValue: 1,
            maxValue: ProcessInfo.processInfo.processorCount,
            fullTextProvider: { "process \($0) frames at once" },
            prefixText: "process",
            suffixTextProvider: { _ in "frames at once" },
            textColor: textColor,
            focusedField: focusedField,
            focusField: .numberOfFramesToProcessConcurrently,
            alwaysOpen: alwaysOpen,
            commitAction: { newVal in
                // persist to prefs & global
                viewModel.numberOfFramesToProcessConcurrently = newVal
                Task { await maxFramesProcessing.set(value: newVal) }
            }
        )
    }
}

// “Number of Frames To Process”
struct EditableNumberOfFramesToProcessView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding
    let textColor: Color
    let alwaysOpen: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        return EditableNumberView(
            value: $viewModel.numberOfFramesToProcess,
            minValue: 1,
            maxValue: viewModel.imageSequenceSize+1,
            fullTextProvider: { "\($0) frames as" },
            // no prefix, so TextField is first
            suffixTextProvider: { $0 == 1 ? "frame as" : "frames as" },
            textColor: textColor,
            focusedField: focusedField,
            focusField: .numberOfFramesToProcess,
            alwaysOpen: alwaysOpen
            // no extra commit side‐effects here
        )
    }
}

/// Shows and edits the per-frame override for numberAlignedNeighborFrames.
/// When the current frame has an override, a "Reset" button reverts it to the
/// global default.  Changing the value invalidates existing star-alignment
/// images and immediately triggers reprocessing for that frame.
struct AlignedNeighborFrameOverrideView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding

    @State private var localCount: Int = 8

    var body: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                /*
                if viewModel.currentFrameHasAlignedNeighborOverride {
                    Text("Custom")
                      .foregroundColor(.yellow)
                      .font(.caption)
                } else {
                    Text("Default")
                      .foregroundColor(.white)
                      .font(.caption)
                }
                Spacer()*/
                if viewModel.currentFrameHasAlignedNeighborOverride {
                    Button("Reset") {
                        viewModel.clearAlignedNeighborFrameOverride(forFrame: viewModel.currentIndex)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
            EditableNumberView(
              value: $localCount,
              minValue: 1,
              maxValue: viewModel.imageSequenceSize,
              fullTextProvider: { "align with \($0) neighbor frames" },
              prefixText: "align with",
              suffixTextProvider: { _ in "neighbor frames" },
              textColor: viewModel.currentFrameHasAlignedNeighborOverride ? .yellow : .white,
              focusedField: focusedField,
              focusField: .frameAlignedNeighborFrames,
              alwaysOpen: false,
              commitAction: { newVal in
                  viewModel.set(alignedNeighborFrames: newVal, forFrame: viewModel.currentIndex)
              }
            )
        }
        .onAppear { localCount = viewModel.currentFrameAlignedNeighborCount }
        .onChange(of: viewModel.currentIndex) {
            localCount = viewModel.currentFrameAlignedNeighborCount
        }
        .onChange(of: viewModel.alignedNeighborFrameOverrides) {
            localCount = viewModel.currentFrameAlignedNeighborCount
        }
        .onChange(of: viewModel.numberOfAlignedNeighborFrames) {
            // if the global default changes, update display when not overridden
            if !viewModel.currentFrameHasAlignedNeighborOverride {
                localCount = viewModel.numberOfAlignedNeighborFrames
            }
        }
    }
}

/// Shows and edits the per-frame override for numberStaticNeighborFrames.
/// When the current frame has an override, a "Reset" button reverts it to the
/// global default.  Changing the value triggers an immediate merged-horizon
/// recompute if the horizon has already been computed for that frame.
struct StaticNeighborFrameOverrideView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding

    /// Local editable copy, kept in sync with the effective count for the
    /// current frame (override if present, otherwise global default).
    @State private var localCount: Int = 16

    var body: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                /*
                if viewModel.currentFrameHasStaticNeighborOverride {
                    Text("Custom")
                      .foregroundColor(.yellow)
                      .font(.caption)
                } else {
                    Text("Default")
                      .foregroundColor(.white)
                      .font(.caption)
                }*/
//                Spacer()
                if viewModel.currentFrameHasStaticNeighborOverride {
                    Button("Reset") {
                        viewModel.clearStaticNeighborFrameOverride(forFrame: viewModel.currentIndex)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .tint(.orange)
                }
            }
            EditableNumberView(
              value: $localCount,
              minValue: 1,
              maxValue: viewModel.imageSequenceSize,
              fullTextProvider: { "merge with \($0) static neighbors" },
              prefixText: "static merge",
              suffixTextProvider: { _ in "neighbors" },
              textColor: viewModel.currentFrameHasStaticNeighborOverride ? .yellow : .white,
              focusedField: focusedField,
              focusField: .frameStaticNeighborFrames,
              alwaysOpen: false,
              commitAction: { newVal in
                  viewModel.set(staticNeighborFrames: newVal, forFrame: viewModel.currentIndex)
              }
            )
        }
        .onAppear { localCount = viewModel.currentFrameStaticNeighborCount }
        .onChange(of: viewModel.currentIndex) {
            localCount = viewModel.currentFrameStaticNeighborCount
        }
        .onChange(of: viewModel.staticNeighborFrameOverrides) {
            localCount = viewModel.currentFrameStaticNeighborCount
        }
        .onChange(of: viewModel.numberStaticNeighborFrames) {
            // if the global default changes, update display when not overridden
            if !viewModel.currentFrameHasStaticNeighborOverride {
                localCount = viewModel.numberStaticNeighborFrames
            }
        }
    }
}
