import SwiftUI
import StarCore

// the filmstrip at the bottom

struct FilmstripView: View {
    @ObservedObject var viewModel: ViewModel
    let imageSequenceView: ImageSequenceView
    let scroller: ScrollViewProxy

    public init(viewModel: ViewModel,
                imageSequenceView: ImageSequenceView,
                scroller: ScrollViewProxy)
    {
        self.viewModel = viewModel
        self.imageSequenceView = imageSequenceView
        self.scroller = scroller
    }
    
    var body: some View {
        HStack {
            if viewModel.image_sequence_size == 0 {
                Text("Loading Film Strip")
                  .font(.largeTitle)
                  .frame(minHeight: 50)
                  //.transition(.moveAndFade)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(spacing: 0) {
                        ForEach(0..<viewModel.image_sequence_size, id: \.self) { frame_index in
                            FilmstripImageView(viewModel: viewModel,
                                               imageSequenceView: imageSequenceView,
                                               frame_index: frame_index,
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
          .background(viewModel.image_sequence_size == 0 ? .yellow : .clear)
    }
}

