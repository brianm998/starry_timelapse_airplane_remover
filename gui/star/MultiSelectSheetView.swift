import SwiftUI
import StarCore
import logging

public enum MultiSelectionType: String, Equatable, CaseIterable {
    case all = "all frames"
    case allAfter = "from this frame to the end" 
    case allBefore = "from the start to this frame" 
    case someAfter = "this frame and some after"
    case someBefore = "some previous frames ending here"
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

public enum MultiSelectionPaintType: String, Equatable, CaseIterable {
    case paint
    case clear

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

struct MultiSelectSheetView: View {
    @Binding var isVisible: Bool
    @Binding var multiSelectionType: MultiSelectionType
    @Binding var multiSelectionPaintType: MultiSelectionPaintType
    @Binding var frames: [FrameViewModel]
    @Binding var currentIndex: Int
    @Binding var drag_start: CGPoint?
    @Binding var drag_end: CGPoint?
    @Binding var number_of_frames: Int
    var shouldPaint: Bool {
        switch multiSelectionPaintType {
        case .paint:
            return true
        case .clear:
            return false
        }
    }
    
    var body: some View {
        VStack {
            Spacer()
              .frame(minWidth: 300)
            Text("Change painting in the selected area across more than one frame.")

            Picker("", selection: $multiSelectionPaintType) {
                ForEach(MultiSelectionPaintType.allCases, id: \.self) { value in
                    Text(value.localizedName).tag(value)
                }
            }
              .pickerStyle(.segmented)
              .frame(maxWidth: 120)
            
            Text("What frames should we modify?")
            Picker("", selection: $multiSelectionType) {
                ForEach(MultiSelectionType.allCases, id: \.self) { value in
                    Text(value.localizedName).tag(value)
                }
            }
              .pickerStyle(.inline)
              .frame(minWidth: 280)

            switch multiSelectionType {
            case .all:
                switch multiSelectionPaintType {
                case .paint:
                    Text("Paint outliers in this area in all \(frames.count) frames")
                case .clear:
                    Text("Clear outliers in this area in all \(frames.count) frames")
                }
                
            case .allAfter:
                let numFrames = frames.count - currentIndex + 1
                switch multiSelectionPaintType {
                case .paint:
                    Text("Paint outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .clear:
                    Text("Clear outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                }
                    
            case .allBefore:
                let numFrames = currentIndex + 1
                switch multiSelectionPaintType {
                case .paint:
                    Text("Paint outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .clear:
                    Text("Clear outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                }

           case .someAfter:
                Spacer().frame(minHeight: 30)
           case .someBefore:
                Spacer().frame(minHeight: 30)
            }
            
            HStack {
                Button("Cancel") {
                    self.isVisible = false
                }
                switch multiSelectionType {
                case .all:
                    Button("Modify") {
                        self.updateFrames(shouldPaint: self.shouldPaint)
                        self.isVisible = false
                    }

                case .allAfter:
                    Button("Modify") {
                        self.updateFrames(shouldPaint: self.shouldPaint, startIndex: currentIndex)
                        self.isVisible = false
                    }
                    
                case .allBefore:
                    Button("Modify") {
                        self.updateFrames(shouldPaint: self.shouldPaint,
                                          startIndex: 0,
                                          endIndex: currentIndex)
                        self.isVisible = false
                    }
                case .someAfter:
                    HStack {
                        Button("Modify") {
                            self.updateFrames(shouldPaint: self.shouldPaint,
                                              startIndex: currentIndex,
                                              endIndex: currentIndex + number_of_frames)
                            self.isVisible = false
                        }
                        Text("the next")
                        TextField("", value: $number_of_frames, format: .number)
                          .frame(maxWidth: 40)
                        Text("frames")
                    }
                case .someBefore:
                    HStack {
                        Button("Modify") {
                            self.updateFrames(shouldPaint: self.shouldPaint,
                                              startIndex: currentIndex - number_of_frames,
                                              endIndex: currentIndex)
                            self.isVisible = false
                        }
                        Text("the previous")
                        TextField("", value: $number_of_frames, format: .number)
                          .frame(maxWidth: 40)
                        Text("frames")
                    }
                }
            }
            Spacer()
        }.frame(minWidth: 300, idealWidth: 450, maxWidth: 800)
    }

    private func updateFrames(shouldPaint: Bool,
                              startIndex: Int = 0,
                              endIndex: Int? = nil)
    {
        Log.w("updateFrames(shouldPaint: \(shouldPaint), startIndex: \(startIndex), endIndex: \(endIndex)")
        let end = endIndex ?? frames.count
        if let drag_start = drag_start,
           let drag_end = drag_end
        {
            for frame in frames {
                if frame.frameIndex >= startIndex,
                   frame.frameIndex <= end
                {
                    update(frame: frame,
                           shouldPaint: shouldPaint,
                           between: drag_start,
                           and: drag_end)
                }
            }
        }
        drag_start = nil        // XXX doesn't clear in view model
        drag_end = nil
    }
    
    private func update(frame frameView: FrameViewModel,
                        shouldPaint: Bool,
                        between drag_start: CGPoint,
                        and end_location: CGPoint)
    {
        frameView.userSelectAllOutliers(toShouldPaint: shouldPaint,
                                        between: drag_start,
                                        and: end_location)
        //update the view layer
        frameView.update()
        if let frame = frameView.frame {
            let new_value = shouldPaint
            Task.detached(priority: .userInitiated) {
                await frame.userSelectAllOutliers(toShouldPaint: new_value,
                                                  between: drag_start,
                                                  and: end_location)
                //await MainActor.run { viewModel.update() }
            }
        }
    }
}

