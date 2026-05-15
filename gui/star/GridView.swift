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
                viewModel.refreshGridHorizonOverlays(at: newScale)
            }
        }
    }

    private func refreshGridHorizonsIfNeeded() {
        let scale = viewModel.gridThumbnailScale
        let rendered = viewModel.gridHorizonRenderedScale
        if rendered != scale {
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

    // Primary/highlighted frame — shown with brightest selection colour.
    var isHighlighted: Bool { viewModel.currentIndex == frameIndex }
    // Part of a multi-frame selection but not the highlighted anchor.
    var isInSelection: Bool {
        !isHighlighted && viewModel.selectedFrameIndices.contains(frameIndex)
    }
    // Either highlighted or in secondary selection.
    var isSelected: Bool { isHighlighted || isInSelection }

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
            ZStack(alignment: .bottomLeading) {
                frameView.previewImage(type: viewModel.frameViewMode)
                    .scaledToFill()
                    .frame(width: imageWidth, height: imageHeight)
                    .clipped()

                if (viewModel.userPreferences.showHorizonOnMainView ?? false) {
                    let overlay = frameView.gridHorizonOverlay ?? frameView.horizonOverlay
                    if let overlay {
                        let strokeColor: Color = frameView.isPendingHorizonRefinement
                            ? .orange
                            : { switch overlay.kind {
                                case .initial:   .white
                                case .merged:    .blue
                                case .reference: .green
                            }}()
                        let overlayHeight = overlay.height
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
        // Three visual states: highlighted (brightest), in-selection, unselected.
        .background(
            isHighlighted  ? Color(white: 0.52) :
            isInSelection  ? Color(white: 0.38) :
                             Color(white: 0.22)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 2)
                .stroke(
                    isHighlighted ? Color.accentColor :
                    isInSelection ? Color.accentColor.opacity(0.55) :
                                    Color.clear,
                    lineWidth: isHighlighted ? 2 : 1
                )
        )
        .onTapGesture(count: 2) {
            viewModel.currentIndex = frameIndex
            viewModel.selectedFrameIndices = [frameIndex]
            viewModel.interactionMode = .edit
        }
        .onTapGesture {
            handleTap()
        }
        .contextMenu {
            frameContextMenu
        }
        .environment(frameView)
    }

    private func handleTap() {
        let mods = NSEvent.modifierFlags
        if mods.contains(.shift) {
            // Range-select from current anchor to this frame.
            let lo = min(viewModel.currentIndex, frameIndex)
            let hi = max(viewModel.currentIndex, frameIndex)
            viewModel.selectedFrameIndices = Set(lo...hi)
            // currentIndex stays as the anchor highlight; don't change it.
        } else if mods.contains(.command) {
            if viewModel.selectedFrameIndices.contains(frameIndex) {
                // Deselect — but never deselect the highlighted anchor.
                if frameIndex != viewModel.currentIndex {
                    viewModel.selectedFrameIndices.remove(frameIndex)
                }
            } else {
                // Add to selection; ensure currentIndex is also in the set.
                viewModel.selectedFrameIndices.insert(frameIndex)
                viewModel.selectedFrameIndices.insert(viewModel.currentIndex)
            }
        } else {
            // Plain click — single selection.
            viewModel.currentIndex = frameIndex
            viewModel.selectedFrameIndices = [frameIndex]
        }
    }

    @ViewBuilder
    private var frameContextMenu: some View {
        // Only show processing options when the user right-clicks a selected frame.
        if isSelected {
            let count = viewModel.isMultiSelecting
                ? viewModel.selectedFrameIndices.count
                : 1
            let label = count == 1 ? "1 Frame" : "\(count) Frames"

            Text(label)
                .font(.headline)

            Divider()

            Button {
                viewModel.processSelectedFrames(with: .none)
            } label: {
                Label("Process \(label) (new only)", systemImage: "play.circle")
            }

            Divider()

            Button {
                viewModel.processSelectedFrames(with: .alignment)
            } label: {
                Label("Re-Process Alignment", systemImage: "arrow.triangle.2.circlepath")
            }

            Button {
                viewModel.processSelectedFrames(with: .outliers)
            } label: {
                Label("Re-Process Outliers", systemImage: "line.diagonal")
            }

            Button {
                viewModel.processSelectedFrames(with: .horizons)
            } label: {
                Label("Re-Process Horizons", systemImage: "mountain.2")
            }

            Divider()

            Button(role: .destructive) {
                viewModel.processSelectedFrames(with: .everything)
            } label: {
                Label("Re-Process Everything", systemImage: "arrow.clockwise.circle")
            }
        }
    }
}
