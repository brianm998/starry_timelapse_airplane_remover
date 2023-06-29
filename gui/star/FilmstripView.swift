import SwiftUI
import StarCore

// the filmstrip at the bottom

struct FilmstripView: View {
    @EnvironmentObject var viewModel: ViewModel
    let imageSequenceView: ImageSequenceView
    let scroller: ScrollViewProxy

    var body: some View {
        HStack {
            if viewModel.imageSequenceSize == 0 {
                Text("Loading Film Strip")
                  .font(.largeTitle)
                  .frame(minHeight: 50)
                  //.transition(.moveAndFade)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<viewModel.imageSequenceSize, id: \.self) { frame_index in
                            FilmstripImageView(frame_index: frame_index,
                                            scroller: scroller)
                              .help("show frame \(frame_index)")
                        }
                    }
                }
                  .frame(minHeight: CGFloat((viewModel.config?.thumbnail_height ?? 50) + 30))
                  //.transition(.moveAndFade)
            }
        }
          .frame(maxWidth: .infinity, maxHeight: 50)
          .background(viewModel.imageSequenceSize == 0 ? .yellow : .clear)
    }
}

