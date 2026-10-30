import SwiftUI
import StarCore
import logging

/// What the Process / Show Progress button (bottom right) offers.
///
/// A value rather than a pair of conditions spelled out in the view, because it is two
/// different buttons sharing one place on screen and the rule for which one it is has to
/// be readable: while a run is going it is the only way back to a processing modal that
/// has been dismissed, and that is not something the frame counts can be allowed to
/// disable.
enum ProcessingButtonRole: Equatable {
    /// Opens the settings sheet, which is where a run is started from.
    case process(enabled: Bool)

    /// Puts the processing modal back up over the window.  Never disabled: it does not
    /// start anything, and a run in progress always has a status to show.
    case status

    static func current(
      isProcessingFrames: Bool,
      isRenderingVideo: Bool,
      unprocessedCount: Int,
      horizonDetectedCount: Int,
      frameCount: Int,
      pendingHorizonRefinement: Bool = false
    ) -> ProcessingButtonRole {
        if isProcessingFrames { return .status }

        // Nothing left that has not been processed, and not the one other state worth
        // processing from — every frame stopped at horizon detection — and no horizon
        // reference waiting to be applied.  That last one is work a finished sequence can
        // still be owed: the frames it affects were rendered with a horizon the user has
        // since corrected, and this run is one of the two ways to redo them.
        let nothingToDo = unprocessedCount == 0
          && horizonDetectedCount != frameCount
          && !pendingHorizonRefinement
        return .process(enabled: !nothingToDo && !isRenderingVideo)
    }
}

struct LeftPanel: View {
    /// The playback speeds the Display picker offers, in frames per second.  The desktop's picker offers the same
    /// (`gherkin/ui/vectors/constants.json` holds the list, and a test on each side checks it).
    static let playbackFrameRates = [1, 2, 3, 5, 10, 15, 20, 25, 30, 60, 90]

    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    @FocusState private var focusedField: FocusedField?
    // kept here rather than in the view model: this view stays alive while the panel is hidden
    @State private var displayExpanded = true

    var body: some View {
        Group {
            if viewModel.leftPanelShowing {
                self.openView
            } else {
                self.closedView
            }
        }
    }

    var openView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .trailing) {

            ScrollView() {
                VStack(alignment: .leading) {

                    ProcessingProgressMarker()


                    self.frameModeView

                    Space(height: 10)

                    self.displaySection

                }
                //                          .frame(maxWidth: 200)
            }
              .defaultScrollAnchor(.bottom)
              .focusable(false)
           //   .frame(maxHeight: .infinity, alignment: .bottom)

            Spacer()
            
            Button() {
                viewModel.leftPanelShowing = false
            } label: {
                Image(systemName: "chevron.left.2")
                  .foregroundColor(.gray)
            }
              .buttonStyle(PlainButtonStyle())
              .cursor(.resizeLeft)
        }
          .padding(10)
          .background(Color(white: 0.22).zIndex(0))
          .frame(maxHeight: .infinity, alignment: .bottom)
        
    }

    var frameModeView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            Text(localized("ui.show_2"))
              .foregroundColor(.white)
            
            VerticalLimitedSelectionPicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                let hasImage = viewModel.currentFrameView.hasImage(type: value)
                let shouldShow = hasImage && (
                    (!viewModel.showAllFrameViewModes && (value == .original || value == .final || value == .userHorizon))
                    || viewModel.showAllFrameViewModes
                )
                if shouldShow {
                    let color: Color = isEnabled ? .black : .yellow
                    HStack {
                        Text(value.longName)
                          .foregroundColor(color)
                          .padding(4)
                          .onTapGesture { _ in
                              viewModel.frameViewMode = value
                          }
                        Spacer()
                    }
                }
            }
              .fixedSize(horizontal: true, vertical: false)
              .background(Color(red: foobar, green: foobar, blue: foobar2))
              .opacity(1.0)
              .disabled(viewModel.videoPlaying)
              .help("""
                      Show each frame as either the original   
                      or with star processing applied.
                      """) // XXX does this work anymore?
              .cornerRadius(5)

            Spacer()
              .frame(maxHeight: 10)

            ExpandUpButton($viewModel.showAllFrameViewModes)
              .cursor(.resizeUp)
        }
    }
    
    var displaySection: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            RightPanelSectionHeader(title: localized("ui.display"),
                                    help: localized("ui.section.display_help"),
                                    isExpanded: $displayExpanded)

            if displayExpanded {
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
                Group {
                    Text(localized("ui.frame_rate"))
                      .foregroundColor(.white)
                    Picker("", selection: $viewModel.videoPlaybackFramerate) {
                        ForEach(Self.playbackFrameRates, id: \.self) {
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


    var closedView: some View {
        VStack(alignment: .leading) {
            // hidden with arrow to allow showing it
            Button() {
                viewModel.leftPanelShowing = true 
            } label: {
                Image(systemName: "chevron.right.2")
                  .foregroundColor(.gray)
            }
              .buttonStyle(PlainButtonStyle())
              .cursor(.resizeRight)
        }
          .padding(10)
          .background(Color(white: 0.22))
          .frame(maxHeight: .infinity, alignment: .bottomTrailing)
        
    }
}

extension View {                // XXX move this
    @ViewBuilder func `if`<Content: View>(
        _ condition: Bool,
        transform: (Self) -> Content
    ) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}

/// Not drawn: the progress bar it replaced is redundant with the processing modal, but the
/// Gherkin UI tests still wait on this element's label.
struct ProcessingProgressMarker: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Color.clear
          .frame(width: 0, height: 0)
          // What the Gherkin UI tests wait on: "<complete>/<total>/<running|idle>" in the label (the value comes through empty for an ignored-children element).
          .accessibilityElement(children: .ignore)
          .accessibilityIdentifier("processing.progress")
          .accessibilityLabel("\(viewModel.frameStateMap[.complete]?.count ?? 0)/\(viewModel.frames.count)/\(viewModel.isProcessingFrames ? "running" : "idle")")
    }
}
