import SwiftUI
import StarCore

enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
}

enum FrameViewMode: String, Equatable, CaseIterable {
    case original
    case processed

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

enum SelectionMode: String, Equatable, CaseIterable {
    case paint
    case clear
    case details
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

enum InteractionMode: String, Equatable, CaseIterable {
    case edit
    case scrub

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}



// the main view of an image sequence 
// user can scrub, play, edit frames, etc

struct ImageSequenceView: View {
    @ObservedObject var viewModel: ViewModel

    var body: some View {
        GeometryReader { top_geometry in
            ScrollViewReader { scroller in
                VStack {
                    let should_show_progress =
                      viewModel.rendering_current_frame            ||
                      viewModel.updating_frame_batch               ||
                      viewModel.rendering_all_frames

                    // selected frame 
                    ZStack {
                        FrameView(viewModel: viewModel,
                                  interactionMode: self.$viewModel.interactionMode,
                                  showFullResolution: self.$viewModel.showFullResolution)
                          .frame(maxWidth: .infinity, alignment: .center)
                          .overlay(
                            ProgressView() // XXX this overlay sucks, change it
                              .scaleEffect(8, anchor: .center) // this is blocky scaled up 
                              .progressViewStyle(CircularProgressViewStyle(tint: .yellow))
                              .frame(maxWidth: 200, maxHeight: 200)
                              .opacity(should_show_progress ? 0.8 : 0)
                          )

                        // show progress bars on top of the image at the bottom
                        ProgressBars(viewModel: viewModel)
                    }
                    // buttons below the selected frame 
                    bottomControls(withScroll: scroller)
                    
                    if viewModel.interactionMode == .edit,
                       viewModel.showFilmstrip
                    {
                        Spacer().frame(maxHeight: 30)
                        // the filmstrip at the bottom
                        FilmstripView(viewModel: viewModel,
                                      imageSequenceView: self,
                                      scroller: scroller)
                          .frame(maxWidth: .infinity)
                          .transition(.slide)
                        Spacer().frame(minHeight: 15, maxHeight: 25)
                    }

                    // scub slider at the bottom
                    if viewModel.image_sequence_size > 0 {
                        ScrubSliderView(viewModel: viewModel,
                                      scroller: scroller)
                    }
                }
            }
              .frame(maxWidth: .infinity, maxHeight: .infinity)
              .padding([.bottom, .leading, .trailing])
              .background(viewModel.background_color)
        }

          .alert(isPresented: $viewModel.showErrorAlert) {
              Alert(title: Text("Error"),
                    message: Text(viewModel.errorMessage),
                    primaryButton: .default(Text("Ok")) { viewModel.sequenceLoaded = false },
                    secondaryButton: .default(Text("Sure")) { viewModel.sequenceLoaded = false } )
              
          }
    }


    // controls below the selected frame and above the filmstrip
    // XXX this is a mess, clean it up
    func bottomControls(withScroll scroller: ScrollViewProxy) -> some View {
        HStack {
            ZStack {
                VideoPlaybackButtons(viewModel: viewModel,
                                     scroller: scroller)
                  .frame(maxWidth: .infinity, alignment: .center)

                HStack {
                    VStack {
                        ZStack {
                            Button("") {
                                self.viewModel.interactionMode = .edit
                            }
                              .opacity(0)
                              .keyboardShortcut("e", modifiers: [])

                            Button("") {
                                self.viewModel.interactionMode = .scrub
                            }
                              .opacity(0)
                              .keyboardShortcut("s", modifiers: [])
                            
                        Picker("I will", selection: $viewModel.interactionMode) {
                            ForEach(InteractionMode.allCases, id: \.self) { value in
                                Text(value.localizedName).tag(value)
                            }
                        }
                          .help("""
                                  Choose between quickly scrubbing around the video
                                  and editing an individual frame.
                                """)
                          .disabled(viewModel.video_playing)
                          .onChange(of: viewModel.interactionMode) { mode in
                              Log.d("interactionMode change \(mode)")
                              switch mode {
                              case .edit:
                                  viewModel.refreshCurrentFrame()
                                  
                              case .scrub:
                                  break
                              }
                          }
                          .frame(maxWidth: 220)
                          .pickerStyle(.segmented)
                        }
                        Picker("I will see", selection: $viewModel.frameViewMode) {
                            ForEach(FrameViewMode.allCases, id: \.self) { value in
                                Text(value.localizedName).tag(value)
                            }
                        }
                          .disabled(viewModel.video_playing)
                          .help("""
                                  Show each frame as either the original   
                                  or with star processing applied.
                                """)
                          .frame(maxWidth: 220)
                          .help("show original or processed frame")
                          .onChange(of: viewModel.frameViewMode) { pick in
                              Log.d("pick \(pick)")
                              viewModel.refreshCurrentFrame()
                          }
                          .pickerStyle(.segmented)
                    }
                    
                    // outlier opacity slider
                    if self.viewModel.interactionMode == .edit {
                        VStack {
                            Text("Outlier Group Opacity")
                            
                            Slider(value: $viewModel.outlierOpacitySliderValue, in : 0...1) { _ in
                                viewModel.update()
                            }
                              .frame(maxWidth: 140, alignment: .bottom)
                        }
                    }
                }
                  .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.interactionMode == .edit {
                    HStack {
                        let frameView = viewModel.currentFrameView
                        VStack {
                            let num_changed = viewModel.numberOfFramesChanged
                            if num_changed > 0 {
                                Text("\(num_changed) frames changed")
                                  .foregroundColor(.yellow)
                            }
                            let num_saving = viewModel.frameSaveQueue?.saving.count ?? -1
                            if num_saving > 0 {
                                Text("saving \(num_saving) frames")
                                  .foregroundColor(.green)
                            }
                        }
                          .frame(alignment: .trailing)
                        VStack {
                            Text("frame \(viewModel.current_index)")
                            if let _ = frameView.outlierViews {
                                if let num_positive = frameView.numberOfPositiveOutliers {
                                    Text("\(num_positive) will paint")
                                      .foregroundColor(num_positive == 0 ? .white : .red)
                                }
                                if let num_negative = frameView.numberOfNegativeOutliers {
                                    Text("\(num_negative) will not paint")
                                      .foregroundColor(num_negative == 0 ? .white : .green)
                                }
                                if let num_undecided = frameView.numberOfUndecidedOutliers,
                                   num_undecided > 0
                                {
                                    Text("\(num_undecided) undecided")
                                      .foregroundColor(.orange)
                                }
                            }
                        }.frame(alignment: .trailing)
                          .id(frameView.numberOfPositiveOutliers)
                          .id(frameView.numberOfNegativeOutliers)
                          //.id(frameView.outlierViews)

                        let paint_action = {
                            Log.d("PAINT")
                            viewModel.paint_sheet_showing = !viewModel.paint_sheet_showing
                        }
                        Button(action: paint_action) {
                            buttonImage("square.stack.3d.forward.dottedline", size: 44)
                            
                        }
                          .buttonStyle(PlainButtonStyle())           
                          .frame(alignment: .trailing)
                          .help("effect multiple frames")
                        
                        let gear_action = {
                            Log.d("GEAR")
                            viewModel.settings_sheet_showing = !viewModel.settings_sheet_showing
                        }
                        Button(action: gear_action) {
                            buttonImage("gearshape.fill", size: 44)
                            
                        }
                          .buttonStyle(PlainButtonStyle())           
                          .frame(alignment: .trailing)
                          .help("settings")
                        
                        toggleViews()
                    }
                      .frame(maxWidth: .infinity, alignment: .trailing)
                      .sheet(isPresented: $viewModel.settings_sheet_showing) {
                          SettingsSheetView(isVisible: self.$viewModel.settings_sheet_showing,
                                            fast_skip_amount: $viewModel.fast_skip_amount,
                                            video_playback_framerate: self.$viewModel.video_playback_framerate,
                                            fastAdvancementType: $viewModel.fastAdvancementType)
                      }
                      .sheet(isPresented: $viewModel.paint_sheet_showing) {
                          MassivePaintSheetView(isVisible: self.$viewModel.paint_sheet_showing,
                                                viewModel: viewModel)
                          { should_paint, start_index, end_index in
                              
                              viewModel.updating_frame_batch = true
                              
                              for idx in start_index ... end_index {
                                  // XXX use a task group?
                                  viewModel.setAllFrameOutliers(in: viewModel.frames[idx], to: should_paint)
                              }
                              viewModel.updating_frame_batch = false
                              
                              Log.d("should_paint \(should_paint), start_index \(start_index), end_index \(end_index)")
                          }
                      }
                }
            }
        }
    }


    func renderAllFramesButton() -> some View {
        let action: () -> Void = {
            Task {
                await withLimitedTaskGroup(of: Void.self) { taskGroup in
                    var number_to_save = 0
                    self.viewModel.rendering_all_frames = true
                    for frameView in viewModel.frames {
                        if let frame = frameView.frame,
                           let frameSaveQueue = viewModel.frameSaveQueue
                        {
                            await taskGroup.addTask() {
                                number_to_save += 1
                                frameSaveQueue.saveNow(frame: frame) {
                                    await viewModel.refresh(frame: frame)
                                    /*
                                     if frame.frame_index == viewModel.current_index {
                                     refreshCurrentFrame()
                                     }
                                     */
                                    number_to_save -= 1
                                    if number_to_save == 0 {
                                        self.viewModel.rendering_all_frames = false
                                    }
                                }
                            }
                        }
                    }
                    await taskGroup.waitForAll()
                }
            }
        }
        
        return Button(action: action) {
            Text("Render All Frames")
        }
          .help("Render all frames of this sequence with current settings")
    }


    func renderCurrentFrame(_ closure: (() -> Void)? = nil) async {
        if let frame = viewModel.currentFrame {
            await viewModel.render(frame: frame, closure: closure)
        }
    }
    
    func renderCurrentFrameButton() -> some View {
        let action: () -> Void = {
            Task { await self.renderCurrentFrame() }
        }
        
        return Button(action: action) {
            Text("Render This Frame")
        }
          .help("Render the active frame with current settings")
    }
    
    func applyDecisionTreeButton() -> some View {
        let action: () -> Void = {
            Task {
                do {
                    if let frame = viewModel.currentFrame {
                        await frame.applyDecisionTreeToAutoSelectedOutliers()
                        await viewModel.render(frame: frame) {
                            Task {
                                await viewModel.refresh(frame: frame)
                                if frame.frame_index == viewModel.current_index {
                                    viewModel.refreshCurrentFrame() // XXX not always still current
                                }
                                await viewModel.setOutlierGroups(forFrame: frame)
                                viewModel.update()
                            }
                        }
                    }
                }
            }
        }
        return Button(action: action) {
            Text("DT Auto Only")
        }
          .help("apply the outlier group decision tree to all selected outlier groups in this frame")
    }

    func applyAllDecisionTreeButton() -> some View {
        Log.d("applyAllDecisionTreeButton")
        let action: () -> Void = {
            Log.d("applyAllDecisionTreeButton action")
            Task {
                Log.d("doh")
                do {
                    //Log.d("doh index \(viewModel.current_index) frame \(viewModel.frames[0].frame) have_all_frames \(viewModel.have_all_frames)")
                    if let frame = viewModel.currentFrame {
                        Log.d("doh")
                        await frame.applyDecisionTreeToAllOutliers()
                        Log.d("doh")
                        await viewModel.render(frame: frame) {
                            Log.d("doh")
                            Task {
                                await viewModel.refresh(frame: frame)
                                if frame.frame_index == viewModel.current_index {
                                    viewModel.refreshCurrentFrame() // XXX not always still current
                                }
                                await viewModel.setOutlierGroups(forFrame: frame)
                                viewModel.update()
                            }
                        }
                    } else {
                        Log.w("FUCK")
                    }
                }
            }
        }
        let shortcutKey: KeyEquivalent = "d"
        return Button(action: action) {
            Text("Decision Tree All")
        }
          .keyboardShortcut(shortcutKey, modifiers: [])
          .help("apply the outlier group decision tree to all outlier groups in this frame")
    }

    func toggleViews() -> some View {
        HStack() {
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
                 .frame(maxWidth: 280)
                 .pickerStyle(.segmented)

                HStack {
                    Toggle("full resolution", isOn: $viewModel.showFullResolution)
                      .onChange(of: viewModel.showFullResolution) { mode_on in
                          viewModel.refreshCurrentFrame()
                      }
                    Toggle("show filmstip", isOn: $viewModel.showFilmstrip)
                }
            }
        }
    }
}
