import SwiftUI
import StarCore

// displays a single frame as an image, and nothing else.
// the image may be preview, or full resolution,
// and may be one of many different types (original, processed, etc)

public struct FrameImageView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @Binding private var interactionMode: InteractionMode
    @Binding private var showFullResolution: Bool

    public init(interactionMode: Binding<InteractionMode>,
                showFullResolution: Binding<Bool>)
    {
        _interactionMode = interactionMode
        _showFullResolution = showFullResolution
    }

    private var fullResolutionImage: some View {
        Group {
            let frameView = self.viewModel.currentFrameView

            if let nextFrame = frameView.frame,
               let url = nextFrame.imageAccessor.urlForImage(ofType: viewModel.frameViewMode.frameImageType,
                                                             atSize: .original)
            {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image
                    } else {
                        self.previewImage
                    }
                }
            } else {
                Text("no url for image :(") // XXX make this better
            }
        }
    }

    private var previewImage: some View {
        let frameView = self.viewModel.frames[self.viewModel.currentIndex]
        switch viewModel.frameViewMode {
        case .original:
            return frameView.previewImage
        case .subtraction:
            return frameView.subtractionPreviewImage
        case .blobs:
            return frameView.blobsPreviewImage
        case .filter1:
            return frameView.filter1PreviewImage
        case .filter2:
            return frameView.filter2PreviewImage
        case .filter3:
            return frameView.filter3PreviewImage
        case .filter4:
            return frameView.filter4PreviewImage
        case .filter5:
            return frameView.filter5PreviewImage
        case .filter6:
            return frameView.filter6PreviewImage
        case .paintMask:
            return frameView.paintMaskPreviewImage
        case .validation:
            return frameView.validationPreviewImage
        case .processed:
            return frameView.processedPreviewImage
        }
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
                let _ = try await frame.loadOutliers()
                await self.viewModel.setOutlierGroups(forFrame: frame)
                await MainActor.run {
                    frameView.loadingOutlierViews = false
                    FU.loadingOutliers = FU.loadingOutlierGroups
                }
            }
        } 
    }
    
    public var body: some View {
        Group {

            if interactionMode == .edit,
               showFullResolution
            {
                self.fullResolutionImage
            } else {
                self.previewImage
            }

            if interactionMode == .edit {
                let frameView = self.viewModel.frames[self.viewModel.currentIndex]
                ZStack() {
                    // in edit mode, show outliers groups 
                    if let outlierViews = frameView.outlierViews {
                        ForEach(outlierViews) { outlierViewModel in
                            OutlierGroupView(groupViewModel: outlierViewModel)
                        }
                    }
                }.opacity(viewModel.outlierOpacity)
            }

        }.onChange(of: viewModel.currentIndex, initial: true) {
            if interactionMode == .edit {
                maybeLoadOutliers()
            }
        }
    }
}
