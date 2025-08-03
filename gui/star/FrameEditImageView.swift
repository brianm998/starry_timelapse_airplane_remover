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
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]
        Log.d("maybeLoadOutliers loading already = \(frameView.loadingOutlierViews)")
        // try loading outliers if there aren't any present

        if frameView.outlierViews == nil {
            if  !frameView.loadingOutlierViews {
                if let frame = frameView.frame {
                    Log.d("maybeLoadOutliers actually loading")
                    frameView.loadingOutlierViews = true
                    viewModel.loadingOutliers = true
                    
                    let FU = viewModel
                    Task.detached(priority: .userInitiated) {
                        Log.d("maybeLoadOutliers actually loading in background")
                        let _ = try await frame.loadOutliers(loadOnly: true)
                        await frameView.computeSmallOutlierImage()
                        Task { @MainActor in
                            Log.d("maybeLoadOutliers done loading, putting outliers in view")
                            await frameView.setOutlierGroups()
                            frameView.loadingOutlierViews = false
                            FU.loadingOutliers = FU.loadingOutlierGroups

                            maybeLoadTrash()
                            maybeLoadSmallOutliers()
                        }
                    }
                }
            }
        } else {
            // this frame already has outliers, make sure we have images for them
            maybeLoadTrash()
            maybeLoadSmallOutliers()
        }
    }

    private func maybeLoadTrash() {
        // try loading trash outliers if there aren't any present
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]

        if viewModel.shouldShowTrash,
           frameView.trashImage == nil,
           !frameView.loadingTrashViews
        {
            frameView.loadingTrashViews = true

            Task.detached(priority: .userInitiated) {
                await frameView.computeTrashImage()
                await MainActor.run {
                    frameView.loadingTrashViews = false
                }
            }
        } 
    }

    private func maybeLoadSmallOutliers() {
        // try loading trash outliers if there aren't any present
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]

        if (frameView.positiveOutlierImage == nil || frameView.negativeOutlierImage == nil) {
            frameView.computeSmallOutlierImage()
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

                Rectangle()
                  .background(.black)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .opacity(1.0-viewModel.frameOpacity)
                
                let frameView = self.viewModel.frames[self.viewModel.currentIndex]
                ZStack() {
                    // in edit mode, show outliers groups

                    // trash goes below
                    if let trashImage = frameView.trashImage {
                        if self.viewModel.shouldShowTrash {
                            trashImage
                              .renderingMode(.template) 
                              .foregroundColor(.yellow)
                              .opacity(viewModel.trashOpacity)
                        }
                    }

                    // then small outliers in single images by state
                    if let smallPositiveOutlierImage = frameView.positiveOutlierImage {
                        smallPositiveOutlierImage
                          .renderingMode(.template) 
                          .foregroundColor(.red)
                    }
                    
                    if let smallNegativeOutlierImage = frameView.negativeOutlierImage {
                        smallNegativeOutlierImage
                          .renderingMode(.template) 
                          .foregroundColor(.green)
                    }
                    
                    // then the outliers that have view models
                    if let outlierViews = frameView.outlierViews {
                        ForEach(outlierViews) { outlierViewModel in
                            if outlierViewModel.group.size > 40 { // XXX use a constant here
                                OutlierGroupView(groupViewModel: outlierViewModel)
                                  .id(localID)
                            }
                        }
                    }
                }.opacity(viewModel.outlierOpacity)
                
                if viewModel.showIgnoreLowerBar {
                    IgnoreBarView()
                }
            }
        }
          .onChange(of: viewModel.currentIndex, initial: true) {
              maybeLoadOutliers()
          }
          .onChange(of: viewModel.shouldShowTrash) {
              maybeLoadTrash()
          }
    }
}
