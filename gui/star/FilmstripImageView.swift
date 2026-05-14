import SwiftUI
import StarCore

// the view for each frame in the filmstrip at the bottom
struct FilmstripImageView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let frameIndex: Int

    var processingColor: Color {
        let frameView = viewModel.frames[frameIndex]
        if let frameState = frameView.frameState,
           frameState == .complete
        {
            return frameState.color
        } else {
            return .gray
        }
    }

    var body: some View {
        let frameView = viewModel.frames[frameIndex]

        // force tracking
        let _ = frameView.reloadID
        
        return VStack(alignment: .center) {
            Spacer().frame(height: 6)
              .layoutPriority(1)
            HStack(spacing: 0) {
                Spacer().frame(width: 8)

                Text("\(frameIndex)").foregroundColor(.white)
                  .layoutPriority(8)
                Spacer()

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
                
                // pixel replacement method indication on top right
                // XXX This needs to be tracked in the FrameViewModel 
                switch frameView.cleanMethod {
                case .automatic(let useOutliers):
                    if useOutliers {
                        AutoSelectiveIcon()
                          .padding(2)
                          .shadow(radius: 1)
                          .help("This frame uses Auto Select")
                          .foregroundColor(self.processingColor)
                    } else {
                        AutoIcon()
                          .padding(2)
                          .shadow(radius: 1)
                          .help("This frame uses Automatic mode")
                          .foregroundColor(self.processingColor)
                    }
                case .selective:
                    SelectiveIcon()
                      .padding(2)
                      .shadow(radius: 1)
                      .help("This frame uses Selective mode")
                      .foregroundColor(self.processingColor)
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

                    frameView.thumbnailImage

                    // Horizon overlay — coloured polyline tracing the sky/ground boundary.
                    // white = initial detected, blue = merged, green = user reference.
                    if (viewModel.userPreferences.showHorizonOnMainView ?? false),
                       let overlay = frameView.horizonOverlay {
                        let strokeColor: Color = if frameView.isPendingHorizonRefinement { .orange }
                        else { switch overlay.kind {
                            case .initial:   .white
                            case .merged:    .blue
                            case .reference: .green
                        }}
                        Canvas { ctx, size in
                            var path = Path()
                            for (col, y) in overlay.yPerColumn.enumerated() {
                                let pt = CGPoint(x: CGFloat(col), y: CGFloat(y))
                                if col == 0 { path.move(to: pt) }
                                else        { path.addLine(to: pt) }
                            }
                            ctx.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
                        }
                        .allowsHitTesting(false)
                    }

                    if let frameState = frameView.frameState {
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
                .frame(width: CGFloat(viewModel.config.config().thumbnailWidth),
                       height: CGFloat(viewModel.config.config().thumbnailHeight))
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
          .environment(frameView)
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

    let width: CGFloat = 5
    
    var body: some View {
        ZStack {
            Image(systemName: "sparkle")
                .font(.system(size: 8, weight: .regular))

            Circle()
                .stroke(lineWidth: 0.5)
                .frame(width: width, height: width)
                .offset(x: 5, y: -5) // adjust to fit your corner
                .opacity(0.5)

            Circle()
                .frame(width: width, height: width)
                .clipShape(Rectangle().offset(x: -2.5))
                .offset(x: 5, y: -5) // adjust to fit your corner
                .opacity(0.5)
        }
    }
}
