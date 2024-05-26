import SwiftUI
import StarCore

    
// shows either an editable view of the current frame or
// just the frame itself for scrubbing and video playback
// falling back to a place holder when we have no image for
// the current frame yet

public struct FrameView: View {
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
        ZStack {
            switch self.interactionMode {
            case .scrub:
                // the current frame by itself for fast video playback and scrubbing
                FrameImageView(interactionMode: self.$interactionMode,
                               showFullResolution: self.$showFullResolution)
                  .aspectRatio(contentMode: . fit)
                  .padding([.top])

            case .edit: 
                // the currently visible frame with outliers made visible
                FrameEditView(interactionMode: self.$interactionMode,
                              showFullResolution: self.$showFullResolution)
            }
        }
    }

    // initial view for when we've not loaded images yet
    var loadingView: some View {
        GeometryReader { geometry in
            ZStack {
                Rectangle()
                  .foregroundColor(.yellow)
                  .aspectRatio(CGSize(width: 4, height: 3), contentMode: .fit)
                Text(viewModel.noImageExplainationText)
                  .font(.system(size: geometry.size.height/6))
                  .opacity(0.6)
            }
              .padding([.top])
              .frame(maxWidth: .infinity, maxHeight: .infinity)
             // .transition(.moveAndFade)
        }
    }
}

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

                var showPreview = true

                if showPreview {
                    //self.currentFrameImageIndex = newFrameView.frameIndex
                    //self.currentFrameImageWasPreview = true

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
                        ZStack(/*alignment: .bottomLeading*/) {
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
