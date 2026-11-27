import SwiftUI
import StarCore
import logging

// displays a single frame as an image, and nothing else.
// the image may be preview, or full resolution,
// and may be one of many different types (original, processed, etc)

public struct FrameEditImageView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @Bindable var frameViewModel: FrameViewModel
    
    private var fullResolutionImage: some View {
        Group {
            if let nextFrame = frameViewModel.frame {
                FullResolutionPicture(
                  path: nextFrame.imageAccessor.nameForImage(
                    frameIndex: nextFrame.frameIndex,
                    ofType: viewModel.frameViewMode,
                    atSize: .original),
                  reloadID: frameViewModel.reloadID,
                  fallback: self.previewImage)
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

    /// The id of the group a UI test clicks, only under `-StarUITestProbes YES` (`OutlierGroupView.probeGroupId`).
    private func probeGroupId(drawn: [OutlierGroupViewModel]) -> UInt16? {
        guard ViewModel.uiTestProbes else { return nil }
        let candidates = drawn.map { OutlierGroupView.ProbeCandidate(id: $0.group.id, bounds: $0.group.bounds, size: $0.group.size) }
        return OutlierGroupView.probeGroupId(groups: candidates, pointsPerPixel: viewModel.currentZoomScale)
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
                            // a test finds one group, one a click can hit at the size the frame is shown at
                            // (`-StarUITestProbes YES`, `outlier.first` in `gherkin/ui/ids.json`, `OutlierGroupView.probeGroupId`)
                            let probe = self.probeGroupId(drawn: sorted)
                            // every group's arrows and lines first, under every group's tappable view (decision 1176)
                            ForEach(sorted) { outlierViewModel in
                                if outlierViewModel.group.size > 40 {
                                    OutlierGroupView(groupViewModel: outlierViewModel, layer: .arrows)
                                      .zIndex(0)
                                      .id("arrows-\(outlierViewModel.group.id)")
                                }
                            }
                            ForEach(Array(sorted.enumerated()), id: \.element.id) { position, outlierViewModel in
                                if outlierViewModel.group.size > 40 { // XXX use a constant here
                                    OutlierGroupView(groupViewModel: outlierViewModel,
                                                     probeId: outlierViewModel.group.id == probe ? "outlier.first" : nil,
                                                     layer: .group)
                                      .zIndex(OutlierGroupView.groupZIndex(position: position))
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

/// The full-size original, loaded uncached (it is too big to keep), with the preview showing
/// until it arrives and whenever it cannot be read.
private struct FullResolutionPicture<Fallback: View>: View {
    let path: String?
    let reloadID: UUID
    let fallback: Fallback

    @State private var image: NSImage?

    private struct TaskKey: Hashable {
        let path: String?
        let reloadID: UUID
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
            } else {
                fallback
            }
        }
          .task(id: TaskKey(path: path, reloadID: reloadID)) {
              guard let path else { image = nil; return }
              let loaded = await FrameImageLoader.shared.loadUncached(path: path)
              if !Task.isCancelled { image = loaded }
          }
    }
}
