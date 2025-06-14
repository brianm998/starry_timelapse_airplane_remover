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
                if let url = nextFrame.imageAccessor.urlForImage(frameIndex: nextFrame.frameIndex,
                                                                 ofType: viewModel.frameViewMode,
                                                                 atSize: .original)
                {
                    AsyncImage(url: url) { phase in
                        if let image = phase.image {
                            image
                        } else {
                            self.previewImage
                        }
                    }
                } else if let url = nextFrame.imageAccessor.urlForImage(frameIndex: nextFrame.frameIndex,
                                                                        ofType: viewModel.frameViewMode,
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

    private func maybeLoadDustbin() { 
        // try loading dustbin outliers if there aren't any present
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]

        if viewModel.shouldShowDustbin,
           frameView.dustbinImage == nil,
           !frameView.loadingDustbinViews,
           let frame = frameView.frame
        {
            frameView.loadingDustbinViews = true

            Task {
                await self.viewModel.computeDustbinImage(forFrame: frame)
                await MainActor.run {
                    frameView.loadingDustbinViews = false
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

                    // dustbin does below
                    if self.viewModel.shouldShowDustbin,
                       let dustbinImage = frameView.dustbinImage
                    {
                        dustbinImage
                          .renderingMode(.template) 
                          .foregroundColor(.yellow)
                          .opacity(viewModel.dustbinOpacity)
                    }

                    // then the outliers that have view models
                    if let outlierViews = frameView.outlierViews {
                        ForEach(outlierViews) { outlierViewModel in
                            OutlierGroupView(groupViewModel: outlierViewModel)
                              .id(localID)
                        }
                    }
                }.opacity(viewModel.outlierOpacity)
            }
        }
          .onChange(of: viewModel.currentIndex, initial: true) {
              maybeLoadOutliers()
              maybeLoadDustbin()
          }
          .onChange(of: viewModel.shouldShowDustbin) {
              maybeLoadDustbin()
          }
    }
}
