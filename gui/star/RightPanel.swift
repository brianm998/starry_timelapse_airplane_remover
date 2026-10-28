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

    // which sections are open; all start open.  Kept here rather than in the
    // view model: this view stays alive while the panel is hidden, so it survives that
    @State private var expandedSections = Set(RightPanelSectionKind.allCases)
    @State private var showingChangeMode = false

    private func isExpanded(_ kind: RightPanelSectionKind) -> Binding<Bool> {
        Binding(
          get: { expandedSections.contains(kind) },
          set: { if $0 { expandedSections.insert(kind) } else { expandedSections.remove(kind) } }
        )
    }

    var body: some View {
        return Group {
            if viewModel.rightPanelShowing {
                VStack(alignment: .leading) {
                    ScrollView {
                        VStack(alignment: .leading) {
                            // the selective tools only do anything when this frame has
                            // outliers to work on, so they are not shown at all otherwise
                            if viewModel.currentFrameUsesOutliers {
                                self.selectiveToolsSection
                                Divider()
                            }
                            self.displaySection
                            Divider()
                            self.processingSection
                            Divider()
                            self.debugSection
                        }
                          // room under the last control, so it can always be scrolled
                          // clear of the panel's close chevron and stays clickable
                          .padding(.bottom, 32)
                          // a floor, so the panel is not a sliver while every section is
                          // collapsed, and does not jump much as sections open and close
                          .frame(minWidth: 180, alignment: .leading)
                          // as wide as its widest control, and no wider: the dividers
                          // would otherwise stretch the panel across the window
                          .fixedSize(horizontal: true, vertical: false)
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
    
    // MARK: - Selective Tools

    var selectiveToolsSection: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            RightPanelSectionHeader(title: localized("ui.section.selective_tools"),
                                    help: localized("ui.section.selective_tools_help"),
                                    isExpanded: self.isExpanded(.selectiveTools))

            if expandedSections.contains(.selectiveTools) {
                HStack {
                    Text(localized("ui.tool"))
                      .foregroundColor(.white)
                    ToolHelpButton()
                }
                  .help(localized("ui.tool_help"))
                VerticalStarPicker(nil, selection: $viewModel.selectionMode) { value, isEnabled, isSelected in
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
                      .help(isEnabled ?
                              value.helpText :
                              localized("tool.help.disabled"))
                }

                Toggle(localized("ui.multi_choice"), isOn: $viewModel.multiChoice)
                  .foregroundColor(.white)
                  .help(localized("ui.multi_choice_help"))

                Toggle(localized("ui.show_trash"), isOn: $viewModel.shouldShowTrash)
                  .foregroundColor(.white)
                  .help(localized("ui.show_trash_help"))

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
                  .help(localized("ui.only_unclassified_help"))

                Group {
                    Text(localized("ui.outlier_group_opacity"))
                      .foregroundColor(.white)
                    Slider(value: $viewModel.outlierOpacity, in : 0...1)
                      .frame(maxWidth: 140, alignment: .bottom)
                }
                  .help(localized("ui.outlier_group_opacity_help"))

                Group {
                    Text(localized("ui.trash_opacity"))
                      .foregroundColor(.white)
                    Slider(value: $viewModel.trashOpacity, in : 0...1)
                      .frame(maxWidth: 140, alignment: .bottom)
                }
                  .help(localized("ui.trash_opacity_help"))
            }
        }
    }

    // MARK: - Display

    var displaySection: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            RightPanelSectionHeader(title: localized("ui.display"),
                                    help: localized("ui.section.display_help"),
                                    isExpanded: self.isExpanded(.display))

            if expandedSections.contains(.display) {
                Group {
                    Text(localized("ui.fast_advancement_type"))
                      .foregroundColor(.white)

                    Picker("", selection: $viewModel.fastAdvancementType) {
                        ForEach(FastAdvancementType.allCases, id: \.self) { value in
                            Text(value.localizedName).tag(value)
                        }
                    }
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
                }
                  .help(localized("ui.fast_advancement_type_help"))

    //                    Toggle(skipEmpties ? "change to # of frames" : "change to skip empties",
    //                           isOn: $skipEmpties)

                // XXX add advance to has undecided
                // XXX add advance to has paintable
                // XXX add advance to has not paintable

                if viewModel.fastAdvancementType == .normal {
                    Group {
                        Text(localized("ui.fast_skip"))
                          .foregroundColor(.white)
                        Picker("", selection: $viewModel.fastSkipAmount) {
                            ForEach(0 ..< 51) {
                                Text(localized("ui.n_frames_lower", $0))
                            }
                        }.frame(maxWidth: 140)
                    }
                      .help(localized("ui.fast_skip_help"))
                }

                Group {
                    Toggle(localized("ui.show_horizon_line"), isOn: Binding(
                        get: { viewModel.userPreferences.showHorizonOnMainView ?? false },
                        set: { viewModel.userPreferences.showHorizonOnMainView = $0 }
                    ))
                      .foregroundColor(.white)

                    HorizonLineKindToggles()
                }
                  .help(localized("ui.show_horizon_line_help"))

                // frame rate
                let frame_rates = [1, 2, 3, 5, 10, 15, 20, 25, 30, 60, 90]
                Group {
                    Text(localized("ui.frame_rate"))
                      .foregroundColor(.white)
                    Picker("", selection: $viewModel.videoPlaybackFramerate) {
                        ForEach(frame_rates, id: \.self) {
                            Text(localized("ui.n_fps", $0))
                        }
                    }.frame(maxWidth: 100)
                }
                  .help(localized("ui.frame_rate_help"))

                // not disabled with the overlays: it dims the frame itself, so it
                // is useful in every clean mode
                Group {
                    Text(localized("ui.frame_opacity"))
                      .foregroundColor(.white)
                    Slider(value: $viewModel.frameOpacity, in : 0...1)
                      .frame(maxWidth: 140, alignment: .bottom)
                }
                  .help(localized("ui.frame_opacity_help"))

                Group {
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
                }
                  .help(localized("ui.zoom_help"))

                Toggle(localized("ui.show_full_resolution"), isOn: $viewModel.showFullResolution)
                  .foregroundColor(.white)
                  .help(localized("ui.show_full_resolution_help"))
            }
        }
    }

    // MARK: - Processing

    var processingSection: some View {
        @Bindable var viewModel = viewModel
        let config = viewModel.config.config()
        let frameView = viewModel.currentFrameView
        return VStack(alignment: .leading) {
            RightPanelSectionHeader(title: localized("ui.processing"),
                                    help: localized("ui.section.processing_help"),
                                    isExpanded: self.isExpanded(.processing))

            if expandedSections.contains(.processing) {
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
                .help(localized("ui.paint_horizon_reference_help"))

                Button {
                    viewModel.reprocessHorizonsForUpdatedReferences()
                } label: {
                    Label(localized("ui.re_run_horizon_refinement"), systemImage: "wand.and.stars")
                }
                .buttonStyle(.bordered)
                .tint(.orange)
                .help(localized("ui.re_run_brightness_position_refinement_for"))
                .disabled(!viewModel.hasPendingHorizonRefinement)

                self.pixelReplacementModeView

                if !config.tripodHeadWasMoving {
                    StaticNeighborFrameOverrideView(
                      focusedField: $focusedField
                    )
                      .help(localized("ui.static_merge_help"))
                }

                ResourceProfileView(textColor: .white)

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
                  .help(localized("ui.render_updates_help"))

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
            }
        }
    }

    // MARK: - Debug

    var debugSection: some View {
        @Bindable var loggingViewModel = loggingViewModel
        return VStack(alignment: .leading) {
            RightPanelSectionHeader(title: localized("ui.section.debug"),
                                    help: localized("ui.section.debug_help"),
                                    isExpanded: self.isExpanded(.debug))

            if expandedSections.contains(.debug) {
                // enable logging
                Group {
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
                  .help(localized("ui.log_to_file_help"))
            }
        }
    }

    var pixelReplacementModeView: some View {
        let method = viewModel.getCleanMethod(forFrame: viewModel.currentIndex)
        let name = method.frameModeName
        let text = viewModel.currentFrameHasOverriddenCleanMethod
          ? localized("ui.processing_mode_current_custom", name)
          : localized("ui.processing_mode_current_default", name)
        return HStack {
            Text(text)
              .foregroundColor(.white)
            Spacer(minLength: 8)
            Button(localized("ui.change_mode")) {
                showingChangeMode = true
            }
              .help(localized("ui.clean_method_help"))
        }
          .sheet(isPresented: $showingChangeMode) {
              ChangeProcessingModeView()
          }
    }
}

extension CleanMethod {
    /// The name of this mode as the change-mode dialog and the panel show it.
    var frameModeName: String {
        switch self {
        case .automatic(let usesOutliers):
            localized(usesOutliers ? "ui.frame_mode_auto_selective" : "ui.frame_mode_automatic")
        case .selective:
            localized("ui.frame_mode_selective")
        }
    }

    var frameModeDescription: String {
        switch self {
        case .automatic(let usesOutliers):
            localized(usesOutliers ? "ui.frame_mode_desc_auto_selective" : "ui.frame_mode_desc_automatic")
        case .selective:
            localized("ui.frame_mode_desc_selective")
        }
    }
}

/// Changes the current frame's processing mode.  The two choices are held here and only
/// reach the frame when OK is pressed; Cancel leaves the frame as it was.
struct ChangeProcessingModeView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var clean: HighLevelCleanMethod = .automatic
    @State private var autoSelect: AutoPreservationMode = .no
    @State private var loaded = false

    private var currentMethod: CleanMethod {
        viewModel.getCleanMethod(forFrame: viewModel.currentIndex)
    }

    private var newMethod: CleanMethod {
        CleanMethod(highLevelCleanMethod: clean, autoPreservationMode: autoSelect)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(localized("ui.change_mode_title"))
              .font(.title)

            VStack(alignment: .leading, spacing: 4) {
                Text(localized("ui.processing_mode_current", currentMethod.frameModeName))
                  .font(.headline)
                Text(currentMethod.frameModeDescription)
                  .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Picker(localized("ui.clean"), selection: $clean) {
                ForEach(HighLevelCleanMethod.allCases, id: \.id) { value in
                    HStack {
                        switch value {
                        case .automatic: AutoIcon()
                        case .selective: SelectiveIcon()
                        }
                        Text(localized(value == .automatic ? "ui.automatic" : "ui.selective"))
                    }
                }
            }
              .pickerStyle(.inline)
              .help(localized("ui.clean_method_help"))

            Picker(localized("ui.auto_select"), selection: $autoSelect) {
                ForEach(AutoPreservationMode.allCases, id: \.id) { value in
                    HStack {
                        switch value {
                        case .yes: AutoSelectiveIcon()
                        case .no: AutoIcon()
                        }
                        Text(value.titleText)
                    }
                }
            }
              .pickerStyle(.inline)
              .disabled(clean != .automatic)
              .help(localized("ui.auto_select_help"))

            Group {
                if newMethod == currentMethod {
                    Text(localized("ui.change_mode_none"))
                      .foregroundColor(.secondary)
                } else {
                    Text(localized("ui.change_mode_summary",
                                   currentMethod.frameModeName,
                                   newMethod.frameModeName,
                                   newMethod.frameModeDescription))
                }
            }
              .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button(localized("ui.cancel")) {
                    dismiss()
                }
                  .keyboardShortcut(.cancelAction)

                Spacer()

                Button(localized("ui.ok")) {
                    viewModel.applyCleanMethodToCurrentFrame(newMethod)
                    dismiss()
                }
                  .keyboardShortcut(.defaultAction)
                  .buttonStyle(.borderedProminent)
                  .tint(.blue)
                  .disabled(newMethod == currentMethod)
            }
        }
          .padding(24)
          .frame(width: 460)
          .onAppear {
              guard !loaded else { return }
              loaded = true
              switch currentMethod {
              case .automatic(let usesOutliers):
                  clean = .automatic
                  autoSelect = usesOutliers ? .yes : .no
              case .selective:
                  clean = .selective
                  autoSelect = .no
              }
          }
    }
}

enum RightPanelSectionKind: Hashable, CaseIterable {
    case selectiveTools
    case display
    case processing
    case debug
}

/// The labeled top of each right panel section; hovering it explains the section,
/// clicking it opens or closes the section.  The chevron points right while closed
/// and down while open.
struct RightPanelSectionHeader: View {
    let title: String
    let help: String
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                  .font(.caption.weight(.bold))
                  .rotationEffect(.degrees(isExpanded ? 90 : 0))
                  .frame(width: 12)
                Text(title)
                  .font(.headline)
            }
              .foregroundColor(.white)
              .contentShape(Rectangle())
        }
          .buttonStyle(.plain)
          .padding(.top, 4)
          .help(help)
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
          maxValue: viewModel.imageSequenceSize - 1,
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
            maxValue: viewModel.imageSequenceSize,
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
              maxValue: viewModel.imageSequenceSize - 1,
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

/// "Use of this Mac": Full / Balanced / Light, plus Custom… for every limit by hand, and the
/// resource governor's one-line answer to "what is holding this run back?".
struct ResourceProfileView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let textColor: Color

    @State private var showCustom = false
    @State private var status: String? = nil

    private var profileBinding: Binding<ResourceProfile?> {
        Binding(
          get: { viewModel.resourceProfile == .custom ? nil : viewModel.resourceProfile },
          set: { if let value = $0 { viewModel.resourceProfile = value } }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(localized("ui.use_of_this_mac"))
              .foregroundColor(textColor)
            // Stacked, not a segmented row: the right panel is narrow, and four buttons
            // side by side made the control wider than everything around it.
            Picker("", selection: profileBinding) {
                Text(localized("ui.use_full")).foregroundColor(textColor).tag(ResourceProfile?.some(.full))
                Text(localized("ui.use_balanced")).foregroundColor(textColor).tag(ResourceProfile?.some(.balanced))
                Text(localized("ui.use_light")).foregroundColor(textColor).tag(ResourceProfile?.some(.light))
            }
              .pickerStyle(.radioGroup)
              .colorScheme(.dark)
              .labelsHidden()
            Button(localized("ui.use_custom")) {
                if viewModel.resourceProfile != .custom {
                    viewModel.resourceProfile = .custom
                }
                showCustom = true
            }
              .buttonStyle(.borderedProminent)
              .tint(viewModel.resourceProfile == .custom ? .accentColor : .gray)
              .controlSize(.small)
              .popover(isPresented: $showCustom) {
                  ResourceCustomLimitsView()
                    .environment(viewModel)
              }
            if let status {
                Text(status)
                  .font(.caption)
                  .foregroundColor(.gray)
            }
        }
        .help(localized("ui.use_of_this_mac_help"))
        .task {
            // The governor samples every few seconds; ask at the same pace.
            while !Task.isCancelled {
                if let latest = await ResourceGovernor.shared.latest {
                    status = latest.limitedBy.map {
                        localized("ui.use_status_limited", $0.description)
                    } ?? localized("ui.use_status_none")
                } else {
                    status = nil
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }
}

/// Every limit behind a profile as an editable field. Opened pre-filled from the profile it
/// was opened from; changes reach the running pipeline at once.
struct ResourceCustomLimitsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 10) {
            Text(localized("ui.use_custom_title"))
              .font(.headline)
            Stepper(value: $viewModel.numberOfFramesToProcessConcurrently, in: 1...1024) {
                Text("\(localized("ui.use_custom_pipeline_depth")): \(viewModel.numberOfFramesToProcessConcurrently)")
            }
            VStack(alignment: .leading) {
                Text("\(localized("ui.use_custom_memory")): \(viewModel.memoryBudgetFraction, specifier: "%.2f")")
                Slider(value: $viewModel.memoryBudgetFraction, in: 0.1...0.95)
            }
            Stepper(value: $viewModel.customResources.cpuWidth, in: 1...256) {
                Text("\(localized("ui.use_custom_cpu")): \(viewModel.customResources.cpuWidth)")
            }
            Stepper(value: $viewModel.customResources.gpuWidth, in: 1...32) {
                Text("\(localized("ui.use_custom_gpu")): \(viewModel.customResources.gpuWidth)")
            }
            VStack(alignment: .leading) {
                Text("\(localized("ui.use_custom_gpu_duty")): \(viewModel.customResources.gpuDutyCycle, specifier: "%.2f")")
                Slider(value: $viewModel.customResources.gpuDutyCycle, in: 0.05...1.0)
            }
            Stepper(value: $viewModel.customResources.diskStreamsPerVolume, in: 1...16) {
                Text("\(localized("ui.use_custom_disk")): \(viewModel.customResources.diskStreamsPerVolume)")
            }
            Picker(localized("ui.use_custom_qos"), selection: $viewModel.customResources.qos) {
                Text(localized("ui.use_custom_qos_user_initiated")).tag(ResourceQoS.userInitiated)
                Text(localized("ui.use_custom_qos_utility")).tag(ResourceQoS.utility)
                Text(localized("ui.use_custom_qos_background")).tag(ResourceQoS.background)
            }
            Picker(localized("ui.use_custom_io"), selection: $viewModel.customResources.ioPolicy) {
                Text(localized("ui.use_custom_io_default")).tag(ResourceIOPolicy.default)
                Text(localized("ui.use_custom_io_utility")).tag(ResourceIOPolicy.utility)
                Text(localized("ui.use_custom_io_throttle")).tag(ResourceIOPolicy.throttle)
            }
        }
        .padding()
        .frame(width: 420)
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
