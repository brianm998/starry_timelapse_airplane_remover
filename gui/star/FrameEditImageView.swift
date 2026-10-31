import SwiftUI
import StarCore
import logging

// displays a single frame as an image, and nothing else.
// the image may be preview, or full resolution,
// and may be one of many different types (original, processed, etc)

public struct FrameEditImageView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @Bindable var frameViewModel: FrameViewModel
    
    @State private var localID = 0
    
    private var fullResolutionImage: some View {
        @Bindable var viewModel = viewModel
        return Group {
            if let nextFrame = frameViewModel.frame {
                if let url = nextFrame.imageAccessor.urlForImage(
                     frameIndex: nextFrame.frameIndex,
                     ofType: viewModel.frameViewMode,
                     atSize: .original)
                {
                    let appendedURL = url.appending(
                        queryItems: [
                          URLQueryItem(
                            name: "v",
                            value: frameViewModel.reloadID.uuidString
                          )
                        ]
                      )
                    AsyncImage(url: appendedURL) { phase in
                        if let image = phase.image {
                            image
                        } else {
                            self.previewImage
                        }
                    }
                } else if let url = nextFrame.imageAccessor.urlForImage(
                            frameIndex: nextFrame.frameIndex,
                            ofType: viewModel.frameViewMode,
                            atSize: .preview)
                {
                    let appendedURL = url.appending(
                        queryItems: [
                          URLQueryItem(
                            name: "v",
                            value: frameViewModel.reloadID.uuidString
                          )
                        ]
                      )
                    AsyncImage(url: appendedURL) { phase in
                        if let image = phase.image {
                            image
                              .resizable()
                        } else {
                            ProgressView()
                              .colorScheme(.dark)
                        }
                    }
                }
            } else {
                Text(localized("ui.image_witn_no_frame")) // XXX make this better
            }
        }
    }

    
    /// In the default mode the full-size aligned TIFFs are never written, so opening one at
    /// full resolution builds it now (uncompressed, no fsync) and then shows it.
    private func makeFullSizeAlignedImageIfNeeded() async {
        let mode = viewModel.frameViewMode
        guard mode.isRecomputableCache,
              let frame = frameViewModel.frame,
              !frame.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                               ofType: mode, atSize: .original),
              await frame.canProduceAlignedImage(of: mode)
        else { return }
        do {
            try await frame.ensureFullSizeAlignedImage(of: mode)
            frameViewModel.existingImages.insert(mode)
            frameViewModel.reloadID = UUID()
        } catch {
            Log.w("frame \(frame.frameIndex) could not build its \(mode) image: \(error)")
        }
    }

    private var previewImage: some View {
        frameViewModel.previewImage(type: viewModel.frameViewMode)
    }

    private func maybeLoadOutliers(force: Bool = false) {

        if !viewModel.currentFrameUsesOutliers {
            // don't load outliers if we don't need to 
            return 
        }

        Log.d("maybeLoadOutliers loading already = \(frameViewModel.loadingOutlierViews)")
        // try loading outliers if there aren't any present

        if frameViewModel.outlierViews == nil || force {
            if  !frameViewModel.loadingOutlierViews {
                if let frame = frameViewModel.frame {
                    Log.d("maybeLoadOutliers actually loading")
                    frameViewModel.loadingOutlierViews = true
                    viewModel.loadingOutliers = true
                    
                    let FU = viewModel
                    Task.detached(priority: .userInitiated) {
                        Log.d("maybeLoadOutliers actually loading in background")
                        let _ = try await frame.loadOutliers(loadOnly: true)
                        await frameViewModel.computeSmallOutlierImage()
                        Task { @MainActor in
                            Log.d("maybeLoadOutliers done loading, putting outliers in view")
                            await frameViewModel.setOutlierGroups(forced: force)
                            frameViewModel.loadingOutlierViews = false
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

        if !viewModel.currentFrameUsesOutliers {
            // don't load outliers if we don't need to 
            return 
        }

        // try loading trash outliers if there aren't any present

        if viewModel.shouldShowTrash,
           frameViewModel.trashImage == nil,
           !frameViewModel.loadingTrashViews
        {
            frameViewModel.loadingTrashViews = true

            Task.detached(priority: .userInitiated) {
                await frameViewModel.computeTrashImage()
                await MainActor.run {
                    frameViewModel.loadingTrashViews = false
                }
            }
        } 
    }

    private func maybeLoadSmallOutliers() {
        // try loading trash outliers if there aren't any present

        if !viewModel.currentFrameUsesOutliers {
            // don't load outliers if we don't need to 
            return 
        }

        if (frameViewModel.positiveOutlierImage == nil || frameViewModel.negativeOutlierImage == nil) {
            frameViewModel.computeSmallOutlierImage()
        }
    }

    public var body: some View {
        @Bindable var viewModel = viewModel

        // force tracking
        let _ = frameViewModel.reloadID
        
        return Group {
            ZStack() {

                if viewModel.showFullResolution {
                    self.fullResolutionImage
                      .task(id: "\(frameViewModel.frameIndex) \(viewModel.frameViewMode.rawValue)") {
                          await makeFullSizeAlignedImageIfNeeded()
                      }
                } else {
                    self.previewImage
                }

                Rectangle()
                  .background(.black)
                  .frame(maxWidth: .infinity, maxHeight: .infinity)
                  .opacity(1.0-viewModel.frameOpacity)
                  .allowsHitTesting(false)
                
                if viewModel.currentFrameUsesOutliers {
                    ZStack() {
                        // in edit mode, show outliers groups
                        // trash goes below
                        if let trashImage = frameViewModel.trashImage {
                            if self.viewModel.shouldShowTrash {
                                trashImage
                                  .renderingMode(.template) 
                                  .foregroundColor(.yellow)
                                  .opacity(viewModel.trashOpacity)
                                  .allowsHitTesting(false)
                            }
                        }

                        // then small outliers in single images by state
                        if let smallPositiveOutlierImage = frameViewModel.positiveOutlierImage {
                            smallPositiveOutlierImage
                              .renderingMode(.template) 
                              .foregroundColor(.red)
                              .allowsHitTesting(false)
                        }
                        
                        if let smallNegativeOutlierImage = frameViewModel.negativeOutlierImage {
                            smallNegativeOutlierImage
                              .renderingMode(.template) 
                              .foregroundColor(.green)
                              .allowsHitTesting(false)
                        }
                        
                        // then the outliers that have view models
                        if let outlierViews = frameViewModel.outlierViews {
                            // put the smaller boxes first, for easier hover and tap
                            let sorted = outlierViews.sorted() {
                                $0.group.bounds.size > $1.group.bounds.size
                            }
                            // a test finds one group: the smallest box that is drawn, which is on top, so a click on it is a click on it
                            // (`-StarUITestProbes YES`, `outlier.first` in `gherkin/ui/ids.json`)
                            let probe = ViewModel.uiTestProbes ? sorted.last(where: { $0.group.size > 40 })?.group.id : nil
                            ForEach(sorted) { outlierViewModel in
                                if outlierViewModel.group.size > 40 { // XXX use a constant here
                                    OutlierGroupView(groupViewModel: outlierViewModel,
                                                     probeId: outlierViewModel.group.id == probe ? "outlier.first" : nil)
                                      .id(outlierViewModel.group.id)
                                }
                            }
                        }
                    }.opacity(viewModel.outlierOpacity)
                }
            }
        }
          .onChange(of: self.viewModel.frames[self.viewModel.currentIndex].frameObserver.numberOfUndecidedOutliers) {
              maybeLoadOutliers()
          }
          .onChange(of: self.viewModel.frames[self.viewModel.currentIndex].frameObserver.numberOfNegativeOutliers) {
              maybeLoadOutliers()
          }
          .onChange(of: self.viewModel.frames[self.viewModel.currentIndex].frameObserver.numberOfPositiveOutliers) {
              maybeLoadOutliers()
          }
          .onChange(of: viewModel.frames[self.viewModel.currentIndex].frameObserver.numberOfUndecidedOutliers) {
              maybeLoadOutliers()
          }
          .onChange(of: viewModel.currentIndex, initial: true) {
              maybeLoadOutliers()
          }
          .onChange(of: frameViewModel.outlierLoadIndex) {
              maybeLoadOutliers(force: true)
          }
          .onChange(of: viewModel.shouldShowTrash) {
              maybeLoadTrash()
          }
    }
}
