import SwiftUI
import StarCore
import logging

public enum MultiChoicePaintType: String, Equatable, CaseIterable {
    case remove
    case keep

    var localizedName: String {
        localized("multi_paint.\(rawValue)")
    }
}

struct MultiChoiceSheetView: View {
    @Binding var isVisible: Bool
    @Binding var multiChoicePaintType: MultiChoicePaintType
    @Binding var multiChoiceType: MultiSelectionType
    @Binding var frames: [FrameViewModel]
    @Binding var currentIndex: Int
    @Binding var number_of_frames: Int
    let multiChoiceOutlierView: OutlierGroupView
    
    var body: some View {
        HStack {
            Spacer()
            VStack {
                Spacer()
                Text(localized("ui.change_all_overlapping_outliers_in_other"))
                
                Picker("", selection: $multiChoicePaintType) {
                    ForEach(MultiChoicePaintType.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .pickerStyle(.segmented)
                  .frame(maxWidth: 120)

                Text(localized("ui.what_frames_should_we_modify"))
                Picker("", selection: $multiChoiceType) {
                    ForEach(MultiSelectionType.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .pickerStyle(.inline)
                  .frame(minWidth: 280)

                
                switch multiChoiceType {
                case .all:
                    switch multiChoicePaintType {
                    case .remove:
                        Text(localized("ui.overlap.paint.all", frames.count))
                    case .keep:
                        Text(localized("ui.overlap.clear.all", frames.count))
                    }

                case .allAfter:
                    let numFrames = frames.count - currentIndex + 1
                    switch multiChoicePaintType {
                    case .remove:
                        Text(localized("ui.overlap.paint.after", numFrames, currentIndex))
                    case .keep:
                        Text(localized("ui.overlap.clear.after", numFrames, currentIndex))
                    }

                case .allBefore:
                    let numFrames = currentIndex + 1
                    switch multiChoicePaintType {
                    case .remove:
                        Text(localized("ui.overlap.paint.before", numFrames, currentIndex))
                    case .keep:
                        Text(localized("ui.overlap.clear.before", numFrames, currentIndex))
                    }

                case .someAfter:
                    Spacer().frame(minHeight: 30)

                case .someBefore:
                    Spacer().frame(minHeight: 30)

                }

                HStack {
                    switch multiChoiceType {
                    case .all:
                        switch multiChoicePaintType {
                        case .remove:
                            Button(localized("ui.remove")) {
                                // paint all overapping outliers
                                self.updateFrames(shouldRemove: true)
                                self.isVisible = false
                            }
                        case .keep:
                            Button(localized("ui.keep")) {
                                // XXX clear all overapping outliers
                                self.updateFrames(shouldRemove: false)
                                self.isVisible = false
                            }
                        }
                    case .allAfter:
                        switch multiChoicePaintType {
                        case .remove:
                            Button(localized("ui.remove")) {
                                // paint all overapping outliers
                                // after and including currentIndex
                                self.updateFrames(shouldRemove: true,
                                                  startIndex: currentIndex)
                                self.isVisible = false
                            }
                        case .keep:
                            Button(localized("ui.keep")) {
                                // clear all overapping outliers
                                // after and including currentIndex
                                self.updateFrames(shouldRemove: false,
                                                  startIndex: currentIndex)
                                self.isVisible = false
                            }
                        }
                    case .allBefore:
                        switch multiChoicePaintType {
                        case .remove:
                            Button(localized("ui.remove")) {
                                // paint all overapping outliers
                                // before and including currentIndex
                                self.updateFrames(shouldRemove: true,
                                                  startIndex: 0,
                                                  endIndex: currentIndex)
                                self.isVisible = false
                            }
                        case .keep:
                            Button(localized("ui.keep")) {
                                // clear all overapping outliers
                                // before and including currentIndex
                                self.updateFrames(shouldRemove: false,
                                                  startIndex: 0,
                                                  endIndex: currentIndex)
                                self.isVisible = false
                            }
                        }

                    case .someAfter:
                        HStack {
                            switch multiChoicePaintType {
                            case .remove:
                                Button(localized("ui.remove")) {
                                    // paint overapping outliers in
                                    // currentIndex and number_of_frames after
                                    self.updateFrames(shouldRemove: true,
                                                      startIndex: currentIndex,
                                                      endIndex: currentIndex + number_of_frames)
                                    self.isVisible = false
                                }
                            case .keep:
                                Button(localized("ui.keep")) {
                                    // clear overapping outliers in
                                    // currentIndex and number_of_frames after
                                    self.updateFrames(shouldRemove: false,
                                                      startIndex: currentIndex,
                                                      endIndex: currentIndex + number_of_frames)
                                    self.isVisible = false
                                }
                            }
                            Text(localized("ui.the_next"))
                            TextField("", value: $number_of_frames, format: .number)
                              .frame(maxWidth: 40)
                            Text(localized("ui.frames"))
                        }
                    case .someBefore:
                        HStack {
                            switch multiChoicePaintType {
                            case .remove:
                                Button(localized("ui.remove")) {
                                    // paint overapping outliers in
                                    // currentIndex and number_of_frames before
                                    self.updateFrames(shouldRemove: true,
                                                      startIndex: currentIndex - number_of_frames,
                                                      endIndex: currentIndex)
                                    self.isVisible = false
                                }
                            case .keep:
                                Button(localized("ui.keep")) {
                                    // clear overapping outliers in
                                    // currentIndex and number_of_frames before
                                    self.updateFrames(shouldRemove: false,
                                                      startIndex: currentIndex - number_of_frames,
                                                      endIndex: currentIndex)
                                    self.isVisible = false
                                }
                            }
                            Text(localized("ui.the_previous"))
                            TextField("", value: $number_of_frames, format: .number)
                              .frame(maxWidth: 40)
                            Text(localized("ui.frames"))
                        }
                    }
                    Button(localized("ui.cancel")) {
                        self.isVisible = false
                    }
                }
                Spacer()
            }
            Spacer()
        }
    }

    private func updateFrames(shouldRemove: Bool,
                              startIndex: Int = 0,
                              endIndex: Int? = nil)
    {
//        Task.detached(priority: .userInitiated) {
            Log.d("update frames shouldRemove \(shouldRemove) startIndex \(startIndex) endIndex \(endIndex)")
            let end = endIndex ?? frames.count
            for frame in frames {
                if frame.frameIndex >= startIndex,
                   frame.frameIndex <= end
                {
                  Task { await self.update(frame: frame, shouldRemove: shouldRemove) }
                }
            }
//        }
    }
        
    private func update(frame frameView: FrameViewModel, shouldRemove: Bool) async {
        if let frame = frameView.frame {
            let new_value = shouldRemove
//            Task.detached(priority: .userInitiated) {
                await frame.userSelectAllOutliers(toShouldRemove: new_value,
                                                  overlapping: multiChoiceOutlierView.groupViewModel.group)
                // save outlier paintability changes here
                await frame.writeOutliersRemoveReasons()
            }
//        }
    }
}
