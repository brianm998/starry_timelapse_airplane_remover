import SwiftUI
import StarCore

// controls on the bottom left of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomLeftView: View {
    @EnvironmentObject var viewModel: ViewModel

    var body: some View {
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
                      .disabled(viewModel.videoPlaying)
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
                  .disabled(viewModel.videoPlaying)
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
    }
}
