import SwiftUI
import StarCore
import logging

// controls on the bottom left of the screen,
// below the image frame and above the filmstrip and scrub bar

struct BottomLeftView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    let pickerWidth: CGFloat = 160

    /// The view picker's labels, from the catalogue (the desktop client's pickers read the same two keys).
    static func viewLabel(_ mode: FrameViewMode) -> String {
        localized(mode == .final ? "ui.view_processed" : "ui.view_original")
    }
    
    var body: some View {
        @Bindable var viewModel = viewModel

        return HStack {
            if viewModel.videoPlaying {
                Group { }
            } else {
                let foobar = 134.0/255.0 // XXX make a custom color from these
                let foobar2 = 138.0/255.0
                
                HStack {
                    StarPicker(selection: $viewModel.interactionMode, identifier: { mode in
                        switch mode {
                        case .edit: return "mode.edit"
                        case .scrub: return "mode.scrub"
                        case .grid: return "mode.grid"
                        }
                    }) { value, isEnabled in
                        Text(value.localizedName)
                          .foregroundColor(isEnabled ? .black : .yellow)
                        //                                  .onTapGesture { _ in
                        //                                      viewModel.frameViewMode = value
                        //                                  }
                    }
                    //.frame(width: pickerWidth)
                    //                              .background(Color(red: foobar, green: foobar, blue: foobar2))
                    //                              .cornerRadius(5)
                      .disabled(viewModel.videoPlaying)
                      .help(localized("ui.interaction_mode_help"))
                    Spacer().frame(maxWidth: 6, maxHeight: 10)
                    Text(localized("ui.with"))
                      .foregroundColor(.white)
                    
                    LimitedSelectionPicker(selection: $viewModel.frameViewMode) { value, isEnabled in
                        if value == .original || value == .final {
                            let name = value == .final ? "view.final" : "view.original"
                            if viewModel.currentFrameView.hasImage(type: value) {
                                Text(Self.viewLabel(value))
                                  .foregroundColor(isEnabled ? .black : .yellow)
                                  .padding(4)
                                  .onTapGesture { _ in
                                      viewModel.frameViewMode = value
                                  }
                                  .optionIdentity(name, selected: viewModel.frameViewMode == value)
                            } else {
                                Text(Self.viewLabel(value))
                                  .foregroundColor(/*isEnabled ? .white : */ .gray)
                                  .padding(4)
                                  .optionIdentity(name, selected: viewModel.frameViewMode == value)
                            }
                        } else {
                            Group { }
                        }
                    }
                    .background(Color(red: foobar, green: foobar, blue: foobar2))
                    .cornerRadius(5)

                    Text(localized("ui.frames"))
                      .foregroundColor(.white)
                    
                }
            }                
        }
    }
}

