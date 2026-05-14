import SwiftUI
import StarCore

// Lightroom-style grid view: scrollable grid of frame previews.
// Single-click selects a frame; double-click enters edit mode for it.
struct GridView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var cellWidth: CGFloat {
        CGFloat(viewModel.config.config().previewWidth) * viewModel.gridThumbnailScale
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: cellWidth), spacing: 4)],
                    spacing: 4
                ) {
                    ForEach(0..<viewModel.frames.count, id: \.self) { index in
                        GridCellView(frameIndex: index)
                            .id(index)
                            .onTapGesture(count: 2) {
                                viewModel.currentIndex = index
                                viewModel.interactionMode = .edit
                            }
                            .onTapGesture {
                                viewModel.currentIndex = index
                            }
                    }
                }
                .padding(8)
            }
            .onAppear {
                proxy.scrollTo(viewModel.currentIndex, anchor: .center)
                refreshGridHorizonsIfNeeded()
            }
            .onChange(of: viewModel.currentIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
            .onChange(of: viewModel.gridThumbnailScale) { _, newScale in
                let rendered = viewModel.gridHorizonRenderedScale
                // Regenerate when scale has drifted 50% or more from the last render.
                let drift = rendered == 0 ? CGFloat.infinity
                                          : abs(newScale - rendered) / rendered
                if drift >= 0.5 {
                    viewModel.refreshGridHorizonOverlays(at: newScale)
                }
            }
        }
    }

    private func refreshGridHorizonsIfNeeded() {
        let scale = viewModel.gridThumbnailScale
        let rendered = viewModel.gridHorizonRenderedScale
        let drift = rendered == 0 ? CGFloat.infinity
                                  : abs(scale - rendered) / rendered
        if drift >= 0.5 {
            viewModel.refreshGridHorizonOverlays(at: scale)
        }
    }
}

// A single cell in the grid: preview image + header overlay.
struct GridCellView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    let frameIndex: Int

    var imageWidth: CGFloat {
        CGFloat(viewModel.config.config().previewWidth) * viewModel.gridThumbnailScale
    }

    var imageHeight: CGFloat {
        CGFloat(viewModel.config.config().previewHeight) * viewModel.gridThumbnailScale
    }

    var isSelected: Bool { viewModel.currentIndex == frameIndex }

    var body: some View {
        let frameView = viewModel.frames[frameIndex]
        let _ = frameView.reloadID

        VStack(spacing: 0) {
            // Header: frame number | outlier indicators | clean method icon
            HStack(spacing: 4) {
                Text("\(frameIndex)")
                    .foregroundColor(.white)
                    .font(.system(size: 11))
                    .padding(.leading, 4)

                Spacer()

                switch frameView.outliersLoaded {
                case .loaded:
                    HStack(spacing: -4) {
                        if let n = frameView.frameObserver.numberOfPositiveOutliers, n != 0 {
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 9))
                                .foregroundColor(.red)
                        }
                        if let n = frameView.frameObserver.numberOfUndecidedOutliers, n != 0 {
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 9))
                                .foregroundColor(.orange)
                        }
                        if let n = frameView.frameObserver.numberOfNegativeOutliers, n != 0 {
                            Image(systemName: "line.diagonal")
                                .font(.system(size: 9))
                                .foregroundColor(.green)
                        }
                    }
                default:
                    EmptyView()
                }

                switch frameView.cleanMethod {
                case .automatic(let useOutliers):
                    if useOutliers {
                        AutoSelectiveIcon()
                            .font(.system(size: 8))
                            .foregroundColor(.white)
                    } else {
                        AutoIcon()
                            .font(.system(size: 8))
                            .foregroundColor(.white)
                    }
                case .selective:
                    SelectiveIcon()
                        .foregroundColor(.white)
                }

                Spacer().frame(width: 4)
            }
            .frame(height: 20)

            // Preview image with horizon overlay and processing state badge.
            // previewImage() already applies .resizable() to the inner image.
            ZStack(alignment: .bottomLeading) {
                frameView.previewImage(type: viewModel.frameViewMode)
                    .scaledToFill()
                    .frame(width: imageWidth, height: imageHeight)
                    .clipped()

                // Horizon overlay: use gridHorizonOverlay (generated at cell dimensions)
                // when available; fall back to horizonOverlay (thumbnail-size) while it loads.
                if (viewModel.userPreferences.showHorizonOnMainView ?? false) {
                    let usingGrid = frameView.gridHorizonOverlay != nil
                    let overlay   = frameView.gridHorizonOverlay ?? frameView.horizonOverlay
                    if let overlay {
                        let strokeColor: Color = frameView.isPendingHorizonRefinement
                            ? .orange
                            : { switch overlay.kind {
                                case .initial:   .white
                                case .merged:    .blue
                                case .reference: .green
                            }}()
                        // gridHorizonOverlay was generated at (Int(imageWidth), Int(imageHeight)),
                        // so its y values span [0, Int(imageHeight)).
                        // horizonOverlay was generated at thumbnailHeight, so scale accordingly.
                        let overlayHeight = usingGrid
                            ? Int(imageHeight)
                            : viewModel.config.config().thumbnailHeight
                        Canvas { ctx, size in
                            var path = Path()
                            let cols = overlay.yPerColumn.count
                            guard cols > 0 else { return }
                            let scaleX = size.width  / CGFloat(cols)
                            let scaleY = size.height / CGFloat(overlayHeight)
                            for (col, y) in overlay.yPerColumn.enumerated() {
                                let pt = CGPoint(x: CGFloat(col) * scaleX,
                                                 y: CGFloat(y) * scaleY)
                                if col == 0 { path.move(to: pt) }
                                else        { path.addLine(to: pt) }
                            }
                            ctx.stroke(path, with: .color(strokeColor), lineWidth: 1.5)
                        }
                        .frame(width: imageWidth, height: imageHeight)
                        .allowsHitTesting(false)
                    }
                }

                if let frameState = frameView.frameState {
                    Text(frameState.shortString)
                        .font(.system(size: 10))
                        .foregroundColor(frameState.color)
                        .padding(.leading, 4)
                        .padding(.bottom, 2)
                }
            }
            .frame(width: imageWidth, height: imageHeight)
        }
        .background(isSelected ? Color(white: 0.45) : Color(white: 0.22))
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .environment(frameView)
    }
}
