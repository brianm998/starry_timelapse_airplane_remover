import SwiftUI
import StarCore
import logging


struct BlobProcessingView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @State var detectionType: DetectionType? = nil

    @State var detectionTypeToCopyFrom: DetectionType? = nil
    @State var stepsLoaded = false
    
    var body: some View {
        @Bindable var viewModel = viewModel
        
        VStack(alignment: .leading) {
          if viewModel.imageSequence != nil {
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
                  let detectionType = await constants.getDetectionType()
                  await MainActor.run {
                      self.detectionType = detectionType
                  }
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

            if let detectionType,
               let imageSequence = viewModel.imageSequence
            {
                @Bindable var imageSequence = imageSequence
                
                Picker("Current Detection Type", selection: $imageSequence.detectionType) {
                    ForEach(DetectionType.allCases, id: \.self) { value in
                        Text(value.rawValue).tag(value)
                    }
                }
                  .frame(maxWidth: 240)
                  .onChange(of: imageSequence.detectionType) {
                      Task {
                          await constants.set(detectionType: imageSequence.detectionType)
                      }
                  }

                switch imageSequence.detectionType {
                case .mild:
                    Text("""
                           The Mild detection type is fastest, and detects a small number of blobs.
                           It will get the vast majority of large bright streaks out of the video,
                           smaller and dimmer signal may not be found.
                           """)
                case .strong:
                    Text("""
                           The Strong detection type has been tuned to find more of the signal we want,
                           at the expense of ending up with more noise.  
                           The signal that may still not be noticed here includes when an airplane
                           is seen as a series of small dim dots in the image.
                           """)
                case .excessive:
                    Text("""
                           The Excessive detection type can produce an excessive amount of blob data.
                           This generally will include any signal that you want to mask out,
                           but usually also includes a lot more noise.  This will slow down processing,
                           and make further analysis slower as well.  It can be used on a frame by frame
                           basis to get that small few bits of signal that the other detection types may miss.
                           """)
                case .custom:
//                    Text("replace these steps with one of the following")
//                    self.customCopyPicker

                    /*
                     XXX this replace is broken, as the values do not change upon replace :(
                     */
                    
                    Text("""
                           A custom detection type can be modified by the user at runtime to see what happens when processing one or more frames.
                           It will typically start as a copy of another detection type.
                           """)
                }

                if detectionType.blobProcessor.steps.count == 0,
                   !stepsLoaded
                {
                    Text("You have loaded an empty set of steps")
                      .foregroundColor(.white)
                      .font(.largeTitle)
                    
                    Text("Please choose an existing detection type to start from") 

                    self.customCopyPicker
                } else {
                    
                    
                    /*
                     read list of steps from processor, and show them to the user in a
                     scrollable list
                     */
                    ScrollView {
                        VStack(alignment: .leading) {
                            VStack(alignment: .leading) {
                                Text("Setup")
                                  .foregroundColor(.white)
                                  .font(.largeTitle)
                                Text("To begin processing each frame we must first:")
                                Text(" - Create a star aligned image")
                                Text(" - Subtract the star aligned image from the frame being processed")
                                Text("Both of these can be loaded from file if they are available from before.")
                                Text("There are no configurable parameters here")
                            }
                              .padding(10)
                              .background(.gray)
                              .padding(1)
                            
                            //ForEach(detectionType.blobProcessor.steps, id: \.self) { step in
                            //print("detectionType.blobProcessor.steps.count \(detectionType.blobProcessor.steps.count)")
                            
                            ForEach(detectionType.blobProcessor.steps.indices) { stepIndex in
                                if stepIndex >= detectionType.blobProcessor.steps.count {
                                    Text("WRONG INDEX: \(stepIndex) >= \(detectionType.blobProcessor.steps.count)")
                                } else {
                                    let step = detectionType.blobProcessor.steps[stepIndex]
                                    switch step {
                                    case .findBlobs(let args):
                                        findBlobsView(args, stepIndex: stepIndex)
                                        
                                    case .applyUserSlices:
                                        applyUserSlicesView()

                                    case .smallBlobRemover(let args):
                                        smallBlobRemoverView(args, stepIndex: stepIndex)

                                    case .smallDimBlobRemover(let args):
                                        smallDimBlobRemoverView(args, stepIndex: stepIndex)

                                    case .blobDupeCheck(let step):
                                        blobDupeCheckView(step)

                                    case .lineSplit(let args):
                                        lineSplitView(args, stepIndex: stepIndex)

                                    case .borderBrightnessBlobRemover(let args):
                                        borderBrightnessLessThanView(args, stepIndex: stepIndex)

                                    case .linearBlobConnector(let args):
                                        linearBlobConnectorView(args, stepIndex: stepIndex)

                                    case .blobLineTrim(let args):
                                        blobLineTrimView(args, stepIndex: stepIndex)

                                    case .isolatedBlobRemover(let args):
                                        isolatedBlobRemoverView(args, stepIndex: stepIndex)

                                    case .disconnectedBlobRemover(let args):
                                        disconnectedBlobRemoverView(args, stepIndex: stepIndex)

                                    case .dimIsolatedBlobRemover(let args):
                                        dimIsolatedBlobRemoverView(args, stepIndex: stepIndex)
                                        
                                    case .save(let imageType):
                                        saveView(imageType)

                                    case .frameState(let processingState):
                                        frameStateView(processingState)

                                    case .removeReallyBigBlobsWithSmallDimBunches(let args):
                                        removeReallyBigBlobsWithSmallDimBunchesView(args, stepIndex: stepIndex)

                                    case .trimWithConstants(let args):
                                        trimWithConstantsView(args, stepIndex: stepIndex)
                                    }
                                }
                            }
                              .padding(10)
                              .background(.gray)
                              .padding(1)

                            VStack(alignment: .leading) {
                                Text("Blob Processing Complete")
                                  .foregroundColor(.white)
                                  .font(.largeTitle)
                                Text("""
                                       At this point, the blobs are promoted to outlier groups.
                                       This allows both manual and machine learning classification
                                       of the remaning data before we use this information to
                                       potentially modify certain pixels in each frame
                                       """)
                            }
                              .padding(10)
                              .background(.gray)
                              .padding(1)
                            
                        }
                    }
                }
            }
        }
    }

    var customCopyPicker: some View {
        Picker("", selection: $detectionTypeToCopyFrom) {
            ForEach(DetectionType.allCases, id: \.self) { value in
                if value == .custom {
                    Group { }
                } else {
                    Text(value.rawValue).tag(value)
                }
            }
        }
          .frame(maxWidth: 240)
          .onChange(of: detectionTypeToCopyFrom) {
              if let detectionTypeToCopyFrom,
                 let detectionType,
                 let customProcessor = detectionType.blobProcessor as? CustomBlobProcessor
              {
                  print("FUCKING DO SHIT HERE \(detectionTypeToCopyFrom)")
//                  self.valueMap = [:]
                  customProcessor.copySteps(from: detectionTypeToCopyFrom.blobProcessor)
                  stepsLoaded = true
              }
          }
        
    }

    private func applyUserSlicesView() -> some View {
        VStack(alignment: .leading) {
            Text("Apply User Slices")
              .foregroundColor(.white)
              .font(.title2)
            Text("Apply any existing user slices to blobs")
        }
    }

    private func findBlobsView(_ args: BlobFinder.Args,
                               stepIndex: Int) -> some View
    {
        stepView(title: "Initial Blob Detection",
                 description: """
                   This initial step analyses both the original frame image and the subtraction
                   image to try to find neighboring groups (blobs) of pixels that are brighter
                   in the subtraction image by the given criteria.
                   After this step, the blobs found here can be processed further so that we can
                   separate signal from noise.
                   The signal we want is from transiently brighter streaks coming from airplanes and satellites.
                   Noise falls into many categories, as it's anything that we don't want to modify.
                   This can be caused by moving clouds, imperfect star alignment,
                   ground being rotated due to star alignment, meteors,
                   and a number of other factores.   
                   """,
                 args: args,
                 array: BlobFinder.Args.ArgType.allCases,
                 stepIndex: stepIndex,
                 showDisableButton: false)
    }
    
    private func smallBlobRemoverView(_ args: SmallBlobRemover.Args,
                                      stepIndex: Int) -> some View
    {
        stepView(title: "Small Blob Remover",
                 description: "gets rid of dimmer blobs off by themselves",
                 args: args,
                 array: SmallBlobRemover.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    private func smallDimBlobRemoverView(_ args: SmallDimBlobRemover.Args,
                                         stepIndex: Int) -> some View
    {
        stepView(title: "Small Dim Blob Remover",
                 description: "gets rid of dimmer blobs off by themselves",
                 args: args,
                 array: SmallDimBlobRemover.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    private func blobDupeCheckView(_ step: String) -> some View {
        VStack(alignment: .leading) {
            Text("Blob Dupe Check")
              .foregroundColor(.white)
              .font(.title2)
            Text("look for duplicate blobs, and log them as step \(step) if any are found")
        }
    }

    private func lineSplitView(_ args: BlobLineSplitter.Args,
                               stepIndex: Int) -> some View
    {
        stepView(title: "Line Splitter",
                 description: "tries to split up blobs into multiple lines if possible",
                 args: args,
                 array: BlobLineSplitter.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    private func borderBrightnessLessThanView(_ args: BorderBrightnessBlobRemover.Args,
                                              stepIndex: Int) -> some View
    {
        stepView(title: "Border Brightness Less Than View Brightness",
                 description: "This steps only keeps blobs that meet one or both of the following criteria.",
                 args: args,
                 array: BorderBrightnessBlobRemover.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    private func linearBlobConnectorView(_ args: LinearBlobConnector.Args,
                                         stepIndex: Int) -> some View
    {
        let description = "This step recurses on finding nearby blobs to find groups of neighbors in a set.\nIt then tries to combine some of them into a line (if we get a good enough line)"
        return stepView(title: "Linear Blob Connector",
                        description: description,
                        args: args,
                        array: LinearBlobConnector.Args.ArgType.allCases,
                        stepIndex: stepIndex)
    }

    private func blobLineTrimView(_ args: BlobLineTrim.Args,
                                  stepIndex: Int) -> some View
    {
        stepView(title: "Blob Line Trim",
                 description: "trim pixels that are too far from a blobs's line",
                 args: args,
                 array: BlobLineTrim.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    private func isolatedBlobRemoverView(_ args: IsolatedBlobRemover.Args,
                                         stepIndex: Int) -> some View
    {
        stepView(title: "Isolated Blob Remover",
                 description: "gets rid of small blobs by themselves in nowhere",
                 args: args,
                 array: IsolatedBlobRemover.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    private func disconnectedBlobRemoverView(_ args: DisconnectedBlobRemover.Args,
                                             stepIndex: Int) -> some View
    {
        let description = "recurse on finding nearby blobs to isolate groups of neighbors as a set\nuse the size of the neighbor set to determine if we keep a blob or not"

        return stepView(title: "Disconnected Blob Remover",
                        description: description,
                        args: args,
                        array: DisconnectedBlobRemover.Args.ArgType.allCases,
                        stepIndex: stepIndex)
    }

    private func dimIsolatedBlobRemoverView(_ args: DimIsolatedBlobRemover.Args,
                                            stepIndex: Int) -> some View
    {
        stepView(title: "Dim Isolated Blob Remover",
                 description: "gets rid of dimmer blobs off by themselves",
                 args: args,
                 array: DimIsolatedBlobRemover.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    private func saveView(_ imageType: FrameViewMode) -> some View {
      HStack(alignment: .firstTextBaseline) {
            Text("Save Image")
              .foregroundColor(.white)
              .font(.title2)
            Text(imageType.longName)
        }
    }

    private func frameStateView(_ processingState: FrameProcessingState) -> some View {
      HStack(alignment: .firstTextBaseline) {
            Text("Set Frame Processing State")
              .foregroundColor(.white)
              .font(.title2)
            Text(processingState.message)
        }
    }

    private func removeReallyBigBlobsWithSmallDimBunchesView(_ args: RemoveReallyBigBlobsWithSmallDimBunches.Args,
                                                             stepIndex: Int) -> some View
    {
        stepView(title: "Remove Really Big Blobs With Small Dim Bunches",
                 description: "Trims dimmer pixels out of large cloud like blobs.",
                 args: args,
                 array: RemoveReallyBigBlobsWithSmallDimBunches.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }


    private func trimWithConstantsView(_ args: BlobTrimmerWithConstants.Args,
                                       stepIndex: Int) -> some View
    {
        stepView(title: "Blob Trimmer with Constants",
                 description: "Removes blobs that don't fit the given criteria",
                 args: args,
                 array: BlobTrimmerWithConstants.Args.ArgType.allCases,
                 stepIndex: stepIndex)
    }

    // keeps track of all text field editable values as strings
    @State private var stringValueMap: [AnyHashable: String] = [:]

    private func stringBinding(for value: AnyHashable) -> Binding<String> {
        .init(get: { self.stringValueMap[value, default: ""] },
              set: { self.stringValueMap[value] = $0 })
    }
    
    // keeps track of all text field editable values as strings
    @State private var boolValueMap: [AnyHashable: Bool] = [:]

    private func boolBinding(for value: AnyHashable) -> Binding<Bool> {
        .init(get: { self.boolValueMap[value, default: false] },
              set: { self.boolValueMap[value] = $0 })
    }

    private func stepView<T: Hashable>(title: String,
                                       description: String,
                                       args: any Argable<T>,
                                       array: [T],
                                       stepIndex: Int,
                                       showDisableButton: Bool = true) -> some View
    {
        ZStack {
            VStack(alignment: .leading) {
                Text(title)
                  .foregroundColor(.white)
                  .font(.largeTitle)
                Text(description)
                Spacer()
                  .frame(maxHeight: 10)
                Text("Parameters which can affect how this step operates:")
                Grid(alignment: .topLeading) {
                    GridRow {
                        Text("Name")
                          .foregroundColor(.white)
                        Text("Value")
                          .foregroundColor(.white)
                        Text("Description")
                          .foregroundColor(.white)
                    }
                      .padding(.vertical, 2)

                    //ForEach(array, id: \.self) { argType in
                    ForEach(array.indices) { index in // index of paramters in list
                        self.stepRowView(args, argType: array[index], stepIndex: stepIndex)
                          .padding(.vertical, 2)
                    }
                }
            }
              .layoutPriority(10)
            
            if detectionType == .custom,
               showDisableButton
            {
                HStack(alignment: .top) {
                    Spacer()
                      .layoutPriority(0)
                    VStack(alignment: .trailing) {
                        Spacer()
                          .frame(maxHeight: 10)
                        
                        Toggle("Disable", isOn: boolBinding(for: stepIndex))
                          .toggleStyle(.switch)
                          .onChange(of: boolBinding(for: stepIndex).wrappedValue) { _, newValue in
                              if let customProcessor = DetectionType.custom.blobProcessor as? CustomBlobProcessor
                              {
                                  customProcessor.shouldDisable(args, newValue, stepIndex)
                              }
                          }
                        
                        Spacer()
                    }
                }
            }
        }
    }

    // view for each parameter for this step, as a GridRow with three elements
    private func stepRowView<T: Hashable>(_ args: any Argable<T>,
                                          argType: T,
                                          stepIndex: Int) -> some View
    {
        GridRow {
            Text("\(argType)")

            let value = args.value(for: argType)
            
            if detectionType == .custom {
                // editable text fields

                if args.isInteger(argType) {
                    TextField("", text: stringBinding(for: argType))
                      .frame(maxWidth: 80)
                      .onAppear {
                          if let value {
                              stringBinding(for: argType).wrappedValue = String(format: "%d", Int(value))
                          }
                      }
                      .onSubmit {
                          if let intValue = Int(stringBinding(for: argType).wrappedValue),
                             let customProcessor = DetectionType.custom.blobProcessor as? CustomBlobProcessor
                          { 
                              customProcessor.intUpdate(args, argType, intValue, stepIndex)
                          }
                      }
                    
                } else {
                    TextField("", // not integer (real number)
                              text: stringBinding(for: argType))
                      .frame(maxWidth: 80)
                      .onAppear {
                          if let value {
                              stringBinding(for: argType).wrappedValue = String(format: "%.2f", value)
                          }
                      }
                      .onSubmit {
                          if let doubleValue = Double(stringBinding(for: argType).wrappedValue),
                             let customProcessor = DetectionType.custom.blobProcessor as? CustomBlobProcessor
                          {
                              customProcessor.doubleUpdate(args, argType, doubleValue, stepIndex)
                          }
                      }
                }
            } else {
                // read only view
                if let value {
                    if args.isInteger(argType) {
                        Text(String(format: "%d", Int(value)))
                    } else {
                        Text(String(format: "%.2f", value))
                    }
                } else {
                    Text("")
                }
            }
            Text(args.description(for: argType))

        }
    }
}
