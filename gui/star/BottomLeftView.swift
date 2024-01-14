import SwiftUI
import StarCore
import logging

// controls on the bottom left of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomLeftView: View {
    @EnvironmentObject var viewModel: ViewModel

    let pickerWidth: CGFloat = 160
    
    var body: some View {
        HStack {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("I will")
                      .gridColumnAlignment(.trailing) 
                    ZStack {
                        Button("") {
                            self.viewModel.interactionMode = .edit
                        }
                          .opacity(0)
                          .keyboardShortcut("e", modifiers: [])
                        
                        Button("") {
                            self.viewModel.interactionMode = .play
                        }
                          .opacity(0)
                          .keyboardShortcut("s", modifiers: [])

                        Picker("", selection: $viewModel.interactionMode) {
                            ForEach(InteractionMode.allCases, id: \.self) { value in
                                Text(value.localizedName).tag(value)
                            }
                        }
                          .help("""
                                  Choose between quickly scrubbing around the video
                                  and editing an individual frame.
                                  """)
                          .disabled(viewModel.videoPlaying)
                          .onChange(of: viewModel.interactionMode) { mode in
                              Log.d("interactionMode change \(mode)")
                              switch mode {
                              case .edit:
                                  viewModel.refreshCurrentFrame()
                                  
                              case .play:
                                  break
                              }
                          }
                          .frame(width: pickerWidth)
                          .pickerStyle(.segmented)
                    }
                    Spacer().frame(maxWidth: 6, maxHeight: 10)
                    Text("this video")
                      .gridColumnAlignment(.leading) 
                }
                GridRow {
                    Text("I will see")
                      .gridColumnAlignment(.trailing) 
                    
                    Picker("", selection: $viewModel.frameViewMode) {
                        ForEach(FrameViewMode.allCases, id: \.self) { value in
                            Text(value.shortName)
                              .help(value.localizedName)
                              .font(.system(size: 8))
                              .tag(value)
                        }
                    }
                      .disabled(viewModel.videoPlaying)
                      .help("""
                              Show each frame as either the original   
                              or with star processing applied.
                              """)
                      .frame(width: 450)
                      .help("show original or processed frame")
                      .onChange(of: viewModel.frameViewMode) { pick in
                          Log.d("pick \(pick)")
                          viewModel.refreshCurrentFrame()
                      }
                      .pickerStyle(.segmented)
                    Spacer().frame(maxWidth: 6, maxHeight: 10)
                    Text("frames")
                      .gridColumnAlignment(.leading) 
                }
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
    }
}
