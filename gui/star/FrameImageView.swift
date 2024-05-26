import SwiftUI
import StarCore

// displays a single frame as an image

public struct FrameImageView: View {
    @EnvironmentObject var viewModel: ViewModel
    @Binding private var interactionMode: InteractionMode
    @Binding private var showFullResolution: Bool

    public init(interactionMode: Binding<InteractionMode>,
                showFullResolution: Binding<Bool>)
    {
        _interactionMode = interactionMode
        _showFullResolution = showFullResolution
    }

    public var body: some View {
        Group {
            let frameView = self.viewModel.frames[self.viewModel.currentIndex]

            if let nextFrame = frameView.frame {
                
                if showFullResolution {
                    // XXX do this
                } else {
                    switch viewModel.frameViewMode {
                    case .original:
                        frameView.previewImage
                    case .subtraction:
                        frameView.subtractionPreviewImage
                    case .blobs:
                        frameView.blobsPreviewImage
                    case .absorbedBlobs:
                        frameView.absorbedPreviewImage
                    case .rectifiedBlobs:
                        frameView.rectifiedPreviewImage
                    case .paintMask:
                        frameView.paintMaskPreviewImage
                    case .validation:
                        frameView.validationPreviewImage
                    case .processed:
                        frameView.processedPreviewImage
                    }
                }

                var showOutliers = true
                if showOutliers {
                    if interactionMode == .edit {
                        ZStack() {
                            // in edit mode, show outliers groups 
                            if let outlierViews = frameView.outlierViews {
                                ForEach(0 ..< outlierViews.count, id: \.self) { idx in
                                    if idx < outlierViews.count {
                                        // the actual outlier view
                                        outlierViews[idx].view
                                    }
                                }
                            }
                        }.opacity(viewModel.outlierOpacity)
                    }
                }
            }
        }.onAppear {
            // XXX this only works the first time the ui shows, not when we transition frames :(
            if interactionMode == .edit {
                // try loading outliers if there aren't any present
                let frameView = self.viewModel.frames[self.viewModel.currentIndex]

                if frameView.outlierViews == nil,
                   !frameView.loadingOutlierViews,
                   let frame = frameView.frame
                {
                    frameView.loadingOutlierViews = true
                    viewModel.loadingOutliers = true
                    Task.detached(priority: .userInitiated) {
                        let _ = try await frame.loadOutliers()
                        await self.viewModel.setOutlierGroups(forFrame: frame)
                        Task { @MainActor in
                            frameView.loadingOutlierViews = false
                            self.viewModel.loadingOutliers = self.viewModel.loadingOutlierGroups
                        }
                    }
                }
            } 
        }
    }
}
