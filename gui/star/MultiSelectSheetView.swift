import SwiftUI
import StarCore
import logging

public enum MultiSelectionType: String, Equatable, CaseIterable {
    case all = "all frames"
    case allAfter = "from this frame to the end" 
    case allBefore = "from the start to this frame" 
    case someAfter = "this frame and some after"
    case someBefore = "some previous frames ending here"
    
    var localizedName: String {
        localized("multi_selection.\(rawValue)")
    }

    /// "some frames" has a number the user types and no sentence under the choices.
    var takesACount: Bool { self == .someAfter || self == .someBefore }

    /// The tail of the choice's id and of its catalogue key (the case name: the rawValues are sentences).
    var idName: String {
        switch self {
        case .all: "all"
        case .allAfter: "allAfter"
        case .allBefore: "allBefore"
        case .someAfter: "someAfter"
        case .someBefore: "someBefore"
        }
    }
}

/// One choice of a picker, as a button that carries an identifier: the segments of a stock `Picker` are AppKit radio buttons, which an
/// `accessibilityIdentifier` on the picker does not reach. The chosen one has the selected trait. `radio` draws a list row with a
/// radio glyph (the range choices); otherwise a pill (the action choices).
struct ChoiceButton: View {
    let title: String
    let selected: Bool
    let identifier: String
    var radio: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if radio {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                        .foregroundColor(selected ? .accentColor : .secondary)
                    Text(title)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            } else {
                Text(title)
                    .foregroundColor(selected ? .white : .primary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor : Color.gray.opacity(0.25)))
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

public enum MultiSelectionRemovalType: String, Equatable, CaseIterable {
    case remove
    case keep
    case removeOverlaps
    case keepOverlaps

    var localizedName: String {
        localized("multi_removal.\(rawValue)")
    }
}

struct MultiSelectSheetView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel
    
    @Binding var isVisible: Bool
    @Binding var multiSelectionType: MultiSelectionType
    @Binding var multiSelectionRemovalType: MultiSelectionRemovalType
    @Binding var frames: [FrameViewModel]
    @Binding var currentIndex: Int
    @Binding var selectionStart: CGPoint?
    @Binding var selectionEnd: CGPoint?
    @Binding var number_of_frames: Int

    var body: some View {
        VStack {
            Spacer()
              .frame(minWidth: 300)
            Text(localized("ui.change_removing_in_the_selected_area_across"))

            // the ids of the choices, which a UI test presses: "multiselect.action.*" and "multiselect.range.*" (the case names)
            HStack(spacing: 6) {
                ForEach(MultiSelectionRemovalType.allCases, id: \.self) { value in
                    ChoiceButton(title: value.localizedName, selected: multiSelectionRemovalType == value,
                                 identifier: "multiselect.action.\(value.rawValue)") { multiSelectionRemovalType = value }
                }
            }

            Text(localized("ui.what_frames_should_we_modify"))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(MultiSelectionType.allCases, id: \.self) { value in
                    ChoiceButton(title: value.localizedName, selected: multiSelectionType == value,
                                 identifier: "multiselect.range.\(value.idName)", radio: true) { multiSelectionType = value }
                }
            }
              .frame(minWidth: 280)

            // what the choices above will do, in words: the id a UI test reads the sheet's action and frames by
            // (not there for a choice with a number, which has no sentence; the space it takes stays)
            if multiSelectionType.takesACount {
                Spacer().frame(minHeight: 30)
            } else {
            Group {
                switch multiSelectionType {
                case .all:
                    switch multiSelectionRemovalType {
                    case .remove:
                        Text(localized("ui.area.remove.all", frames.count))
                    case .keep:
                        Text(localized("ui.area.keep.all", frames.count))
                    case .removeOverlaps:
                        Text(localized("ui.area.remove_overlaps.all", frames.count))
                    case .keepOverlaps:
                        Text(localized("ui.area.keep_overlaps.all", frames.count))
                    }
                
                case .allAfter:
                    let numFrames = frames.count - currentIndex
                    switch multiSelectionRemovalType {
                    case .remove:
                        Text(localized("ui.area.remove.after", numFrames, currentIndex))
                    case .keep:
                        Text(localized("ui.area.keep.after", numFrames, currentIndex))
                    case .removeOverlaps:
                        Text(localized("ui.area.remove_overlaps.after", numFrames, currentIndex))
                    case .keepOverlaps:
                        Text(localized("ui.area.keep_overlaps.after", numFrames, currentIndex))

                    }
                    
                case .allBefore:
                    let numFrames = currentIndex + 1
                    switch multiSelectionRemovalType {
                    case .remove:
                        Text(localized("ui.area.remove.before", numFrames, currentIndex))
                    case .keep:
                        Text(localized("ui.area.keep.before", numFrames, currentIndex))
                    case .removeOverlaps:
                        Text(localized("ui.area.remove_overlaps.before", numFrames, currentIndex))
                    case .keepOverlaps:
                        Text(localized("ui.area.keep_overlaps.before", numFrames, currentIndex))
                    }

               case .someAfter, .someBefore:
                    EmptyView()
                }
            
            }
              .accessibilityIdentifier("multiselect.summary")
            }

            HStack {
                Button(localized("ui.cancel")) {
                    self.isVisible = false
                }
                  .accessibilityIdentifier("multiselect.cancel")
                switch multiSelectionType {
                case .all:
                    Button(localized("ui.modify")) {
                        switch multiSelectionRemovalType {
                        case .remove:
                            self.updateFrames(shouldRemove: true)
                        case .keep:
                            self.updateFrames(shouldRemove: false)
                        case .removeOverlaps:
                            self.updateOverlappersInFrames(shouldRemove: true)
                        case .keepOverlaps:
                            self.updateOverlappersInFrames(shouldRemove: false)
                        }
                        self.isVisible = false
                    }

                case .allAfter:
                    Button(localized("ui.modify")) {

                        switch multiSelectionRemovalType {
                        case .remove:
                            self.updateFrames(shouldRemove: true,
                                              startIndex: currentIndex)
                        case .keep:
                            self.updateFrames(shouldRemove: false,
                                              startIndex: currentIndex)
                        case .removeOverlaps:
                            self.updateOverlappersInFrames(shouldRemove: true,
                                                           startIndex: currentIndex)
                        case .keepOverlaps:
                            self.updateOverlappersInFrames(shouldRemove: false,
                                                           startIndex: currentIndex)
                        }
                        self.isVisible = false
                    }
                    
                case .allBefore:
                    Button(localized("ui.modify")) {

                        switch multiSelectionRemovalType {
                        case .remove:
                            self.updateFrames(shouldRemove: true,
                                              startIndex: 0,
                                              endIndex: currentIndex)
                        case .keep:
                            self.updateFrames(shouldRemove: false,
                                              startIndex: 0,
                                              endIndex: currentIndex)
                        case .removeOverlaps:
                            self.updateOverlappersInFrames(shouldRemove: true,
                                                           startIndex: 0,
                                                           endIndex: currentIndex)
                        case .keepOverlaps:
                            self.updateOverlappersInFrames(shouldRemove: false,
                                                           startIndex: 0,
                                                           endIndex: currentIndex)
                        }

                        self.isVisible = false
                    }
                case .someAfter:
                    HStack {
                        Button(localized("ui.modify")) {


                            switch multiSelectionRemovalType {
                            case .remove:
                                self.updateFrames(shouldRemove: true,
                                                  startIndex: currentIndex,
                                                  endIndex: currentIndex + number_of_frames)
                            case .keep:
                                self.updateFrames(shouldRemove: false,
                                                  startIndex: currentIndex,
                                                  endIndex: currentIndex + number_of_frames)
                            case .removeOverlaps:
                                self.updateOverlappersInFrames(shouldRemove: true,
                                                               startIndex: currentIndex,
                                                               endIndex: currentIndex + number_of_frames)

                            case .keepOverlaps:
                                self.updateOverlappersInFrames(shouldRemove: false,
                                                               startIndex: currentIndex,
                                                               endIndex: currentIndex + number_of_frames)
                            }
                            
                            self.isVisible = false
                        }
                        Text(localized("ui.the_next"))
                        TextField("", value: $number_of_frames, format: .number)
                          .frame(maxWidth: 40)
                          .accessibilityIdentifier("multiselect.count")
                        Text(localized("ui.frames"))
                    }
                case .someBefore:
                    HStack {
                        Button(localized("ui.modify")) {
                            switch multiSelectionRemovalType {
                            case .remove:
                                self.updateFrames(shouldRemove: true,
                                                  startIndex: currentIndex - number_of_frames,
                                                  endIndex: currentIndex)
                            case .keep:
                                self.updateFrames(shouldRemove: false,
                                                  startIndex: currentIndex - number_of_frames,
                                                  endIndex: currentIndex)
                            case .removeOverlaps:
                                self.updateOverlappersInFrames(shouldRemove: true,
                                                               startIndex: currentIndex - number_of_frames,
                                                               endIndex: currentIndex)

                           case .keepOverlaps:
                                self.updateOverlappersInFrames(shouldRemove: false,
                                                               startIndex: currentIndex - number_of_frames,
                                                               endIndex: currentIndex)
                            }
                            
                            self.isVisible = false
                        }
                        Text(localized("ui.the_previous"))
                        TextField("", value: $number_of_frames, format: .number)
                          .frame(maxWidth: 40)
                          .accessibilityIdentifier("multiselect.count")
                        Text(localized("ui.frames"))
                    }
                }
            }
            Spacer()
        }.frame(minWidth: 300, idealWidth: 450, maxWidth: 800)
    }

    private func updateFrames(shouldRemove: Bool,
                              startIndex: Int = 0,
                              endIndex: Int? = nil)
    {
        let end = endIndex ?? frames.count
        let frames: [FrameViewModel] = frames
        let currentIndex = currentIndex
        Log.w("updateFrames(shouldRemove: \(shouldRemove), startIndex: \(startIndex), endIndex: \(String(describing: endIndex))")
        if let selectionStart = selectionStart,
           let selectionEnd = selectionEnd
        {
            for frameView in frames {
                if frameView.frameIndex >= startIndex,
                   frameView.frameIndex <= end,
                   let frame = frameView.frame 
                {
                    let new_value = shouldRemove
                    Task {
                        await frame.userSelectAllOutliers(toShouldRemove: new_value,
                                                          between: selectionStart,
                                                          and: selectionEnd,
                                                          includingTrash: viewModel.shouldShowTrash)
                        // save outlier removeability changes here
                        await frame.writeOutliersRemoveReasons()

                        Task {
                            do {
                                try await viewModel.render(frame: frame, now: false)
                            } catch {
                                await viewModel.report(error: localized("ui.render_failed", error))
                            }
                        }

                        await MainActor.run {
                            if currentIndex == frame.frameIndex {
                                self.selectionStart = nil
                                self.selectionEnd = nil
                            }
                        }
                    }
                }
            }
        }
    }

    private func updateOverlappersInFrames(shouldRemove: Bool,
                                           startIndex: Int = 0,
                                           endIndex: Int? = nil) 
    {
        let end = endIndex ?? frames.count
        let frames: [FrameViewModel] = frames
        let currentIndex = currentIndex

        Log.w("updateFrames(shouldRemove: \(shouldRemove), startIndex: \(startIndex), endIndex: \(String(describing: endIndex))")
        if let selectionStart = selectionStart,
           let selectionEnd = selectionEnd 
        {
            for frameView in frames {
                if frameView.frameIndex >= startIndex,
                   frameView.frameIndex <= end
                {
                    if let frame = frameView.frame {
                        Task {
                            let new_value = shouldRemove
                            await frame.foreachOutlierGroupMulti(between: selectionStart,
                                                                 and: selectionEnd,
                                                                 includingTrash: viewModel.shouldShowTrash)
                            { group, isInTrash in
                                await frame.userSelectAllOutliers(toShouldRemove: new_value,
                                                                  overlapping: group)

                            }
                            // save outlier removeability changes here
                            await frame.writeOutliersRemoveReasons()

                            Task {
                                do {
                                    try await viewModel.render(frame: frame, now: false, ever: false)
                                } catch {
                                    await viewModel.report(error: localized("ui.render_failed", error))
                                }
                            }
                            
                            await MainActor.run {
                                if currentIndex == frame.frameIndex {
                                    self.selectionStart = nil
                                    self.selectionEnd = nil
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

