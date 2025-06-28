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

public enum MultiSelectionRemovalType: String, Equatable, CaseIterable {
    case remove
    case keep
    case removeOverlaps
    case keepOverlaps

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
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
            Text("Change removing in the selected area across more than one frame.")

            Picker("", selection: $multiSelectionRemovalType) {
                ForEach(MultiSelectionRemovalType.allCases, id: \.self) { value in
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
                switch multiSelectionRemovalType {
                case .remove:
                    Text("Remove outliers in this area in all \(frames.count) frames")
                case .keep:
                    Text("Keep outliers in this area in all \(frames.count) frames")
                case .removeOverlaps:
                    Text("Remove overlaying outliers in this area in all \(frames.count) frames")
                case .keepOverlaps:
                    Text("Keep overlaying outliers in this area in all \(frames.count) frames")
                }
                
            case .allAfter:
                let numFrames = frames.count - currentIndex + 1
                switch multiSelectionRemovalType {
                case .remove:
                    Text("Remove outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .keep:
                    Text("Keep outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .removeOverlaps:
                    Text("Remove overlaying outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")
                case .keepOverlaps:
                    Text("Keep overlaying outliers in this area in \(numFrames) frames from frame \(currentIndex) to the end")

                }
                    
            case .allBefore:
                let numFrames = currentIndex + 1
                switch multiSelectionRemovalType {
                case .remove:
                    Text("Remove outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .keep:
                    Text("Keep outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .removeOverlaps:
                    Text("Remove overlaying outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
                case .keepOverlaps:
                    Text("Keep overlaying outliers in this area in \(numFrames) frames from the start ending at frame \(currentIndex)")
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
                    Button("Modify") {

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
                    Button("Modify") {

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
                            self.updateOverlappersInFrames(shouldRemove: true,
                                                           startIndex: 0,
                                                           endIndex: currentIndex)
                        }

                        self.isVisible = false
                    }
                case .someAfter:
                    HStack {
                        Button("Modify") {


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
                        Text("the next")
                        TextField("", value: $number_of_frames, format: .number)
                          .frame(maxWidth: 40)
                        Text("frames")
                    }
                case .someBefore:
                    HStack {
                        Button("Modify") {
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
                            try? await viewModel.render(frame: frame, now: false)
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
                                try? await viewModel.render(frame: frame, now: false)
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

