import SwiftUI
import StarCore

// Left panel shown in grid mode.
// Lets the user choose which FrameViewMode is displayed across all grid cells.
struct GridLeftPanel: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    var body: some View {
        Group {
            if viewModel.leftPanelShowing {
                openView
            } else {
                closedView
            }
        }
    }

    private var openView: some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .trailing) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    viewModeSection
                }
                .padding(12)
            }

            // Collapse arrow at bottom-right, matching LeftPanel style
            Button {
                viewModel.leftPanelShowing = false
            } label: {
                Image(systemName: "chevron.left.2")
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
            .padding(10)
        }
        .frame(width: 160)
        .background(Color(white: 0.18))
        .frame(maxHeight: .infinity, alignment: .bottomTrailing)
    }

    private var closedView: some View {
        VStack(alignment: .leading) {
            Button {
                viewModel.leftPanelShowing = true
            } label: {
                Image(systemName: "chevron.right.2")
                    .foregroundColor(.gray)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(10)
        .background(Color(white: 0.22))
        .frame(maxHeight: .infinity, alignment: .bottomTrailing)
    }

    // View mode picker: shows modes that have at least one existing preview image
    // in the sequence, or always shows original and final.
    @ViewBuilder
    private var viewModeSection: some View {
        @Bindable var viewModel = viewModel
        VStack(alignment: .leading, spacing: 8) {
            Text(localized("ui.show"))
                .font(.headline)
                .foregroundColor(.white)

            ForEach(visibleModes, id: \.self) { mode in
                let isSelected = viewModel.frameViewMode == mode
                HStack {
                    Text(mode.longName)
                        .font(.system(size: 12))
                        .foregroundColor(isSelected ? .black : .white)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 6)
                    Spacer()
                }
                .background(isSelected ? Color.accentColor : Color.clear)
                .cornerRadius(4)
                .contentShape(Rectangle())
                .onTapGesture {
                    viewModel.frameViewMode = mode
                }
            }
        }
    }

    // Modes to display in the picker.
    // Always include original and final; include others if any frame has that image type.
    private var visibleModes: [FrameViewMode] {
        let alwaysShow: Set<FrameViewMode> = [.original, .final]
        var modes: [FrameViewMode] = []
        for mode in FrameViewMode.allCases {
            if alwaysShow.contains(mode) {
                modes.append(mode)
            } else if viewModel.frames.contains(where: { $0.hasImage(type: mode) }) {
                modes.append(mode)
            }
        }
        return modes
    }
}
