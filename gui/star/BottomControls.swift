import SwiftUI
import StarCore

// controls below the selected frame and above the filmstrip
// XXX this is a mess, clean it up
struct BottomControls: View {
    @EnvironmentObject var viewModel: ViewModel
    let scroller: ScrollViewProxy
    
    var body: some View {
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
