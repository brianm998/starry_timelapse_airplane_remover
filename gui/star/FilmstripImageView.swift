import SwiftUI
import StarCore

// the view for each frame in the filmstrip at the bottom
struct FilmstripImageView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    let frameIndex: Int

    var body: some View {
            VStack(alignment: .center) {
                let frameView = viewModel.frames[frameIndex]
                Spacer().frame(maxHeight: 8)
                HStack {
                    Spacer().frame(maxWidth: 10)
                      .frame(alignment: .leading)
                    Text("\(frameIndex)").foregroundColor(.white)
                      .frame(alignment: .leading)
                    Spacer()
                    switch frameView.outliersLoaded {
                    case .unloaded:
                        // show nothing when unloaded
                        Group { }

                    case .loading:
                        Image(systemName: "line.diagonal")
                          .foregroundColor(.yellow)
                          .animation(Animation.easeInOut(duration:1)
                                       .repeatForever(autoreverses:true))
                    case .loaded:
                        Image(systemName: "line.diagonal")
                          .foregroundColor(.green)
                    }

                    Spacer()
                      .frame(maxWidth: 6)
                      .frame(alignment: .trailing)

                }
                  .frame(maxHeight: 10)
                
                if frameIndex >= 0 && frameIndex < viewModel.frames.count {
                    ZStack(alignment: .bottomTrailing) {
                        if viewModel.currentIndex == frameIndex {
                            frameView.thumbnailImage
                              .foregroundColor(.orange)
                        } else {
                            frameView.thumbnailImage
                        }
                        if let frameState = frameView.frameState {
                            Circle()
                              .fill(frameState.color)
                              .opacity(0.6)
                              .frame(maxWidth: 10, maxHeight: 10)
                              .offset(x: -2, y: -2)
                        }
                    }
                }
                Spacer().frame(maxHeight: 8)
            }
          .frame(minWidth: CGFloat((viewModel.config?.thumbnailWidth ?? 80) + 8),
                 minHeight: CGFloat((viewModel.config?.thumbnailHeight ?? 50) + 30))
        // highlight the selected frame
          .background(viewModel.currentIndex == frameIndex ? Color(white: 0.45) : Color(white: 0.22))
          .onTapGesture {
              viewModel.currentIndex = frameIndex
          }
    }
}

