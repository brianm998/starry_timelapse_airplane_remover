import SwiftUI
import StarCore

// displays a single frame as an image, and nothing else.
// the image may be preview, or full resolution,
// and may be one of many different types (original, processed, etc)

public struct FrameImageView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel

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
        Group {
            ZStack {
                if viewModel.interactionMode == .edit,
                   viewModel.showFullResolution
                {
                    self.fullResolutionImage
                } else {
                    ZStack {
                        self.previewImage
                    }
                }
                if viewModel.interactionMode == .edit {
                    Rectangle()
                      .background(.black)
                      .frame(maxWidth: .infinity, maxHeight: .infinity)
                      .opacity(1.0-viewModel.frameOpacity)
                }
            }
              .background {
                  // read geometry in background to not mess up view
                      GeometryReader { reader in
                          Rectangle()
                            .foregroundColor(.clear)
                          // check disappear and nil out frame
                            .onAppear {
                                _cursor_frame = reader.frame(in: .global)
                            }
                            .onChange(of: reader.size) { _ in
                                _cursor_frame = reader.frame(in: .global)
                            }
                      }
              }
            if viewModel.interactionMode == .edit {
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
            if viewModel.interactionMode == .edit {
                maybeLoadOutliers()
            }
        }
    }
}
