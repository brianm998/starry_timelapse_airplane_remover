import SwiftUI
import StarCore

// the view for each frame in the filmstrip at the bottom
struct FilmstripImageView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let frameIndex: Int

    var body: some View {
        VStack(alignment: .center) {
            let frameView = viewModel.frames[frameIndex]
            Spacer().frame(height: 6)
              .layoutPriority(1)
            HStack(spacing: 0) {
                Spacer().frame(width: 8)

                Text("\(frameIndex)").foregroundColor(.white)
                  .layoutPriority(8)
                Spacer()

                switch viewModel.getPixelReplacementMethod(forFrame: frameIndex) {
                case .automatic(let useOutliers):
                    if useOutliers {
                        AutoSelectiveIcon()
                          .padding(2)
                          .foregroundColor(.gray)
                          .shadow(radius: 1)
                          .help("This frame uses Auto Select")
                    } else {
                        AutoIcon()
                          .padding(2)
                          .foregroundColor(.gray)
                          .shadow(radius: 1)
                          .help("This frame uses Automatic mode")
                    }
                case .selective:
                    SelectiveIcon()
                      .padding(2)
                      .foregroundColor(.gray)
                      .shadow(radius: 1)
                      .help("This frame uses Selective mode")
                }
                
                switch frameView.outliersLoaded {
                case .unloaded:
                    // show nothing when unloaded
                    Group { }
                      .layoutPriority(1)
                    
                case .loading:
                    Image(systemName: "progress.indicator")
                      .layoutPriority(1)
                      .foregroundColor(.yellow)
                      .animation(Animation.easeInOut(duration:1)
                                   .repeatForever(autoreverses:true))
                    // XXX add .onHover() here
                    
                case .loaded:
                    HStack(spacing: -6) {
                        if let num = frameView.frameObserver.numberOfPositiveOutliers,
                           num != 0
                        {
                            Image(systemName: "line.diagonal")
                              .foregroundColor(.red)
                        }
                        if let num = frameView.frameObserver.numberOfUndecidedOutliers,
                           num != 0
                        {
                            Image(systemName: "line.diagonal")
                              .foregroundColor(.orange)
                        }
                        if let num = frameView.frameObserver.numberOfNegativeOutliers,
                           num != 0
                        {
                            Image(systemName: "line.diagonal")
                              .foregroundColor(.green)
                        }
                    }
                      .layoutPriority(1)
                }
                
                Spacer()
                  .frame(width: 4)
            }
              .frame(height: 10)

            Spacer()
              .frame(height: 6)
            
            if frameIndex >= 0 && frameIndex < viewModel.frames.count {
                ZStack(alignment: .center) {
                    // the actual thumbnail image
                    if viewModel.currentIndex == frameIndex {
                        frameView.thumbnailImage
                          .foregroundColor(.orange)
                    } else {
                        frameView.thumbnailImage
                    }
                    if let frameState = frameView.frameState {
                        // the green dot on the bottom right
                        if frameState == .complete {
                            VStack {
                                Spacer() 
                                HStack {
                                    Spacer()

                                    Circle()
                                      .fill(frameState.color)
                                      .opacity(0.6)
                                      .frame(maxWidth: 10, maxHeight: 10)
                                      .offset(x: -2, y: -2)

                                    Spacer()
                                      .frame(width: 4)
                                }
                            }
                        }
                        // processing state on the bottom left 
                        VStack {
                            Spacer() 
                            HStack {
                                Spacer()
                                  .frame(width: 8)
                                Text(frameState.shortString)
                                  .font(.system(size: 12))
                                  .foregroundColor(frameState.color)
                                Spacer()
                            }
                        }
                    }
                }
            }
            Spacer().frame(height: 8)
        }
          .frame(width: CGFloat((viewModel.config.config().thumbnailWidth) + 8),
                 height: CGFloat((viewModel.config.config().thumbnailHeight) + 30))
        // highlight the selected frame
          .background(viewModel.currentIndex == frameIndex ? Color(white: 0.45) : Color(white: 0.22))
          .onTapGesture {
              viewModel.currentIndex = frameIndex
          }
    }
}

struct AutoIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "sparkle")
                .font(.system(size: 8, weight: .regular))
        }
    }
}

struct SelectiveIcon: View {
    let width: CGFloat = 8
    var body: some View {
        ZStack {
            Circle()
                .stroke(lineWidth: 1)
                .frame(width: width, height: width)

            // Filled half (left)
            Circle()
                .frame(width: width, height: width)
                .clipShape(Rectangle().offset(x: -5))
        }
    }
}

struct AutoSelectiveIcon: View {
    var body: some View {
        ZStack {
            Image(systemName: "sparkle")
                .font(.system(size: 8, weight: .regular))

            Circle()
                .frame(width: 3, height: 3)
                .offset(x: 5, y: 5) // adjust to fit your corner
        }
    }
}
