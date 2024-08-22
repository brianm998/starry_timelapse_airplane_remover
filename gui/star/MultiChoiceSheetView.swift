import SwiftUI
import StarCore
import logging

public enum MultiChoicePaintType: String, Equatable, CaseIterable {
    case paint
    case clear

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
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
                Text("Change all overlapping outliers in other frames to:")
                
                Picker("", selection: $multiChoicePaintType) {
                    ForEach(MultiChoicePaintType.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .pickerStyle(.segmented)
                  .frame(maxWidth: 120)

                Text("What frames should we modify?")
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
                    case .paint:
                        Text("Paint overlapping outliers in all \(frames.count) frames")
                    case .clear:
                        Text("Clear overlapping outliers in all \(frames.count) frames")
                    }

                case .allAfter:
                    let numFrames = frames.count - currentIndex + 1
                    switch multiChoicePaintType {
                    case .paint:
                        Text("Paint overlapping outliers in \(numFrames) frames from frame \(currentIndex) to the end")
                    case .clear:
                        Text("Clear overlapping outliers in \(numFrames) frames from frame \(currentIndex) to the end")
                    }

                case .allBefore:
                    let numFrames = currentIndex + 1
                    switch multiChoicePaintType {
                    case .paint:
                        Text("Paint overlapping outliers in \(numFrames) frames from the start ending at frame \(currentIndex)")
                    case .clear:
                        Text("Clear overlapping outliers in \(numFrames) frames from the start ending at frame \(currentIndex)")
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
                        case .paint:
                            Button("Paint") {
                                // paint all overapping outliers
                                self.updateFrames(shouldPaint: true)
                                self.isVisible = false
                            }
                        case .clear:
                            Button("Clear") {
                                // XXX clear all overapping outliers
                                self.updateFrames(shouldPaint: false)
                                self.isVisible = false
                            }
                        }
                    case .allAfter:
                        switch multiChoicePaintType {
                        case .paint:
                            Button("Paint") {
                                // paint all overapping outliers
                                // after and including currentIndex
                                self.updateFrames(shouldPaint: true,
                                                  startIndex: currentIndex)
                                self.isVisible = false
                            }
                        case .clear:
                            Button("Clear") {
                                // clear all overapping outliers
                                // after and including currentIndex
                                self.updateFrames(shouldPaint: false,
                                                  startIndex: currentIndex)
                                self.isVisible = false
                            }
                        }
                    case .allBefore:
                        switch multiChoicePaintType {
                        case .paint:
                            Button("Paint") {
                                // paint all overapping outliers
                                // before and including currentIndex
                                self.updateFrames(shouldPaint: true,
                                                  startIndex: 0,
                                                  endIndex: currentIndex)
                                self.isVisible = false
                            }
                        case .clear:
                            Button("Clear") {
                                // clear all overapping outliers
                                // before and including currentIndex
                                self.updateFrames(shouldPaint: false,
                                                  startIndex: 0,
                                                  endIndex: currentIndex)
                                self.isVisible = false
                            }
                        }

                    case .someAfter:
                        HStack {
                            switch multiChoicePaintType {
                            case .paint:
                                Button("Paint") {
                                    // paint overapping outliers in
                                    // currentIndex and number_of_frames after
                                    self.updateFrames(shouldPaint: true,
                                                      startIndex: currentIndex,
                                                      endIndex: currentIndex + number_of_frames)
                                    self.isVisible = false
                                }
                            case .clear:
                                Button("Clear") {
                                    // clear overapping outliers in
                                    // currentIndex and number_of_frames after
                                    self.updateFrames(shouldPaint: false,
                                                      startIndex: currentIndex,
                                                      endIndex: currentIndex + number_of_frames)
                                    self.isVisible = false
                                }
                            }
                            Text("the next")
                            TextField("", value: $number_of_frames, format: .number)
                              .frame(maxWidth: 40)
                            Text("frames")
                        }
                    case .someBefore:
                        HStack {
                            switch multiChoicePaintType {
                            case .paint:
                                Button("Paint") {
                                    // paint overapping outliers in
                                    // currentIndex and number_of_frames before
                                    self.updateFrames(shouldPaint: true,
                                                      startIndex: currentIndex - number_of_frames,
                                                      endIndex: currentIndex)
                                    self.isVisible = false
                                }
                            case .clear:
                                Button("Clear") {
                                    // clear overapping outliers in
                                    // currentIndex and number_of_frames before
                                    self.updateFrames(shouldPaint: false,
                                                      startIndex: currentIndex - number_of_frames,
                                                      endIndex: currentIndex)
                                    self.isVisible = false
                                }
                            }
                            Text("the previous")
                            TextField("", value: $number_of_frames, format: .number)
                              .frame(maxWidth: 40)
                            Text("frames")
                        }
                    }
                    Button("Cancel") {
                        self.isVisible = false
                    }
                }
                Spacer()
            }
            Spacer()
        }
    }

    private func updateFrames(shouldPaint: Bool,
                              startIndex: Int = 0,
                              endIndex: Int? = nil)
    {
        Task.detached(priority: .userInitiated) {
            Log.d("update frames shouldPaint \(shouldPaint) startIndex \(startIndex) endIndex \(endIndex)")
            let end = endIndex ?? frames.count
            for frame in frames {
                if frame.frameIndex >= startIndex,
                   frame.frameIndex <= end
                {
                    await self.update(frame: frame, shouldPaint: shouldPaint)
                    // save outlier paintability changes here
                    await frame.writeOutliersBinary()
                }
            }
        }
    }
        
    private func update(frame frameView: FrameViewModel, shouldPaint: Bool) async {
        if let frame = frameView.frame {
            let new_value = shouldPaint
            Task.detached(priority: .userInitiated) {
                await frame.userSelectAllOutliers(toShouldPaint: new_value,
                                                  overlapping: multiChoiceOutlierView.groupViewModel.group)
            }
        }
    }
}
