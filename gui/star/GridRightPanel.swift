import SwiftUI
import StarCore

// Right-side info panel shown in grid mode.
// Displays metadata about the currently selected frame, Lightroom-style.
struct GridRightPanel: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            if viewModel.rightPanelShowing {
                openView
            } else {
                closedView
            }
        }
    }

    private var openView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    thumbnailSizeSection
                    horizonSection
                    frameInfoSection
                    outlierSection
                    processingSection
                }
                .padding(12)
            }

            Spacer()

            Button {
                viewModel.rightPanelShowing = false
            } label: {
                Image(systemName: "chevron.right.2")
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
            .cursor(.resizeRight)
        }
        .padding(10)
        .frame(width: 200)
        .frame(maxHeight: .infinity, alignment: .bottomLeading)
        .background(Color(white: 0.22))
    }

    private var closedView: some View {
        VStack {
            Button {
                viewModel.rightPanelShowing = true
            } label: {
                Image(systemName: "chevron.left.2")
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
            .cursor(.resizeLeft)
        }
        .padding(10)
        .background(Color(white: 0.22))
        .frame(maxHeight: .infinity, alignment: .bottomLeading)
    }

    // Thumbnail size slider
    private var thumbnailSizeSection: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 6) {
            Text("Thumbnail Size")
                .font(.headline)
                .foregroundColor(.white)

            // 0.02 = very small, 0.5 = ~809×540 (large)
            Slider(value: $viewModel.gridThumbnailScale, in: 0.02...0.5)
                .labelsHidden()

            Text(String(format: "%.2f×", viewModel.gridThumbnailScale))
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
        }
    }

    // Global horizon line visibility toggle
    private var horizonSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Display")
                .font(.headline)
                .foregroundColor(.white)

            Toggle("Show Horizon Lines", isOn: Binding(
                get: { viewModel.userPreferences.showHorizonOnMainView ?? false },
                set: { viewModel.userPreferences.showHorizonOnMainView = $0 }
            ))
            .toggleStyle(.switch)
            .font(.caption)
            .foregroundColor(.white)
        }
    }

    // Basic frame identity
    @ViewBuilder
    private var frameInfoSection: some View {
        let frame = viewModel.frames[viewModel.currentIndex]

        VStack(alignment: .leading, spacing: 6) {
            Text("Frame")
                .font(.headline)
                .foregroundColor(.white)

            infoRow("Index", value: "\(viewModel.currentIndex)")

            if let f = frame.frame,
               let url = f.imageAccessor.urlForImage(
                 frameIndex: f.frameIndex,
                 ofType: .original,
                 atSize: .original
               )
            {
                infoRow("File", value: url.lastPathComponent)
                    .lineLimit(2)
            }

            if let state = frame.frameState {
                infoRow("State", value: state.shortString)
                    .foregroundColor(state.color)
            }
        }
    }

    // Outlier counts
    @ViewBuilder
    private var outlierSection: some View {
        let frame = viewModel.frames[viewModel.currentIndex]

        if frame.outliersLoaded == .loaded {
            VStack(alignment: .leading, spacing: 6) {
                Text("Outliers")
                    .font(.headline)
                    .foregroundColor(.white)

                if let n = frame.frameObserver.numberOfPositiveOutliers {
                    infoRow("Positive", value: "\(n)")
                        .foregroundColor(n > 0 ? .red : .white)
                }
                if let n = frame.frameObserver.numberOfNegativeOutliers {
                    infoRow("Negative", value: "\(n)")
                        .foregroundColor(n > 0 ? .green : .white)
                }
                if let n = frame.frameObserver.numberOfUndecidedOutliers {
                    infoRow("Undecided", value: "\(n)")
                        .foregroundColor(n > 0 ? .orange : .white)
                }
                if let n = frame.frameObserver.numberOfTrashOutliers {
                    infoRow("Trash", value: "\(n)")
                        .foregroundColor(n > 0 ? .gray : .white)
                }
            }
        }
    }

    // Processing and clean method info
    @ViewBuilder
    private var processingSection: some View {
        let frame = viewModel.frames[viewModel.currentIndex]

        VStack(alignment: .leading, spacing: 6) {
            Text("Processing")
                .font(.headline)
                .foregroundColor(.white)

            switch frame.cleanMethod {
            case .automatic(let useOutliers):
                infoRow("Mode", value: useOutliers ? "Auto-Selective" : "Automatic")
            case .selective:
                infoRow("Mode", value: "Selective")
            }

            if frame.horizonOverlay != nil {
                infoRow("Horizon", value: frame.isPendingHorizonRefinement ? "Pending" : "Set")
                    .foregroundColor(frame.isPendingHorizonRefinement ? .orange : .green)
            }
        }

        Divider()
            .background(Color.white.opacity(0.2))

        Text("Double-click a thumbnail to edit")
            .font(.caption)
            .foregroundColor(.white.opacity(0.5))
            .multilineTextAlignment(.leading)
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 62, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
