import SwiftUI
import StarCore
import logging

// controls on the bottom left of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomLeftView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let pickerWidth: CGFloat = 160
    
    var body: some View {
        @Bindable var viewModel = viewModel

        return HStack {
            if viewModel.videoPlaying {
                Group { }
            } else {
                let foobar = 134.0/255.0 // XXX make a custom color from these
                let foobar2 = 138.0/255.0
                
                HStack {
                    Text("I will")
                      .gridColumnAlignment(.trailing) 
                      .foregroundColor(.white)
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

                        StarPicker(selection: $viewModel.interactionMode) { value, isEnabled in
                            Text(value.rawValue)
                              .foregroundColor(isEnabled ? .black : .gray)
                            //                                  .onTapGesture { _ in
                            //                                      viewModel.frameViewMode = value
                            //                                  }
                        }
                        //.frame(width: pickerWidth)
                        //                              .background(Color(red: foobar, green: foobar, blue: foobar2))
                        //                              .cornerRadius(5)
                          .disabled(viewModel.videoPlaying)
                          .help("""
                                  Choose between quickly scrubbing around the video
                                  and editing an individual frame.
                                  """)
                    }
                    Spacer().frame(maxWidth: 6, maxHeight: 10)
                    Text("this video")
                      .foregroundColor(.white)
                      .gridColumnAlignment(.leading) 
                }
            }                
        }
    }
}

