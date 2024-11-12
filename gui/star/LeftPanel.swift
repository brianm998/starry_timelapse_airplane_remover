import SwiftUI
import StarCore

struct LeftPanel: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    var body: some View {
        @Bindable var viewModel = viewModel
        return Group {
            if viewModel.leftPanelShowing {
                VStack(alignment: .trailing) {
                    ScrollView() {
                        VStack(alignment: .leading) {
                            Text("Show:")
                              .foregroundColor(.white)

                            VerticalLimitedSelectionPicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                                let shouldShow = (!viewModel.showAllFrameViewModes && (value == .original || value == .processed)) || viewModel.showAllFrameViewModes
                                if shouldShow {
                                    if viewModel.currentFrameView.hasImage(type: value) {
                                        Text(value.longName)
                                          .foregroundColor(isEnabled ? .black : .gray)
                                          .padding(4)
                                          .onTapGesture { _ in
                                              viewModel.frameViewMode = value
                                          }
                                    } else {
                                        Text(value.longName)
                                          .foregroundColor(/*isEnabled ? .white : */ .gray)
                                          .padding(4)
                                    }
                                } else {
                                    Group { }
                                }
                            }
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

                            Toggle("See All View Modes", isOn: $viewModel.showAllFrameViewModes)
                              .foregroundColor(.white)
                        }
//                          .frame(maxWidth: 200)
                    }
                      .defaultScrollAnchor(.bottom)
                      .frame(maxHeight: .infinity, alignment: .bottom)

                    Spacer()
                    
                    Button() {
                        viewModel.leftPanelShowing = false
                    } label: {
                        Image(systemName: "chevron.left.2")
                          .foregroundColor(.gray)
                    }
                      .buttonStyle(PlainButtonStyle())
                }
                  .padding(10)
                  .background(Color(white: 0.22))
                  .frame(maxHeight: .infinity, alignment: .bottom)
            } else {
                VStack(alignment: .leading) {
                    // hidden with arrow to allow showing it
                    Button() {
                        viewModel.leftPanelShowing = true 
                    } label: {
                        Image(systemName: "chevron.right.2")
                          .foregroundColor(.gray)
                    }
                      .buttonStyle(PlainButtonStyle())
                }
                  .padding(10)
                  .background(Color(white: 0.22))
                  .frame(maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
    }
}
