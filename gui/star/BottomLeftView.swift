import SwiftUI
import StarCore
import logging

// controls on the bottom left of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomLeftView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    let pickerWidth: CGFloat = 160
    
    var body: some View {
        @Bindable var viewModel = viewModel

        return HStack {
            if viewModel.videoPlaying {
                Group { }
            } else {
                let foobar = 134.0/255.0 // XXX make a custom color from these
                let foobar2 = 138.0/255.0
                        
                
                Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                    GridRow {
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
                    GridRow {
                        Text("I will see")
                          .foregroundColor(.white)
                          .gridColumnAlignment(.trailing) 

                        //ViewModePicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                        LimitedSelectionPicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                            if viewModel.currentFrameView.hasImage(type: value) {
                                Text(value.shortName)
                                  .foregroundColor(isEnabled ? .black : .gray)
                                  .padding(4)
                                  .onTapGesture { _ in
                                      viewModel.frameViewMode = value
                                  }
                            } else {
                                Text(value.shortName)
                                  .foregroundColor(/*isEnabled ? .white : */ .gray)
                                  .padding(4)
                            }
                        }
                          .background(Color(red: foobar, green: foobar, blue: foobar2))
                          .opacity(1.0)
                        //                      .background(.red)
                          .disabled(viewModel.videoPlaying)
                          .help("""
                                  Show each frame as either the original   
                                  or with star processing applied.
                                  """)
                          .cornerRadius(5)
                        
                        Spacer().frame(maxWidth: 6, maxHeight: 10)
                        Text("frames")
                          .foregroundColor(.white)
                          .gridColumnAlignment(.leading)
                    }
                }
                
                // outlier opacity slider
                if self.viewModel.interactionMode == .edit {
                    VStack {
                        Text("Outlier Group Opacity")
                          .foregroundColor(.white)
                        
                        Slider(value: $viewModel.outlierOpacity, in : 0...1)
                          .frame(maxWidth: 140, alignment: .bottom)
                          .background(.gray)
                    }
                }
            }
        }
    }
}

