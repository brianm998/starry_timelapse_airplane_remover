import SwiftUI
import StarCore
import logging

public enum FastAdvancementType: String, Equatable, CaseIterable {
    case normal
    case skipEmpties
    case toNextPositive
    case toNextNegative
    case toNextUnknown
    
    var localizedName: String {
        localized("fast_advancement.\(rawValue)")
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

                            Text(localized("ui.fast_advancement_type"))
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
                                Text(localized("ui.fast_skip_n_frames", viewModel.fastSkipAmount))
                                  .frame(maxWidth: 140)
                                  .multilineTextAlignment(.leading)
                                  .foregroundColor(.white)
                            case .skipEmpties:
                                Text(localized("ui.skip_all_frames_without_outliers"))
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextPositive:
                                Text(localized("ui.skip_to_next_frame_with_a_positive_outlier"))
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextNegative:
                                Text(localized("ui.skip_to_next_frame_with_a_negative_outlier"))
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextUnknown:
                                Text(localized("ui.skip_to_next_frame_with_a_unknown_outlier"))
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            }

//                    Toggle(skipEmpties ? "change to # of frames" : "change to skip empties",
//                           isOn: $skipEmpties)

                    // XXX add advance to has undecided
                    // XXX add advance to has paintable
                    // XXX add advance to has not paintable
                    
                            if viewModel.fastAdvancementType == .normal {
                                Text(localized("ui.fast_skip"))
                                  .foregroundColor(.white)
                                Picker("", selection: $viewModel.fastSkipAmount) {
                                    ForEach(0 ..< 51) {
                                        Text(localized("ui.n_frames_lower", $0))
                                    }
                                }.frame(maxWidth: 140)
                            }

                            VerticalStarPicker(localized("ui.tool"), selection: $viewModel.selectionMode) { value, isEnabled, isSelected in
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


                            Toggle(localized("ui.multi_choice"), isOn: $viewModel.multiChoice)
                              .foregroundColor(.white)
   
                            // ── Horizon painting ───────────────────────
                            Button {
                                viewModel.isShowingHorizonPainter.toggle()
                            } label: {
                                Label(
                                    viewModel.isShowingHorizonPainter
                                        ? localized("ui.close_horizon_painter")
                                        : localized("ui.paint_horizon_reference"),
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

                            Button {
                                viewModel.reprocessHorizonsForUpdatedReferences()
                            } label: {
                                Label(localized("ui.re_run_horizon_refinement"), systemImage: "wand.and.stars")
                            }
                            .buttonStyle(.bordered)
                            .tint(.orange)
                            .help(localized("ui.re_run_brightness_position_refinement_for"))
                            .disabled(!viewModel.hasPendingHorizonRefinement)

                            Toggle(localized("ui.show_trash"), isOn: $viewModel.shouldShowTrash)
                              .foregroundColor(.white)
                              .disabled(!viewModel.currentFrameUsesOutliers)

                            Toggle(localized("ui.show_horizon_line"), isOn: Binding(
                                get: { viewModel.userPreferences.showHorizonOnMainView ?? false },
                                set: { viewModel.userPreferences.showHorizonOnMainView = $0 }
                            ))
                              .foregroundColor(.white)

                            /*
                             XXX for some unknown reason, these grab focus and refuse
                             XXX to let it go :(
                             
                            Text(localized("ui.trash_level"))
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

                              Text(localized("ui.small_trash_max"))
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
                            Text(localized("ui.minimum_classification_size"))
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
                            
                            Toggle(localized("ui.only_unclassified"),
                              isOn: $viewModel.classifyOnlyUnclassified
                            )
                              .foregroundColor(.orange)
                            
                            // frame rate 
                            let frame_rates = [1, 2, 3, 5, 10, 15, 20, 25, 30, 60, 90]
                            Text(localized("ui.frame_rate"))
                              .foregroundColor(.white)
                            Picker("", selection: $viewModel.videoPlaybackFramerate) {
                                ForEach(frame_rates, id: \.self) {
                                    Text(localized("ui.n_fps", $0))
                                }
                            }.frame(maxWidth: 100)


                            VStack(alignment: .leading) {
                                // outlier opacity slider
                                Text(localized("ui.outlier_group_opacity"))
                                  .foregroundColor(.white)
                                
                                Slider(value: $viewModel.outlierOpacity, in : 0...1)
                                  .frame(maxWidth: 140, alignment: .bottom)
                                
                                Text(localized("ui.trash_opacity"))
                                  .foregroundColor(.white)
                                
                                Slider(value: $viewModel.trashOpacity, in : 0...1)
                                  .frame(maxWidth: 140, alignment: .bottom)
                                
                                Text(localized("ui.frame_opacity"))
                                  .foregroundColor(.white)
                                
                                Slider(value: $viewModel.frameOpacity, in : 0...1)
                                  .frame(maxWidth: 140, alignment: .bottom)
                            }
                              .disabled(!viewModel.currentFrameUsesOutliers)


                            HStack {
                                Text(localized("ui.zoom"))
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
                            
                            Toggle(localized("ui.show_full_resolution"), isOn: $viewModel.showFullResolution)
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

                            MemoryMultiplierView(
                              focusedField: $focusedField,
                              textColor: .white,
                              alwaysOpen: false
                            )

                            Picker(localized("ui.redo"), selection: $viewModel.reprocessingType) {
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
                                    Text(localized("ui.process_the_next"))
                                case .allHorizons:
                                    Text(localized("ui.re_process_all_horizons"))
                                default:
                                    Text(localized("ui.re_process_the_next"))
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
                                    do {
                                        if let frame = viewModel.currentFrame {
                                            try await viewModel.render(frame: frame, now: true)
                                        }
                                    } catch {
                                        viewModel.report(error: localized("ui.render_failed", error))
                                    }
                                }
                            } label: {
                                Text(localized("ui.render_updates"))
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
                                Text(localized("ui.log_operation_queue"))
                            }
  */                          
                            // enable logging
                            HStack(spacing: 0) {
                                Toggle(isOn: $loggingViewModel.fileLogEnabled) {
                                    Text("")
                                      .foregroundColor(loggingViewModel.fileLogEnabled ? .black : .gray)
                                }
                                Text(localized("ui.log_to_file_at_level_2"))
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
                      .focusable(false)

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
                Text(localized("ui.custom"))
                  .foregroundColor(.white)
            } else {
                Text(localized("ui.default"))
                  .foregroundColor(.white)
            }
            Picker(localized("ui.clean"),
                   selection: $viewModel.currentFrameHighLevelCleanMethod)
            {
                ForEach(HighLevelCleanMethod.allCases, id: \.id) { value in
                    HStack {
                        switch value {
                        case .automatic:
                            AutoIcon()
                              .foregroundColor(.white)
                            Text(localized("ui.automatic"))
                              .foregroundColor(.white)
                            
                        case .selective:
                            SelectiveIcon()
                              .foregroundColor(.white)
                            Text(localized("ui.selective"))
                              .foregroundColor(.white)
                        }
                    }
                }
            }
              .foregroundColor(.white)
              .pickerStyle(.inline)

//            Text(AutoPreservationMode.topTitle)
//              .foregroundColor(.white)
            Picker(localized("ui.auto_select"),
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
          fullTextProvider: { localized("ui.slider.max_zoom", $0) },
          prefixText: localized("ui.slider.max_zoom_prefix"),
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
          fullTextProvider: { localized("ui.slider.pixel_threshold", $0) },
          prefixText: localized("ui.slider.pixel_threshold_prefix"),
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
          fullTextProvider: { localized("ui.slider.align_neighbors", $0) },
          prefixText: localized("ui.slider.process_with"),
          suffixTextProvider: { _ in localized("ui.slider.neighbor_frames") },
          textColor: textColor,
          focusedField: focusedField,
          focusField: .numberOfNeighborFrames,
          alwaysOpen: alwaysOpen
          // no extra commit side‐effects here
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
            fullTextProvider: { localized("ui.slider.n_frames_as", $0) },
            // no prefix, so TextField is first
            suffixTextProvider: { $0 == 1 ? localized("ui.slider.frame_as") : localized("ui.slider.frames_as") },
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
                    Text(localized("ui.custom"))
                      .foregroundColor(.yellow)
                      .font(.caption)
                } else {
                    Text(localized("ui.default"))
                      .foregroundColor(.white)
                      .font(.caption)
                }
                Spacer()*/
                if viewModel.currentFrameHasAlignedNeighborOverride {
                    Button(localized("ui.reset")) {
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
              fullTextProvider: { localized("ui.slider.align_neighbors", $0) },
              prefixText: localized("ui.slider.align_with"),
              suffixTextProvider: { _ in localized("ui.slider.neighbor_frames") },
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
                    Text(localized("ui.custom"))
                      .foregroundColor(.yellow)
                      .font(.caption)
                } else {
                    Text(localized("ui.default"))
                      .foregroundColor(.white)
                      .font(.caption)
                }*/
//                Spacer()
                if viewModel.currentFrameHasStaticNeighborOverride {
                    Button(localized("ui.reset")) {
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
              fullTextProvider: { localized("ui.slider.merge_static", $0) },
              prefixText: localized("ui.slider.static_merge"),
              suffixTextProvider: { _ in localized("ui.slider.neighbors") },
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
            fullTextProvider: { localized("ui.slider.process_at_once", $0) },
            prefixText: localized("ui.slider.process"),
            suffixTextProvider: { _ in localized("ui.slider.frames_at_once") },
            textColor: textColor,
            focusedField: focusedField,
            focusField: .numberOfFramesToProcessConcurrently,
            alwaysOpen: alwaysOpen,
            commitAction: { newVal in
                viewModel.numberOfFramesToProcessConcurrently = newVal
            }
        )
    }
}

struct MemoryMultiplierView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let focusedField: FocusState<FocusedField?>.Binding
    let textColor: Color
    let alwaysOpen: Bool

    var body: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 4) {
            EditableNumberView(
                value: $viewModel.keypointMemoryMultiplier,
                minValue: 1,
                maxValue: 200,
                fullTextProvider: { localized("ui.slider.kp_mem", $0) },
                prefixText: localized("ui.slider.kp_mem_prefix"),
                suffixTextProvider: { _ in "" },
                textColor: textColor,
                focusedField: focusedField,
                focusField: .keypointMemoryMultiplier,
                alwaysOpen: alwaysOpen,
                commitAction: { newVal in
                    viewModel.keypointMemoryMultiplier = newVal
                }
            )
            // Separate from kp mem on purpose: kp mem is the *estimate* of one op's
            // memory, this is how many may run at once.  Raising kp mem to calm a big
            // sequence used to be the only lever, and it inflated every reservation as
            // a side effect.  0 = no explicit cap.
            EditableNumberView(
                value: $viewModel.maxConcurrentKeypointOps,
                minValue: 0,
                maxValue: 256,
                fullTextProvider: { $0 == 0 ? localized("ui.slider.max_kp_ops_auto") : localized("ui.slider.max_kp_ops", $0) },
                prefixText: localized("ui.slider.max_kp_ops_prefix"),
                suffixTextProvider: { _ in "" },
                textColor: textColor,
                focusedField: focusedField,
                focusField: .maxConcurrentKeypointOps,
                alwaysOpen: alwaysOpen,
                commitAction: { newVal in
                    viewModel.maxConcurrentKeypointOps = newVal
                }
            )
            EditableNumberView(
                value: $viewModel.outlierMemoryMultiplier,
                minValue: 1,
                maxValue: 50,
                fullTextProvider: { localized("ui.slider.outlier_mem", $0) },
                prefixText: localized("ui.slider.outlier_mem_prefix"),
                suffixTextProvider: { _ in "" },
                textColor: textColor,
                focusedField: focusedField,
                focusField: .outlierMemoryMultiplier,
                alwaysOpen: alwaysOpen,
                commitAction: { newVal in
                    viewModel.outlierMemoryMultiplier = newVal
                }
            )
            EditableNumberView(
                value: $viewModel.mergeMemoryMultiplier,
                minValue: 1,
                maxValue: 50,
                fullTextProvider: { localized("ui.slider.merge_mem", $0) },
                prefixText: localized("ui.slider.merge_mem_prefix"),
                suffixTextProvider: { _ in "" },
                textColor: textColor,
                focusedField: focusedField,
                focusField: .mergeMemoryMultiplier,
                alwaysOpen: alwaysOpen,
                commitAction: { newVal in
                    viewModel.mergeMemoryMultiplier = newVal
                }
            )
            EditableNumberView(
                value: $viewModel.horizonMemoryMultiplier,
                minValue: 1,
                maxValue: 50,
                fullTextProvider: { localized("ui.slider.horizon_mem", $0) },
                prefixText: localized("ui.slider.horizon_mem_prefix"),
                suffixTextProvider: { _ in "" },
                textColor: textColor,
                focusedField: focusedField,
                focusField: .horizonMemoryMultiplier,
                alwaysOpen: alwaysOpen,
                commitAction: { newVal in
                    viewModel.horizonMemoryMultiplier = newVal
                }
            )
            // Paired with horizon mem on purpose, and the more useful of the two: a
            // horizon op's cost barely tracks the frame size, so the multiplier alone
            // under-reserves on small frames and this is what covers them.  0 = no floor.
            EditableNumberView(
                value: $viewModel.horizonReservationFloorMB,
                minValue: 0,
                maxValue: 16384,
                fullTextProvider: { $0 == 0 ? localized("ui.slider.horizon_floor_none") : localized("ui.slider.horizon_floor", $0) },
                prefixText: localized("ui.slider.horizon_floor_prefix"),
                suffixTextProvider: { _ in "MB" },
                textColor: textColor,
                focusedField: focusedField,
                focusField: .horizonReservationFloorMB,
                alwaysOpen: alwaysOpen,
                commitAction: { newVal in
                    viewModel.horizonReservationFloorMB = newVal
                }
            )
        }
    }
}
