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
    case delete
    case paintOverlaps
    case clearOverlaps

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
    @Binding var selectionStart: CGPoint?
    @Binding var selectionEnd: CGPoint?
    @Binding var number_of_frames: Int

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
                case .delete:
                    Text("Remove outliers in this area in all \(frames.count) frames")
                case .paintOverlaps:
                    Text("Paint overlaying outliers in this area in all \(frames.count) frames")
                case .clearOverlaps:
                    Text("Clear overlaying outliers in this area in all \(frames.count) frames")
                }
                
            case .allAfter:
                let numFrames = frames.count - currentIndex + 1
                switch multiSelectionPaintType {
                case .paint:
                    Text("Paint outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .clear:
                    Text("Clear outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .delete:
                    Text("Remove outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .paintOverlaps:
                    Text("Paint overlaying outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .clearOverlaps:
                    Text("Clear overlaying outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")

                }
                    
            case .allBefore:
                let numFrames = currentIndex + 1
                switch multiSelectionPaintType {
                case .paint:
                    Text("Paint outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .clear:
                    Text("Clear outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .delete:
                    Text("Remove outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .paintOverlaps:
                    Text("Paint overlaying outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .clearOverlaps:
                    Text("Clear overlaying outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
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
                        switch multiSelectionPaintType {
                        case .paint:
                            self.updateFrames(shouldPaint: true)
                        case .clear:
                            self.updateFrames(shouldPaint: false)
                        case .delete:
                            self.deleteFromFrames()
                        case .paintOverlaps:
                            self.updateOverlappersInFrames(shouldPaint: true)
                        case .clearOverlaps:
                            self.updateOverlappersInFrames(shouldPaint: false)
                        }
                        self.isVisible = false
                    }

                case .allAfter:
                    Button("Modify") {

                        switch multiSelectionPaintType {
                        case .paint:
                            self.updateFrames(shouldPaint: true,
                                              startIndex: currentIndex)
                        case .clear:
                            self.updateFrames(shouldPaint: false,
                                              startIndex: currentIndex)
                        case .delete:
                            self.deleteFromFrames(startIndex: currentIndex)
                        case .paintOverlaps:
                            self.updateOverlappersInFrames(shouldPaint: true,
                                                           startIndex: currentIndex)
                        case .clearOverlaps:
                            self.updateOverlappersInFrames(shouldPaint: false,
                                                           startIndex: currentIndex)
                        }
                        self.isVisible = false
                    }
                    
                case .allBefore:
                    Button("Modify") {

                        switch multiSelectionPaintType {
                        case .paint:
                            self.updateFrames(shouldPaint: true,
                                              startIndex: 0,
                                              endIndex: currentIndex)
                        case .clear:
                            self.updateFrames(shouldPaint: false,
                                              startIndex: 0,
                                              endIndex: currentIndex)
                        case .delete:
                            self.deleteFromFrames(startIndex: 0,
                                                  endIndex: currentIndex)
                        case .paintOverlaps:
                            self.updateOverlappersInFrames(shouldPaint: true,
                                                           endIndex: currentIndex)
                        case .clearOverlaps:
                            self.updateOverlappersInFrames(shouldPaint: true,
                                                           endIndex: currentIndex)
                        }

                        self.isVisible = false
                    }
                case .someAfter:
                    HStack {
                        Button("Modify") {


                            switch multiSelectionPaintType {
                            case .paint:
                                self.updateFrames(shouldPaint: true,
                                                  startIndex: currentIndex,
                                                  endIndex: currentIndex + number_of_frames)
                            case .clear:
                                self.updateFrames(shouldPaint: false,
                                                  startIndex: currentIndex,
                                                  endIndex: currentIndex + number_of_frames)
                            case .delete:
                                self.deleteFromFrames(startIndex: currentIndex,
                                                      endIndex: currentIndex + number_of_frames)
                            case .paintOverlaps:
                                self.updateOverlappersInFrames(shouldPaint: true,
                                                               endIndex: currentIndex + number_of_frames)

                            case .clearOverlaps:
                                self.updateOverlappersInFrames(shouldPaint: false,
                                                               endIndex: currentIndex + number_of_frames)
                            }
                            
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
                            switch multiSelectionPaintType {
                            case .paint:
                                self.updateFrames(shouldPaint: true,
                                                  startIndex: currentIndex - number_of_frames,
                                                  endIndex: currentIndex)
                            case .clear:
                                self.updateFrames(shouldPaint: false,
                                                  startIndex: currentIndex - number_of_frames,
                                                  endIndex: currentIndex)
                            case .delete:
                                self.deleteFromFrames(startIndex: currentIndex - number_of_frames,
                                                      endIndex: currentIndex)
                            case .paintOverlaps:
                                self.updateOverlappersInFrames(shouldPaint: true,
                                                               startIndex: currentIndex - number_of_frames,
                                                               endIndex: currentIndex)

                           case .clearOverlaps:
                                self.updateOverlappersInFrames(shouldPaint: false,
                                                               startIndex: currentIndex - number_of_frames,
                                                               endIndex: currentIndex)
                            }
                            
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

    private func deleteFromFrames(startIndex: Int = 0, endIndex: Int? = nil) {
        let end = endIndex ?? frames.count
        let frames = self.frames
        let currentIndex = currentIndex
        if let selectionStart = selectionStart,
           let selectionEnd = selectionEnd
        {
            for frameView in frames {
                if frameView.frameIndex >= startIndex,
                   frameView.frameIndex <= end
                {
                    let gestureBounds = frameView.deleteOutliers(between: selectionStart,
                                                             and: selectionEnd)

                    if let frame = frameView.frame {
                        Task.detached(priority: .userInitiated) {
                            do {
                                try await frame.deleteOutliers(in: gestureBounds)
                                // save outlier paintability changes here
                                await frame.writeOutliersBinary()
                            } catch {
                                // XXX handle errors here better
                                Log.e("failed to delete outliers: \(error)")
                            }
                            if currentIndex == frame.frameIndex {
                                Task {
                                    await MainActor.run {
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

    private func updateFrames(shouldPaint: Bool,
                              startIndex: Int = 0,
                              endIndex: Int? = nil)
    {
        let end = endIndex ?? frames.count
        let frames: [FrameViewModel] = frames
        let currentIndex = currentIndex
        Log.w("updateFrames(shouldPaint: \(shouldPaint), startIndex: \(startIndex), endIndex: \(endIndex)")
        if let selectionStart = selectionStart,
           let selectionEnd = selectionEnd
        {
            for frameView in frames {
                if frameView.frameIndex >= startIndex,
                   frameView.frameIndex <= end,
                   let frame = frameView.frame 
                {
                    let new_value = shouldPaint
                    Task {
                        await frame.userSelectAllOutliers(toShouldPaint: new_value,
                                                          between: selectionStart,
                                                          and: selectionEnd)
                        // save outlier paintability changes here
                        await frame.writeOutliersBinary()

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

    private func updateOverlappersInFrames(shouldPaint: Bool,
                                           startIndex: Int = 0,
                                           endIndex: Int? = nil) 
    {
        let end = endIndex ?? frames.count
        let frames: [FrameViewModel] = frames
        let currentIndex = currentIndex

        Log.w("updateFrames(shouldPaint: \(shouldPaint), startIndex: \(startIndex), endIndex: \(endIndex)")
        if let selectionStart = selectionStart,
           let selectionEnd = selectionEnd 
        {
            for frameView in frames {
                if frameView.frameIndex >= startIndex,
                   frameView.frameIndex <= end
                {
                    if let frame = frameView.frame {
                        Task {
                            let new_value = shouldPaint
                            await frame.foreachOutlierGroupAsync(between: selectionStart,
                                                                 and: selectionEnd)
                            { group in
                                await frame.userSelectAllOutliers(toShouldPaint: new_value,
                                                                  overlapping: group)

                                return .continue
                            }
                            // save outlier paintability changes here
                            await frame.writeOutliersBinary()
                            
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

