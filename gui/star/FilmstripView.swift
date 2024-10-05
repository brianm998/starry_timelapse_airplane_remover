import SwiftUI
import StarCore

// the filmstrip at the bottom

struct FilmstripView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    let imageSequenceView: ImageSequenceView

    var body: some View {
        HStack {
            ScrollViewReader { scroller in
                if viewModel.imageSequenceSize == 0 {
                    Text("Loading Film Strip")
                      .font(.largeTitle)
                      .frame(minHeight: 50)
                } else {
                    ScrollView(.horizontal) {
                        LazyHStack(spacing: 0) {
                            ForEach(0..<viewModel.imageSequenceSize, id: \.self) { frameIndex in
                                FilmstripImageView(frameIndex: frameIndex)
                                  .help("show frame \(frameIndex)")
                            }
                        }
                    }
                      .defaultScrollAnchor(.center)
                      .onChange(of: viewModel.currentIndex, initial: true) {
                          scroller.scrollTo(viewModel.currentIndex)
                      }
                      .frame(minHeight: CGFloat((viewModel.config?.thumbnailHeight ?? 50) + 30))
                }
            }
        }
          .frame(maxWidth: .infinity, maxHeight: 50)
          .background(viewModel.imageSequenceSize == 0 ? .yellow : .clear)
    }
}

