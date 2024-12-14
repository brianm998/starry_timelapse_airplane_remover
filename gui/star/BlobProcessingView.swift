import SwiftUI
import StarCore
import logging


struct BlobProcessingView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @State var detectionType: DetectionType? = nil
    
    var body: some View {
        @Bindable var viewModel = viewModel
        
        Group {
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
        VStack {
            Text("Blob Processing Steps")

            if let detectionType {
                Text("Currently using \(detectionType.rawValue) detection type")
                Text("Before running these steps, each frame will first have an aligned neibnor image subtracted from it, and then an initial blob detection phase will be run.  XXX Expose constants used to allow tweaking XXX") 
                /*
                 read list of steps from processor, and show them to the user in a
                 scrollable list
                 
                 */
                ScrollView {
                    ForEach(detectionType.blobProcessor.steps, id: \.self) { step in
                        Group {
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

                            case .borderBrightnessLessThan(let amount):
                                borderBrightnessLessThanView(amount)

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
                            }
                        }
                          .background(.gray)
                          .padding(1)
                    }
                }
            }
        }
    }

    private func processView(_ blobFunctionType: BlobFunctionType) -> some View {
        Text("processView")
    }

    private func smallBlobRemoverView(_ args: SmallBlobRemover.Args) -> some View {
        Text("smallBlobRemoverView")
    }

    private func smallDimBlobRemoverView(_ args: SmallDimBlobRemover.Args) -> some View {
        Text("smallDimBlobRemoverView")
    }

    private func blobDupeCheckView(_ step: String) -> some View {
        Text("blobDupeCheckView")
    }

    private func lineSplitView(_ args: BlobLineSplitter.Args) -> some View {
        Text("lineSplitView")
    }

    private func borderBrightnessLessThanView(_ amount: Double) -> some View {
        Text("borderBrightnessLessThanView")
    }

    private func linearBlobConnectorView(_ args: LinearBlobConnector.Args) -> some View {
        VStack(alignment: .leading) {
            Text("Linear Blob Connector")
            Text("This step recurses on finding nearby blobs to find groups of neighbors in a set.\nIt then tries to combine some of them into a line (if we get a good enough line)")
            Text("Arguments:")
            Grid(alignment: .leading) {
                GridRow {
                    Text("Name")
                    Text("Value")
                    Text("Description")
                }
                ForEach(LinearBlobConnector.Args.ArgType.allCases, id: \.self) { argType in
                    GridRow {
                        Text("\(argType)")
                        if let value = args.value(for: argType) {
                            Text("\(value)")
                        } else {
                            Group { }
                        }
                        Text(args.description(for: argType))
                    }
                }
            }
        }
    }

    private func blobLineTrimView(_ args: BlobLineTrim.Args) -> some View {
        Text("blobLineTrimView")
    }

    private func isolatedBlobRemoverView(_ args: IsolatedBlobRemover.Args) -> some View {
        Text("isolatedBlobRemoverView")
    }

    private func disconnectedBlobRemoverView(_ args: DisconnectedBlobRemover.Args) -> some View {
        Text("disconnectedBlobRemoverView")
    }

    private func dimIsolatedBlobRemoverView(_ args: DimIsolatedBlobRemover.Args) -> some View {
        Text("dimIsolatedBlobRemoverView")
    }

    private func saveView(_ imageType: FrameViewMode) -> some View {
        Text("Save image of \(imageType.longName)")
    }

    private func frameStateView(_ processingState: FrameProcessingState) -> some View {
        Text("Set Frame Processing State to \(processingState.message)")
    }
}
