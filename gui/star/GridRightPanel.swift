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
            Text(localized("ui.thumbnail_size"))
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
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 6) {
            Text(localized("ui.display"))
                .font(.headline)
                .foregroundColor(.white)

            Toggle(localized("ui.show_horizon_lines"), isOn: Binding(
                get: { viewModel.userPreferences.showHorizonOnMainView ?? false },
                set: { viewModel.userPreferences.showHorizonOnMainView = $0 }
            ))
            .toggleStyle(.switch)
            .font(.caption)
            .foregroundColor(.white)

            Toggle(localized("ui.show_filmstrip"), isOn: $viewModel.showFilmstrip)
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
            Text(localized("ui.frame"))
                .font(.headline)
                .foregroundColor(.white)

            infoRow(localized("ui.index"), value: "\(viewModel.currentIndex)")

            if let f = frame.frame,
               let url = f.imageAccessor.urlForImage(
                 frameIndex: f.frameIndex,
                 ofType: .original,
                 atSize: .original
               )
            {
                infoRow(localized("ui.file"), value: url.lastPathComponent)
                    .lineLimit(2)
            }

            if let state = frame.frameState {
                infoRow(localized("ui.state"), value: state.shortString)
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
                Text(localized("ui.outliers"))
                    .font(.headline)
                    .foregroundColor(.white)

                if let n = frame.frameObserver.numberOfPositiveOutliers {
                    infoRow(localized("ui.positive"), value: "\(n)")
                        .foregroundColor(n > 0 ? .red : .white)
                }
                if let n = frame.frameObserver.numberOfNegativeOutliers {
                    infoRow(localized("ui.negative"), value: "\(n)")
                        .foregroundColor(n > 0 ? .green : .white)
                }
                if let n = frame.frameObserver.numberOfUndecidedOutliers {
                    infoRow(localized("ui.undecided"), value: "\(n)")
                        .foregroundColor(n > 0 ? .orange : .white)
                }
                if let n = frame.frameObserver.numberOfTrashOutliers {
                    infoRow(localized("ui.trash"), value: "\(n)")
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
            Text(localized("ui.processing"))
                .font(.headline)
                .foregroundColor(.white)

            switch frame.cleanMethod {
            case .automatic(let useOutliers):
                infoRow(localized("ui.mode"), value: useOutliers ? localized("ui.auto_selective") : localized("ui.automatic"))
            case .selective:
                infoRow(localized("ui.mode"), value: localized("ui.selective"))
            }

            if frame.horizonOverlay != nil {
                infoRow(localized("ui.horizon"), value: frame.isPendingHorizonRefinement ? localized("ui.pending") : localized("ui.set"))
                    .foregroundColor(frame.isPendingHorizonRefinement ? .orange : .green)
            }
        }

        Divider()
            .background(Color.white.opacity(0.2))

        Text(localized("ui.double_click_a_thumbnail_to_edit"))
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
