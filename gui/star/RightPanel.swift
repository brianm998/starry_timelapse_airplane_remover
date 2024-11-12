import SwiftUI
import StarCore

public enum FastAdvancementType: String, Equatable, CaseIterable {
    case normal
    case skipEmpties
    case toNextPositive
    case toNextNegative
    case toNextUnknown
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

struct RightPanel: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

    let foobar = 134.0/255.0 // XXX make a custom color from these
    let foobar2 = 138.0/255.0

    var body: some View {
        @Bindable var viewModel = viewModel
        return Group {
            if viewModel.rightPanelShowing {
                VStack(alignment: .leading) {
                    ScrollView {
                        VStack(alignment: .leading) {

                            Text("Fast Advancement Type")
                              .foregroundColor(.white)

                            Picker("", selection: $viewModel.fastAdvancementType) {
                                ForEach(FastAdvancementType.allCases, id: \.self) { value in
                                    Text(value.localizedName).tag(value)
                                }
                            }
                              .help("""
                                      How the fast forward and fast reverse buttons work:

                                      normal         - move by some fixed number of frames
                                      skipEmpties    - skip all frames without any outliers
                                      toNextPositive - skip to the next frame with positive outliers
                                      toNextNegative - skip to the next frame with negative outliers
                                      toNextUnknown  - skip to the next frame with unknown outliers
                                      """)
                              .frame(maxWidth: 140)

                            switch viewModel.fastAdvancementType {
                            case .normal:
                                Text("Fast Forward and Reverse move by \(viewModel.fastSkipAmount) frames")
                                  .frame(maxWidth: 140)
                                  .multilineTextAlignment(.leading)
                                  .foregroundColor(.white)
                            case .skipEmpties:
                                Text("Skip all frames without outliers")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextPositive:
                                Text("Skip to next frame with a positive outlier")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextNegative:
                                Text("Skip to next frame with a negative outlier")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            case .toNextUnknown:
                                Text("Skip to next frame with a unknown outlier")
                                  .frame(maxWidth: 140)
                                  .foregroundColor(.white)
                            }

//                    Toggle(skipEmpties ? "change to # of frames" : "change to skip empties",
//                           isOn: $skipEmpties)

                    // XXX add advance to has undecided
                    // XXX add advance to has paintable
                    // XXX add advance to has not paintable
                    
                            if viewModel.fastAdvancementType == .normal {
                                Text("Fast Skip")
                                  .foregroundColor(.white)
                                Picker("", selection: $viewModel.fastSkipAmount) {
                                    ForEach(0 ..< 51) {
                                        Text("\($0) frames")
                                    }
                                }.frame(maxWidth: 140)
                            }

                            VerticalStarPicker("selection mode", selection: $viewModel.selectionMode) { value, _ in
                                Text(value.localizedName).tag(value)
                            }
                              .help("""
                                      What happens when outlier groups are selected?
                                      paint   - they will be marked for painting
                                      clear   - they will be marked for not painting
                                      details - they will be shown in the info window
                                      """)      // XXX does this work here?

                            Toggle("multi choice", isOn: $viewModel.multiChoice)
                              .foregroundColor(.white)

                            // frame rate checkoer
                            let frame_rates = [1, 2, 3, 5, 10, 15, 20, 25, 30]
                            Text("Frame Rate")
                              .foregroundColor(.white)
                            Picker("", selection: $viewModel.videoPlaybackFramerate) {
                                ForEach(frame_rates, id: \.self) {
                                    Text("\($0) fps")
                                }
                            }.frame(maxWidth: 100)

                            
                            // outlier opacity slider
                            Text("Outlier Group Opacity")
                              .foregroundColor(.white)
                            
                            Slider(value: $viewModel.outlierOpacity, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)
                            
                            Text("Frame Opacity")
                              .foregroundColor(.white)
                            
                            Slider(value: $viewModel.frameOpacity, in : 0...1)
                              .frame(maxWidth: 140, alignment: .bottom)

                            Toggle("full resolution", isOn: $viewModel.showFullResolution)
                              .foregroundColor(.white)
                        }
                    }
                      .defaultScrollAnchor(.bottom)
                    Button() {
                        viewModel.rightPanelShowing = false
                    } label: {
                        Image(systemName: "chevron.right.2")
                          .foregroundColor(.black)
                    }
                      .buttonStyle(PlainButtonStyle())
                }
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
              }
                .frame(maxHeight: .infinity, alignment: .bottomLeading)
            }
        }
    }
}
