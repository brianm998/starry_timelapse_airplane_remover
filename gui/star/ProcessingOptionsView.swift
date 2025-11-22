import AppKit
import SwiftUI
import StarCore
import logging

// view that shows the user what options there are for processing the image sequence
struct ProcessingOptionsView: View {

    @Binding var isVisible: Bool
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @FocusState private var focusedField: FocusedField?

    var body: some View {
        @Bindable var viewModel = viewModel
        return HStack {
            Space(width: 20)
            VStack {
                Space(height: 20)
                let unprocessed = viewModel.frameStateMap[.unprocessed]?.count ?? 0
                let horizonCount = viewModel.frameStateMap[.horizonDetected]?.count ?? 0

                Text("Image Sequence Processing Options")
                  .font(.title)

                Space(height: 20)

                Grid {
                    self.cuncurrentProcessingLimitView
                    Divider()
                    self.neighborFrameCountView
                    Divider()
                    self.pixelThresholdView
                    Divider()
                    self.processingModeView
                }
                
                Text(viewModel.detectionType.blobProcessor.description)
                  .lineLimit(nil)
                  .fixedSize(horizontal: false, vertical: true)
                
                Space(height: 20)

                HStack {
                    Spacer()
                    Button() {
                        self.isVisible = false
                    } label: {
                        Text("Cancel")
                    }
                    Space(width: 10)
                    Button() {
                        viewModel.processFrames(from: 0)
                        self.isVisible = false
                    } label: {
                        Text("Process \(unprocessed + horizonCount) frames")
                    }
                      .buttonStyle(.borderedProminent)
                      .tint(.blue)
                    Space(width: 20)
                }
                Space(height: 20)
            }
            Space(width: 20)
        }
    }

    private var cuncurrentProcessingLimitView: some View {
        GridRow {
            HStack {
                Spacer()
                EditableNumberOfFramesToProcessConcurrentlyView(
                  focusedField: $focusedField,
                  textColor: .black,
                  alwaysOpen: true
                )
            }
            Text("How many frames do we process concurrently?  Number of CPUs is likely too high, as much of the processing has been parallized.  2-5 is a good number here.")
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
        }

    }

    private var neighborFrameCountView: some View {
        GridRow {
            HStack {
                Spacer()
                EditableNumberOfNeighborFrames(
                  focusedField: $focusedField,
                  textColor: .black,
                  alwaysOpen: true
                )
            }
            Text("During star alignment, we use this number for aligning and processing neighboring frames.  Lowest possible number is 1, which does work in most cases.  However, 8 is a better option for general use, as it covers the case where neighboring frames have bad pixels at the same location.")
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
        }
    }


    private var pixelThresholdView: some View {
        GridRow {
            HStack {
                Spacer()
                EditablePixelThresholdView(
                  focusedField: $focusedField,
                  textColor: .black,
                  alwaysOpen: true
                )
            }
            Text("The pixel threshold is a factor used to weed out pixels that are statistically too much brigher than other aligned pixels at the same location.  Lower values like 0.5 get rid of more brighter pixels, higher values like 2.0 will allow more brighter pixels to pass through.  Used for both the subtraction image and for calculating what pixel values to replace airplanes with.")
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
        }
       
    }

    private var processingModeView: some View {
        @Bindable var viewModel = viewModel
        return GridRow {
            HStack {
                Text("Processing Mode:")
                Picker("", selection: $viewModel.detectionType) {
                    ForEach(DetectionType.allCases, id: \.self) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                  .frame(maxWidth: 120)
                  .onChange(of: viewModel.detectionType) {
                      Task {
                          await constants.set(detectionType: viewModel.detectionType)

                          // stick it in user preferences
                          self.viewModel.userPreferences.processingType = viewModel.detectionType
                      }
                  }
            }
            Text("Star supports a number of different processing modes.  On one end is faster processing and less accuracy, on the other end is slower processing and more touch up work.")
              .lineLimit(nil)
              .fixedSize(horizontal: false, vertical: true)
        }
    }
}
