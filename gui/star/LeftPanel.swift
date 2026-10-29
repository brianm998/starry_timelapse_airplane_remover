import SwiftUI
import StarCore
import logging

/// What the left panel's top button offers.
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

                    self.processingButtons

                    ProcessingProgressBarView()
                      .frame(maxWidth: 200, alignment: .leading)
                     //.frame(maxWidth: .none)
                    
                    Space(height: 10)

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

    /// The processing modal's Dismiss button hands the window back with the run still
    /// going, and there was no way back to it — dismissing it was a one-way door.  While a
    /// run is live this button is that way back, which is also the only thing it could
    /// usefully be: starting a second run over the same frames is exactly what it must not
    /// do.
    var processingButtonRole: ProcessingButtonRole {
        ProcessingButtonRole.current(
          isProcessingFrames: viewModel.isProcessingFrames,
          isRenderingVideo: viewModel.isRenderingVideo,
          unprocessedCount: viewModel.frameStateMap[.unprocessed]?.count ?? 0,
          horizonDetectedCount: viewModel.frameStateMap[.horizonDetected]?.count ?? 0,
          frameCount: viewModel.frames.count,
          pendingHorizonRefinement: viewModel.hasPendingHorizonRefinement
        )
    }

    var processButtonDisabled: Bool {
        if case .process(let enabled) = processingButtonRole { return !enabled }
        return false
    }

    var updateButtonDisabled: Bool {
        let userModified = viewModel.frameStateMap[.userModified]?.count ?? 0
        return userModified == 0 || viewModel.isProcessingFrames || viewModel.isRenderingVideo 
    }

    var renderButtonDisabled: Bool {
        let complete = viewModel.frameStateMap[.complete]?.count ?? 0
        return complete != viewModel.frames.count || viewModel.isProcessingFrames || viewModel.isRenderingVideo
    }
    
    var processingButtons: some View {
        VStack(alignment: .leading) {
            let unprocessed = viewModel.frameStateMap[.unprocessed]?.count ?? 0
            let horizonCount = viewModel.frameStateMap[.horizonDetected]?.count ?? 0

            let role = processingButtonRole

            Button() {
                switch role {
                case .status:  viewModel.processingModalShowing = true
                case .process: viewModel.shouldShowProcessingSettings = true
                }
            } label: {
                Text(role == .status
                       ? localized("ui.show_progress")
                       : localized("ui.process_frames"))
            }
              .disabled(processButtonDisabled)
              .if(!processButtonDisabled) {
                  $0.buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
              .help(role == .status
                      ? localized("ui.show_the_processing_status_again")
                      : localized("ui.choose_settings_and_process_these_frames"))
            
            
            let userModified = viewModel.frameStateMap[.userModified]?.count ?? 0
            /*
            Button() {
                // XXX this has no max number of processes :(
                Task {
                  await viewModel.processAll()
                }
            } label: {
                Text(localized("ui.update_n_frames", userModified))
            }
              .disabled(updateButtonDisabled)
              .if(!updateButtonDisabled) { view in
                  view
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
*/
            let complete = viewModel.frameStateMap[.complete]?.count ?? 0

            Button() {
                Log.d("render video")
                viewModel.renderVideoSheetShowing = true
                /*

                 need to keep track of ffmpeg parameters when we load a video
                 (get rid of script to render)

                 default ffmpeg parameters to prores high quailty in config

                 have ui that allows users to change codec and frame rate, etc.

                 show render progress in UI somehow
                 
                 */

                viewModel.isRenderingVideo = false
                
            } label: {
                Text(localized("ui.render_video_from_n_frames_lower", viewModel.frames.count))
            }
              .disabled(renderButtonDisabled)
              .if(!renderButtonDisabled) { view in
                  view
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
              }
        }
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

struct ProcessingProgressBarView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    let unprocessedColor: Color = .gray
    let processingColor: Color = .yellow
    let completeColor: Color = .green

    var body: some View {
        return GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let totalFrames = max(1, viewModel.frames.count)
            
            let unprocessed = CGFloat(viewModel.frameStateMap[.unprocessed]?.count ?? 0)
            let processing = CGFloat(viewModel.numberOfFramesProcessingNow)
            let complete = CGFloat(viewModel.frameStateMap[.complete]?.count ?? 0)

            
            let unprocessedWidth = totalWidth * (unprocessed / CGFloat(totalFrames))
            let processingWidth = totalWidth * (processing / CGFloat(totalFrames))
            let completeWidth = totalWidth * (complete / CGFloat(totalFrames))

            HStack(spacing: 0) {
                Rectangle()
                    .fill(completeColor)
                    .frame(width: completeWidth)

                Rectangle()
                    .fill(processingColor)
                    .frame(width: processingWidth)

                Rectangle()
                    .fill(unprocessedColor)
                    .frame(width: unprocessedWidth)

            }
            .cornerRadius(4)
            .frame(height: 10)
        }
        .frame(height: 10)
          // What the Gherkin UI tests wait on: "<complete>/<total>/<running|idle>" in the label (the value comes through empty for an ignored-children element).
          .accessibilityElement(children: .ignore)
          .accessibilityIdentifier("processing.progress")
          .accessibilityLabel("\(viewModel.frameStateMap[.complete]?.count ?? 0)/\(viewModel.frames.count)/\(viewModel.isProcessingFrames ? "running" : "idle")")
    }
}

