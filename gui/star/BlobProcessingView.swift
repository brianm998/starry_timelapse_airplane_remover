import SwiftUI
import StarCore
import logging


struct BlobProcessingView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @State var detectionType: DetectionType? = nil
    
    var body: some View {
        @Bindable var viewModel = viewModel
        
        VStack(alignment: .leading) {
            if let viewModel = viewModel.imageSequence {
                self.mainView
            } else {
                VStack {
                    Text("No Image sequence loaded.")
                    Text("Load an image sequence in the main star window to see and edit blob processing steps here")
                }
            }
        }
          .navigationTitle("Star Blob Processing")
          .onAppear {
              Task.detached {
                  await constants.didChange() { detectionType in
                      Task { @MainActor in
                          self.detectionType = detectionType
                      }
                  }
              }
          }
    }

    var mainView: some View {
        VStack(alignment: .leading) {
            Text("Blob Processing Steps")

            if let detectionType {
                Text("Currently using \(detectionType.rawValue) detection type")
                /*
                 read list of steps from processor, and show them to the user in a
                 scrollable list
                 */
                ScrollView {
                    VStack(alignment: .leading) {
                        VStack(alignment: .leading) {
                            Text("Setup")
                              .foregroundColor(.blue)
                            Text("use the subtraction and original image for this frame to find an initial set of blobs")
                        }
                          .padding(10)
                          .background(.gray)
                          .padding(1)
                        
                        VStack(alignment: .leading) {
                            Text("Find Blobs")
                              .foregroundColor(.blue)
                            Text("""
                                   Detect blobs of difference in brightness in the subtraction array
                                   airplanes show up as lines or dots in a line
                                   because the image subtracted from this frame had the sky aligned,
                                   the ground may get moved, and therefore may contain blobs as well.
                                   """)
                        }
                          .padding(10)
                          .background(.gray)
                          .padding(1)

                        ForEach(detectionType.blobProcessor.steps, id: \.self) { step in
                            switch step {
                            case .process(let functionType):
                                processView(functionType)

                            case .smallBlobRemover(let args):
                                smallBlobRemoverView(args)

                            case .smallDimBlobRemover(let args):
                                smallDimBlobRemoverView(args)

                            case .blobDupeCheck(let step):
                                blobDupeCheckView(step)

                            case .lineSplit(let args):
                                lineSplitView(args)

                            case .borderBrightnessLessThan(let amount, let medianIntensityFloor):
                                borderBrightnessLessThanView(amount, medianIntensityFloor: medianIntensityFloor)

                            case .linearBlobConnector(let args):
                                linearBlobConnectorView(args)

                            case .blobLineTrim(let args):
                                blobLineTrimView(args)

                            case .isolatedBlobRemover(let args):
                                isolatedBlobRemoverView(args)

                            case .disconnectedBlobRemover(let args):
                                disconnectedBlobRemoverView(args)

                            case .dimIsolatedBlobRemover(let args):
                                dimIsolatedBlobRemoverView(args)
                                
                            case .save(let imageType):
                                saveView(imageType)

                            case .frameState(let processingState):
                                frameStateView(processingState)

                            case .removeReallyBigBlobsWithSmallDimBunches(let args):
                                removeReallyBigBlobsWithSmallDimBunchesView(args)
                            }
                        }
                          .padding(10)
                          .background(.gray)
                          .padding(1)
                    }
                }
            }
        }
    }

    private func processView(_ blobFunctionType: BlobFunctionType) -> some View {
        VStack(alignment: .leading) {
            switch blobFunctionType {
            case .trimWithConstants:
                Text("Trim with Constants")
                  .foregroundColor(.blue)
                Text("Trims with constants")
            case .applyUserSlices:
                Text("Apply User Slices")
                  .foregroundColor(.blue)
                Text("Apply any existing user slices to blobs")
            }
        }
    }

    private func smallBlobRemoverView(_ args: SmallBlobRemover.Args) -> some View {
        stepView(title: "Small Blob Remover",
                 description: "gets rid of dimmer blobs off by themselves",
                 args: args,
                 array: SmallBlobRemover.Args.ArgType.allCases)
    }

    private func smallDimBlobRemoverView(_ args: SmallDimBlobRemover.Args) -> some View {
        stepView(title: "Small Dim Blob Remover",
                 description: "gets rid of dimmer blobs off by themselves",
                 args: args,
                 array: SmallDimBlobRemover.Args.ArgType.allCases)
    }

    private func blobDupeCheckView(_ step: String) -> some View {
        VStack(alignment: .leading) {
            Text("Blob Dupe Check")
              .foregroundColor(.blue)
            Text("look for duplicate blobs, and log them as step \(step) if any are found")
        }
    }

    private func lineSplitView(_ args: BlobLineSplitter.Args) -> some View {
        stepView(title: "Linear Blob Connector",
                 description: "gets rid of small blobs by themselves in nowhere",
                 args: args,
                 array: BlobLineSplitter.Args.ArgType.allCases)
    }

    private func borderBrightnessLessThanView(_ amount: Double, medianIntensityFloor: UInt16) -> some View {
        let amountStr = String(format: "%.2f", amount)
        let medianIntensityStr = String(format: "%d", Int(medianIntensityFloor))
        return VStack(alignment: .leading) {
            Text("Border Brightness Less Than View Brightness")
              .foregroundColor(.blue)
            Text("This step only keeps blobs that have either a border brightness level vs the original image of \(amountStr) or a median intensity of \(medianIntensityStr)")
        }
    }

    private func linearBlobConnectorView(_ args: LinearBlobConnector.Args) -> some View {
        let description = "This step recurses on finding nearby blobs to find groups of neighbors in a set.\nIt then tries to combine some of them into a line (if we get a good enough line)"
        return stepView(title: "Linear Blob Connector",
                        description: description,
                        args: args,
                        array: LinearBlobConnector.Args.ArgType.allCases)
    }

    private func blobLineTrimView(_ args: BlobLineTrim.Args) -> some View {
        stepView(title: "Blob Line Trim",
                 description: "trim pixels that are too far from a blobs's line",
                 args: args,
                 array: BlobLineTrim.Args.ArgType.allCases)
    }

    private func isolatedBlobRemoverView(_ args: IsolatedBlobRemover.Args) -> some View {
        stepView(title: "Isolated Blob Remover",
                 description: "gets rid of small blobs by themselves in nowhere",
                 args: args,
                 array: IsolatedBlobRemover.Args.ArgType.allCases)
    }

    private func disconnectedBlobRemoverView(_ args: DisconnectedBlobRemover.Args) -> some View {
        let description = "recurse on finding nearby blobs to isolate groups of neighbors as a set\nuse the size of the neighbor set to determine if we keep a blob or not"

        return stepView(title: "Disconnected Blob Remover",
                 description: description,
                 args: args,
                 array: DisconnectedBlobRemover.Args.ArgType.allCases)
    }

    private func dimIsolatedBlobRemoverView(_ args: DimIsolatedBlobRemover.Args) -> some View {
        stepView(title: "Dim Isolated Blob Remover",
                 description: "gets rid of dimmer blobs off by themselves",
                 args: args,
                 array: DimIsolatedBlobRemover.Args.ArgType.allCases)
    }

    private func saveView(_ imageType: FrameViewMode) -> some View {
        VStack(alignment: .leading) {
            Text("Save Image")
              .foregroundColor(.blue)
            Text("of type \(imageType.longName)")
        }
    }

    private func frameStateView(_ processingState: FrameProcessingState) -> some View {
        VStack(alignment: .leading) {
            Text("Set Frame Processing State")
              .foregroundColor(.blue)
            Text(processingState.message)
        }
    }

    private func removeReallyBigBlobsWithSmallDimBunchesView(_ args: RemoveReallyBigBlobsWithSmallDimBunches.Args) -> some View {
        stepView(title: "Remove Really Big Blobs With Small Dim Bunches",
                 description: "Trims dimmer pixels out of large cloud like blobs.",
                 args: args,
                 array: RemoveReallyBigBlobsWithSmallDimBunches.Args.ArgType.allCases)
    }
    
    private func stepView<T: Hashable>(title: String,
                                       description: String,
                                       args: any Argable<T>,
                                       array: [T]) -> some View
    {
        VStack(alignment: .leading) {
            Text(title)
              .foregroundColor(.blue)
            Text(description)
            Text("Arguments:")
            Grid(alignment: .leading) {
                GridRow {
                    Text("Name")
                      .foregroundColor(.white)
                    Text("Value")
                      .foregroundColor(.white)
                    Text("Description")
                      .foregroundColor(.white)
                }

                ForEach(array, id: \.self) { argType in
                    GridRow {
                        Text("\(argType)")
                        if let value = args.value(for: argType) {
                            if args.isInteger(argType) {
                                Text(String(format: "%d", Int(value)))
                            } else {
                                Text(String(format: "%.2f", value))
                            }
                        } else {
                            Group { }
                        }
                        Text(args.description(for: argType))
                    }
                }
            }
        }
    }
}
