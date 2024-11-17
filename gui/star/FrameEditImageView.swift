import SwiftUI
import StarCore
import logging

// displays a single frame as an image, and nothing else.
// the image may be preview, or full resolution,
// and may be one of many different types (original, processed, etc)

public struct FrameEditImageView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var localID = 0
    
    private var fullResolutionImage: some View {
        @Bindable var viewModel = viewModel
        return Group {
            let frameView = self.viewModel.currentFrameView

            if let nextFrame = frameView.frame {
                if let url = nextFrame.imageAccessor.urlForImage(ofType: viewModel.frameViewMode,
                                                                 atSize: .original)
                {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                        } else {
                            self.previewImage
                        }
                    }
                } else if let url = nextFrame.imageAccessor.urlForImage(ofType: viewModel.frameViewMode,
                                                                        atSize: .preview) {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                              .resizable()
                        } else {
                            ProgressView()
                        }
                    }
                }
            } else {
                Text("image witn no frame :(") // XXX make this better
            }
        }
    }

    
    private var previewImage: some View {
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]
        return frameView.previewImage(type: viewModel.frameViewMode)
    }

    private func maybeLoadOutliers() {
        // try loading outliers if there aren't any present
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]

        if frameView.outlierViews == nil,
           !frameView.loadingOutlierViews,
           let frame = frameView.frame
        {
            frameView.loadingOutlierViews = true
            viewModel.loadingOutliers = true

            let FU = viewModel
            Task {
                let _ = try await frame.loadOutliers(loadOnly: true)
                await self.viewModel.setOutlierGroups(forFrame: frame)
                await MainActor.run {
                    frameView.loadingOutlierViews = false
                    FU.loadingOutliers = FU.loadingOutlierGroups
                }
            }
        } 
    }

    public var body: some View {
        @Bindable var viewModel = viewModel

        return Group {
            ZStack() {

                if viewModel.showFullResolution {
                    self.fullResolutionImage
                } else {
                    self.previewImage
                }

                if viewModel.showIgnoreLowerBar {
                    IgnoreBarView()
                }

                Rectangle()
                  .background(.black)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .opacity(1.0-viewModel.frameOpacity)
                
                let frameView = self.viewModel.frames[self.viewModel.currentIndex]
                ZStack() {
                    // in edit mode, show outliers groups 
                    if let outlierViews = frameView.outlierViews {
                        ForEach(outlierViews) { outlierViewModel in
                            OutlierGroupView(groupViewModel: outlierViewModel)
                              .id(localID)
                        }
                    }
                }.opacity(viewModel.outlierOpacity)
            }
        }.onChange(of: viewModel.currentIndex, initial: true) {
            maybeLoadOutliers()
        }
    }

    var ignoreBar: some View {  // make this visible on scrub/video mode too
        ZStack {
            // red background
            Rectangle()
              .background(.red)
              .opacity(0.3)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.ignoreLowerPixels)
              .offset(y: viewModel.frameHeight/2 - viewModel.ignoreLowerPixels/2)

            // draw an X
            Path { path in
                path.addLines([CGPoint(x: 0, y: self.viewModel.frameHeight),
                               CGPoint(x: self.viewModel.frameWidth,
                                       y: self.viewModel.frameHeight-self.viewModel.ignoreLowerPixels)])
                path.closeSubpath()
                path.addLines([CGPoint(x: self.viewModel.frameWidth,
                                       y: self.viewModel.frameHeight),
                               CGPoint(x: 0,
                                       y: self.viewModel.frameHeight-self.viewModel.ignoreLowerPixels)])
                path.closeSubpath()
            }
              .stroke(.white, lineWidth: viewModel.lineWidth*2)
              .opacity(0.4)

            // arrow on the right
            Image(systemName: "arrow.left")
              .resizable()
              .foregroundColor(.orange)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: (viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .gesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.arrowHeight/2))

            // arrow on the left
            Image(systemName: "arrow.right")
              .resizable()
              .foregroundColor(.orange)
              .frame(width: viewModel.arrowLength, height: viewModel.arrowHeight) 
              .offset(x: -(viewModel.frameWidth+viewModel.arrowLength)/2,
                      y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .gesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.arrowHeight/2))

            // white line at the top of the ignore bar
            Rectangle()
              .foregroundColor(.white)
              .background(.white)
              .opacity(0.85)
              .frame(width: viewModel.frameWidth,
                     height: viewModel.lineWidth)
              .offset(y: viewModel.frameHeight/2 + viewModel.lineWidth/2 - viewModel.ignoreLowerPixels)
              .gesture(self.ignoreLowerPixelsGesture(adjustment: viewModel.lineWidth))

            // Text on the top
            if viewModel.ignoreLowerPixels > viewModel.frameHeight/11 {
                Text("This area will not be processed")
                  .foregroundColor(.red)
                  .font(.system(size: viewModel.frameHeight/12))
                  .offset(y: viewModel.frameHeight/2 - viewModel.ignoreLowerPixels/2)
            }
        }        
    }
    
    func ignoreLowerPixelsGesture(adjustment: CGFloat) -> some Gesture {
        DragGesture() 
          .onChanged { gesture in
              Log.d("gesture.location.y \(gesture.location.y) viewModel.frameHeight \(viewModel.frameHeight) viewModel.ignoreLowerPixels \(viewModel.ignoreLowerPixels)")
              let offset = viewModel.frameHeight/2 - gesture.location.y
              if viewModel.ignoreLowerPixels + offset > 0 {
                  viewModel.ignoreLowerPixels = offset + adjustment
              }
          }
          .onEnded { gesture in
              Log.d("gesture.location.y \(gesture.location.y)")
              let offset = viewModel.frameHeight/2 - gesture.location.y
              if viewModel.ignoreLowerPixels + offset > 0 {
                  viewModel.ignoreLowerPixels = offset + adjustment
              } else {
                  viewModel.ignoreLowerPixels = 0
              }
              if var config = viewModel.config {
                  config.ignoreLowerPixels = Int(viewModel.ignoreLowerPixels)
                  viewModel.config = config
                  // XXX this config doesn't get mirroried to the other spots
                  // XXX we need a centeralized config for this to work :(
                  // XXX and save the config to file as well
                  // XXX get this view working on the scrub view and during video playing
              }
          }
    }
}
