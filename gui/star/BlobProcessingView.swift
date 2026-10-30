import SwiftUI
import StarCore
import logging


struct BlobProcessingView: View {
    @Environment(ViewModel.self) var viewModel: ViewModel
    @State var detectionType: DetectionType? = nil

    @State var detectionTypeToCopyFrom: DetectionType? = nil
    @State var stepsLoaded = false
    @State var steps: [BlobProcessingType] = []
    
    var body: some View {
        @Bindable var viewModel = viewModel
        
        VStack(alignment: .leading) {
          if viewModel.imageSequence != nil {
                self.mainView
            } else {
                VStack {
                    Text(localized("ui.no_image_sequence_loaded"))
                    Text(localized("ui.load_an_image_sequence_in_the_main_star_2"))
                }
            }
        }
          .navigationTitle(localized("ui.star_blob_processing"))
          .onAppear {
              Task.detached {
                  let detectionType = await constants.getDetectionType()
                  await MainActor.run {
                      self.detectionType = detectionType
                      self.steps = detectionType.blobProcessor.steps
                  }
                  await constants.didChange() { detectionType in
                      Task { @MainActor in
                          self.detectionType = detectionType
                          self.steps = detectionType.blobProcessor.steps
                      }
                  }
              }
          }
    }

    var mainView: some View {
        VStack(alignment: .leading) {
            Text(localized("ui.blob_processing_steps"))

            if let imageSequence = viewModel.imageSequence {
                @Bindable var imageSequence = imageSequence
                
                Picker(localized("ui.current_detection_type"), selection: $imageSequence.detectionType) {
                    ForEach(DetectionType.allCases, id: \.self) { value in
                        Text(value.localizedName).tag(value)
                    }
                }
                  .frame(maxWidth: 240)
                  .onChange(of: imageSequence.detectionType) {
                      // The sequence's own config.json already has it (`detectionType`'s didSet); this is what the
                      // frames read it from, and the preference a new sequence starts with, as in the settings sheet
                      // and the Kotlin client.
                      let chosen = imageSequence.detectionType
                      Task {
                          await constants.set(detectionType: chosen)
                          viewModel.userPreferences.processingType = chosen
                      }
                  }

                // what the chosen detection type is
                Text(localized("ui.detection_type_desc.\(imageSequence.detectionType.rawValue)"))

                if steps.count == 0,
                   !stepsLoaded
                {
                    Text(localized("ui.you_have_loaded_an_empty_set_of_steps"))
                      .foregroundColor(.white)
                      .font(.largeTitle)
                    
                    Text(localized("ui.please_choose_an_existing_detection_type_to")) 

                    self.customCopyPicker
                } else {
                    
                    
                    /*
                     read list of steps from processor, and show them to the user in a
                     scrollable list
                     */
                    ScrollView {
                        VStack(alignment: .leading) {
                            VStack(alignment: .leading) {
                                Text(localized("ui.setup"))
                                  .foregroundColor(.white)
                                  .font(.largeTitle)
                                Text(localized("ui.to_begin_processing_each_frame_we_must_first"))
                                Text(localized("ui.create_a_star_aligned_image"))
                                Text(localized("ui.subtract_the_star_aligned_image_from_the"))
                                Text(localized("ui.both_of_these_can_be_loaded_from_file_if"))
                                Text(localized("ui.there_are_no_configurable_parameters_here"))
                            }
                              .padding(10)
                              .background(.gray)
                              .padding(1)
                            
                            
                            ForEach(Array(steps.enumerated()), id: \.element) { stepIndex, step in
                                HStack {
                                    switch step {
                                    case .compactBlobIds:
                                        compactBlobIdsView()
                                        
                                    case .findBlobs(let args):
                                        findBlobsView(args, stepIndex: stepIndex)

                                    case .applyUserSlices:
                                        applyUserSlicesView()

                                    case .smallBlobRemover(let args):
                                        smallBlobRemoverView(args, stepIndex: stepIndex)
                                        
                                    case .blobDupeCheck(let step):
                                        blobDupeCheckView(step)

                                    case .linearBlobConnector(let args):
                                        linearBlobConnectorView(args, stepIndex: stepIndex)

                                    case .linearBlobExtender(let args):
                                        linearBlobExtenderView(args, stepIndex: stepIndex)
                                        
                                    case .blobLineTrim(let args):
                                        blobLineTrimView(args, stepIndex: stepIndex)

                                    case .save(let imageType):
                                        saveView(imageType)

                                    case .frameState(let processingState):
                                        frameStateView(processingState)

                                    case .houghLineMatrixBlobConnector(let args):
                                        houghLineMatrixBlobConnectorView(args, stepIndex: stepIndex)
                                    }
                                }
                                  .background(.gray)
                                  .padding(1)
                            }

                            VStack(alignment: .leading) {
                                Text(localized("ui.blob_processing_complete"))
                                  .foregroundColor(.white)
                                  .font(.largeTitle)
                                Text(localized("ui.blob_processing_complete_desc"))
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
                    Text(value.localizedName).tag(value)
                }
            }
        }
          .frame(maxWidth: 240)
          .onChange(of: detectionTypeToCopyFrom) {
              if let detectionTypeToCopyFrom,
                 let detectionType,
                 let customProcessor = detectionType.blobProcessor as? CustomBlobProcessor
              {
                  customProcessor.copySteps(from: detectionTypeToCopyFrom.blobProcessor)
                  stepsLoaded = true
              }
          }
    }

    private func smallBlobRemoverView(_ args: SmallBlobRemover.Args,
                                      stepIndex: Int) -> some View
    {
        StepView(title: localized("ui.small_blob_remover"),
                 description: localized("ui.small_blob_remover_desc"),
                 args: args,
                 array: SmallBlobRemover.Args.ArgType.allCases,
                 stepIndex: stepIndex,
                 detectionType: $detectionType)
    }

    private func applyUserSlicesView() -> some View {
        VStack(alignment: .leading) {
            Text(localized("ui.apply_user_slices"))
              .foregroundColor(.white)
              .font(.title2)
            Text(localized("ui.apply_any_existing_user_slices_to_blobs"))
        }
          .padding(10)
    }

    private func compactBlobIdsView() -> some View {
        VStack(alignment: .leading) {
            Text(localized("ui.compact_blob_ids"))
              .foregroundColor(.white)
              .font(.title2)
            Text(localized("ui.re_id_blobs_to_free_up_id_space"))
        }
          .padding(10)
    }

    private func findBlobsView(_ args: BlobFinder.Args,
                               stepIndex: Int) -> some View
    {
        StepView(title: localized("ui.initial_blob_detection"),
                 description: localized("ui.initial_blob_detection_desc"),
                 args: args,
                 array: BlobFinder.Args.ArgType.allCases,
                 stepIndex: stepIndex,
                 detectionType: $detectionType,
                 showDisableButton: false)
    }
    
    private func blobDupeCheckView(_ step: String) -> some View {
        VStack(alignment: .leading) {
            Text(localized("ui.blob_dupe_check"))
              .foregroundColor(.white)
              .font(.title2)
            Text(localized("ui.duplicate_blob_step", step))
        }
          .padding(10)
    }

    private func linearBlobConnectorView(_ args: LinearBlobConnector.Args,
                                         stepIndex: Int) -> some View
    {
        let description = localized("ui.linear_blob_connector_desc")
        return StepView(title: localized("ui.linear_blob_connector"),
                        description: description,
                        args: args,
                        array: LinearBlobConnector.Args.ArgType.allCases,
                        stepIndex: stepIndex,
                       detectionType: $detectionType)
    }

    private func linearBlobExtenderView(_ args: LinearBlobExtender.Args,
                                         stepIndex: Int) -> some View
    {
        let description = localized("ui.linear_blob_extender_desc")
        return StepView(title: localized("ui.linear_blob_extender"),
                        description: description,
                        args: args,
                        array: LinearBlobExtender.Args.ArgType.allCases,
                        stepIndex: stepIndex,
                        detectionType: $detectionType)
    }

    private func blobLineTrimView(_ args: BlobLineTrim.Args,
                                  stepIndex: Int) -> some View
    {
        StepView(title: localized("ui.blob_line_trim"),
                 description: localized("ui.blob_line_trim_desc"),
                 args: args,
                 array: BlobLineTrim.Args.ArgType.allCases,
                 stepIndex: stepIndex,
                 detectionType: $detectionType)
    }

    private func saveView(_ imageType: FrameViewMode) -> some View {
      HStack(alignment: .firstTextBaseline) {
            Text(localized("ui.save_image"))
              .foregroundColor(.white)
              .font(.title2)
            Text(imageType.longName)
        }
        .padding(10)
    }

    private func frameStateView(_ processingState: FrameProcessingState) -> some View {
      HStack(alignment: .firstTextBaseline) {
            Text(localized("ui.set_frame_processing_state"))
              .foregroundColor(.white)
              .font(.title2)
            Text(processingState.message)
        }
        .padding(10)
    }

    private func houghLineMatrixBlobConnectorView(_ args: HoughLineMatrixBlobConnector.Args,
                                                  stepIndex: Int) -> some View
    {
        StepView(title: localized("ui.hough_line_matrix_blob_connector"),
                 description: localized("ui.hough_line_matrix_blob_connector_desc"),
                 args: args,
                 array: HoughLineMatrixBlobConnector.Args.ArgType.allCases,
                 stepIndex: stepIndex,
                 detectionType: $detectionType)
    }

}


struct StepView<T: Hashable>: View {
    let title: String
    let description: String
    let args: any Argable<T>
    let array: [T]
    let stepIndex: Int
    let showDisableButton: Bool

    @Binding var detectionType: DetectionType?
    @State var isDisabled = false
    
    public init(title: String,
                description: String,
                args: any Argable<T>,
                array: [T],
                stepIndex: Int,
                detectionType: Binding<DetectionType?>,
                showDisableButton: Bool = true)
    {
        _detectionType = detectionType
        self.title = title
        self.description = description
        self.args = args
        self.array = array
        self.stepIndex = stepIndex
        self.showDisableButton = showDisableButton
    }

    var body: some View {
        VStack() {
            
            ScrollView() {
                
            VStack(alignment: .leading) {
                HStack {



                    if detectionType == .custom,
                       showDisableButton
                    {
                        
                        Toggle(localized("ui.disable"), isOn: $isDisabled)
                          .toggleStyle(.switch)
                          .onChange(of: isDisabled) { _, newValue in
                              if let customProcessor = DetectionType.custom.blobProcessor as? CustomBlobProcessor
                              {
                                  customProcessor.shouldDisable(args, newValue, stepIndex)
                              }
                          }
                        
                    }

                Text(title)
                  .foregroundColor(.white)
                  .font(.largeTitle)
                  .fixedSize(horizontal: false, vertical: true)

                
                }
                Text(description)
                  .fixedSize(horizontal: false, vertical: true)
                Spacer()
                  .frame(maxHeight: 10)
                Text(localized("ui.parameters_which_can_affect_how_this_step"))
                  .fixedSize(horizontal: false, vertical: true)
                Grid(alignment: .topLeading) {
                    GridRow {
                        Text(localized("ui.name"))
                          .foregroundColor(.white)
                          .fixedSize(horizontal: false, vertical: true)
                        Text(localized("ui.value"))
                          .foregroundColor(.white)
                          .fixedSize(horizontal: false, vertical: true)
                        Text(localized("ui.description"))
                          .foregroundColor(.white)
                          .fixedSize(horizontal: false, vertical: true)
                    }
                      .padding(.vertical, 2)

                    /*
                        Divider()
                          .gridCellUnsizedAxes(.vertical)
                          .opacity(0.7)
                      */  

                    // index of paramters in list
                    ForEach(Array(array.enumerated()), id: \.element) { index, value in
                        StepRowView(args,
                                    argType: value,
                                    stepIndex: stepIndex,
                                    detectionType: $detectionType)
                          .padding(.vertical, 2)
                          .disabled(isDisabled)
                        /*
                        Divider()
                          .gridCellUnsizedAxes(.vertical)
                          .opacity(0.7)
                         */
                    }
                }
                  .layoutPriority(10)
            }
            }
        }
          .padding(10)
    }
}

// view for each parameter for this step, as a GridRow with three elements
struct StepRowView<T: Hashable>: View {

    let args: any Argable<T>
    let argType: T
    let stepIndex: Int

    @Binding var detectionType: DetectionType?
    @State var stringValue = ""
    
    init(_ args: any Argable<T>,
         argType: T,
         stepIndex: Int,
         detectionType: Binding<DetectionType?>)
    {
        self.args = args
        self.argType = argType
        self.stepIndex = stepIndex
        _detectionType = detectionType
    }

    var body: some View {
        GridRow {
            Text("\(argType)")
              .fixedSize(horizontal: false, vertical: true)

            let value = args.value(for: argType)
            
            if detectionType == .custom {
                // editable text fields

                if args.isInteger(argType) {
                    TextField("", text: $stringValue)
                      .frame(maxWidth: 80)
                      .onAppear {
                          if let value {
                              stringValue = String(format: "%d", Int(value))
                          }
                      }
                      .onSubmit {
                          if let intValue = Int(stringValue),
                             let customProcessor = DetectionType.custom.blobProcessor as? CustomBlobProcessor
                          { 
                              customProcessor.intUpdate(args, argType, intValue, stepIndex)
                          }
                      }
                    
                } else {
                    TextField("", // not integer (real number)
                              text: $stringValue)
                      .frame(maxWidth: 80)
                      .onAppear {
                          if let value {
                              stringValue = String(format: "%.2f", value)
                          }
                      }
                      .onSubmit {
                          if let doubleValue = Double(stringValue),
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
              .fixedSize(horizontal: false, vertical: true)
        }
    }
}
