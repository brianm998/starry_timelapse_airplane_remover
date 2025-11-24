import SwiftUI
import StarCore
import logging

/*

 New items to add:

 - int min/max canny thresholds
 - bool canny gradient magnitude equation

 - bool use canny for horizon?
 - int otsu width
 
 */

enum SceneType: String, CaseIterable, Identifiable {
    case skyHorizon = "Sky + Horizon"
    case skyOnly = "Sky Only"

    var id: Self { self }

    var helpText: String {
        switch self {
        case .skyOnly:
            "Video contains only the sky; no land or horizon line."
        case .skyHorizon:
            "Video shows both sky and ground (horizon line visible)."
        }
    }

    var description: String {
        switch self {
        case .skyOnly:
            "Choose this option if every frame contains only stars, sky glow, and clouds, with no land features. In this mode, frames are aligned only to the stars, which is faster and avoids unnecessary processing."
        case .skyHorizon:
            "Select this if the video includes ground, mountains, treetops, or a clear horizon line. The processor will automatically align the sky to the stars and the ground to the horizon separately. This produces cleaner results in scenes containing both earth and sky."
        }
    }
}

enum CameraMotion: String, CaseIterable, Identifiable {
    case fixed = "Fixed Camera"
    case moving = "Moving Camera"

    var id: Self { self }

    var helpText: String {
        switch self {
        case .fixed:
            "Camera was stationary."
        case .moving:
            "Camera panned or tracked."
        }
    }

    var description: String {
        switch self {
        case .fixed:
            "Choose this if the tripod/head stayed in one place all night. This gives the processor a stable reference, allowing more accurate alignment of the horizon."
        case .moving:
            "Select this if the camera was panning, tracking stars, or following a programmed movement. This helps the processor account for frame-to-frame motion and align images properly even as the scene shifts."
        }
    }
}

struct InitialInstructionsView: View {
    var viewModel: ImageSequenceViewModel

    @State private var pixelReplacementMethod: HighLevelPixelReplacementMethod
    @State private var autoPreservationMode: AutoPreservationMode

    @State private var showSceneTypeInfo = false
    @State private var showCameraMotionInfo = false
    @State private var showProcessingMethodInfo = false
    @State private var showAutoPreservationMethodInfo = false

    @State private var showProcessFramesInfo = false
    @State private var showNeighborFrameInfo = false
    @State private var showPixelThresholdInfo = false
    @State private var showProcessingModeInfo = false
    
    @State private var showExtraSettings = false

    @FocusState private var focusedField: FocusedField?

    init(viewModel: ImageSequenceViewModel) {
        self.viewModel = viewModel

        // grab that shit from the view model
        if viewModel.pixelReplacementMethod.usesOutliers {
            autoPreservationMode = .yes
        } else {
            autoPreservationMode = .no
        }
        switch viewModel.pixelReplacementMethod {
        case .automatic(_):
            pixelReplacementMethod = .automatic
        case .selective:
            pixelReplacementMethod = .selective
        }
    }
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return VStack {
              Text("Choose from the following options to let Star know the best way to process this video.")
                .lineLimit(nil)
                .font(.largeTitle)
                .foregroundColor(.white)

              Space(height: 20)

              ScrollView {
                  Grid {
                      self.sceneTypeGridRow
                      Divider()
                      self.cameraMotionGridRow
                      Divider()
                      self.processingMethodGridRow
                      Divider()
                      self.automaticSelectionGridRow
                        .disabled(self.pixelReplacementMethod == .selective)

                      if showExtraSettings {
                          Divider()
                          self.cuncurrentProcessingLimitView
                          Divider()
                          self.neighborFrameCountView
                          Divider()
                          self.pixelThresholdView
                          Divider()
                          self.processingModeView
                      }
                  }
              }
              
              Space(height: 20)
              
              HStack {
                  Spacer()
                  Button {
                      self.applySettings()
                      viewModel.shouldShowInitialInstructions = false
                  } label: {
                      ZStack {
                          Color.white
                            .cornerRadius(20)

                          Text("Close")
                            .font(.title2)
                            .padding(20)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                    .fixedSize(horizontal: true, vertical: true)

                  Button {
                      startProcessing()
                  } label: {
                      ZStack {
                          Color.blue
                            .cornerRadius(20)

                          Text("Start Processing")
                            .font(.title2)
                            .padding(20)
                            .foregroundColor(.white)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                    .fixedSize(horizontal: true, vertical: true)


                  Spacer()
                  Button() {
                      withAnimation {
                          showExtraSettings = !showExtraSettings
                      }
                  } label: {
                      Text("⚙")
                        .font(.system(size: 60))
                        .foregroundColor(showExtraSettings ? .red : .green)
                        .help(showExtraSettings ? "Hide Extra Settings" : "Show Extra Settings")
                  }
                    .buttonStyle(PlainButtonStyle())
                  Text(showExtraSettings ? "Hide Extra Settings" : "Show Extra Settings")
                    .foregroundColor(.white)
              }
          }
          .frame(minWidth: 800)
          .padding(20)
          .background(.gray)
    }

    private var sceneTypeGridRow: some View {
        @Bindable var viewModel = viewModel
        return GridRow {
            HStack(alignment: .top) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Scene Type:")
                          .font(.title2)
                          .foregroundColor(.white)
                    }
                    
                }
                HStack {
                    Picker("", selection: $viewModel.sceneType) {
                        ForEach(SceneType.allCases, id: \.id) { sceneType in
                            Text(sceneType.rawValue).tag(sceneType)
                              .foregroundColor(.white)
                              .help(sceneType.helpText)
                        }
                    }
                      .pickerStyle(.inline)
                      .foregroundColor(.white)
                    Spacer()
                }
            }
            
            Button {
                withAnimation {
                    showSceneTypeInfo = !showSceneTypeInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                  .foregroundColor(showSceneTypeInfo ? .red : .green)
                  .help(showSceneTypeInfo ? "Hide Scene Type Information" : "Show Scene Type Information")
                
            }
              .buttonStyle(PlainButtonStyle())
        
            HStack {
                if showSceneTypeInfo {
                    VStack(alignment: .leading) {
                        ForEach(SceneType.allCases, id: \.id) { sceneType in
                            Text(sceneType.rawValue)
                              .foregroundColor(.white)
                              .font(.largeTitle)
                            
                            Text(sceneType.description)
                              .foregroundColor(.white)
                              .font(.body)
                        }
                    }
                } else {
                    Text("Show Info")
                      .foregroundColor(.white)
                    if addSpacer { Spacer() }
                }
            }
        }
    }
    

     
    private var cameraMotionGridRow: some View {
        @Bindable var viewModel = viewModel
        return GridRow {
            HStack(alignment: .top) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Camera Motion:")
                          .font(.title2)
                          .foregroundColor(.white)

                    }
                }
                HStack {
                    Picker("", selection: $viewModel.cameraMotion) {
                        ForEach(CameraMotion.allCases, id: \.id) { cameraMotion in
                            Text(cameraMotion.rawValue).tag(cameraMotion)
                              .foregroundColor(.white)
                              .help(cameraMotion.helpText)
                        }
                    }
                      .pickerStyle(.inline)
                      .foregroundColor(.white)
                    //                                .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            Button {
                withAnimation {
                    showCameraMotionInfo = !showCameraMotionInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                  .foregroundColor(showCameraMotionInfo ? .red : .green)
                  .help(showCameraMotionInfo ? "Hide Camera Motion Information" : "Show Camera Motion Information")
            }
              .buttonStyle(PlainButtonStyle())

            HStack {
                if showCameraMotionInfo {
                    VStack(alignment: .leading) {
                        ForEach(CameraMotion.allCases, id: \.id) { cameraMotion in
                            Text(cameraMotion.rawValue)
                              .foregroundColor(.white)
                              .font(.largeTitle)
                            
                            Text(cameraMotion.description)
                              .foregroundColor(.white)
                              .font(.body)
                        }
                    }
                } else {
                    Text("Show Info")
                      .foregroundColor(.white)
                    if addSpacer { Spacer() }
                }
            }
        }
    }

    private var addSpacer: Bool {
        showCameraMotionInfo || showSceneTypeInfo || showProcessingMethodInfo ||
        showAutoPreservationMethodInfo || showProcessFramesInfo ||
        showNeighborFrameInfo || showPixelThresholdInfo || showProcessingModeInfo
    }

    private var automaticSelectionGridRow: some View {
        GridRow {
            HStack(alignment: .top) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Selective Auto Clean:")
                          .font(.title2)
                          .foregroundColor(.white)

                    }
                }
                HStack {
                    Picker("", selection: $autoPreservationMode) {
                        ForEach(AutoPreservationMode.allCases, id: \.id) { mode in
                            Text(mode.rawValue).tag(mode)
                              .foregroundColor(.white)
                              .help(mode.helpText)
                        }
                    }
                      .pickerStyle(.inline)
                      .foregroundColor(.white)
                    Spacer()
                }
            }
            Button {
                withAnimation {
                    showAutoPreservationMethodInfo = !showAutoPreservationMethodInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                //.font(.largeTitle)
                  .foregroundColor(showAutoPreservationMethodInfo ? .red : .green)
                  .help(showAutoPreservationMethodInfo ? "Hide Auto Clean Information" : "Show Auto Clean Information")
            }
              .buttonStyle(PlainButtonStyle())

            HStack {
                if showAutoPreservationMethodInfo {
                    VStack(alignment: .leading) {
                        ForEach(AutoPreservationMode.allCases, id: \.id) { mode in
                            Text(mode.rawValue)
                              .foregroundColor(.white)
                              .font(.largeTitle)
                            
                            Text(mode.description)
                              .foregroundColor(.white)
                              .font(.body)
                        }
                    }
                } else {
                    Text("Show Info")
                      .foregroundColor(.white)
                    if addSpacer { Spacer() }
                }
            }
        }
    }
    
    private var processingMethodGridRow: some View {
        @Bindable var viewModel = viewModel
        return
          InstructionGridRow(
            showInfo: $showProcessingMethodInfo,
            addSpacer: { addSpacer },
            infoView: {
                VStack(alignment: .leading) {
                    ForEach(HighLevelPixelReplacementMethod.allCases, id: \.id) { processingMethod in
                        Text(processingMethod.titleText)
                          .foregroundColor(.white)
                          .font(.largeTitle)
                        
                        Text(processingMethod.description)
                          .foregroundColor(.white)
                          .font(.body)
                    }
                }
            } 
          ) {
            HStack(alignment: .top) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Processing Method:")
                          .font(.title2)
                          .foregroundColor(.white)

                    }
                }
                HStack {
                    Picker("", selection: $pixelReplacementMethod) {
                        ForEach(HighLevelPixelReplacementMethod.allCases, id: \.id) { processingMethod in
                           Text(processingMethod.titleText).tag(viewModel.sceneType)
                              .foregroundColor(.white)
                              .help(processingMethod.helpText)
                        }
                    }
                      .pickerStyle(.inline)
                    //                        .fixedSize(horizontal: false, vertical: true)
                      .foregroundColor(.white)
                    Spacer()
                }
            }
        }
    }
    
    private var cuncurrentProcessingLimitView: some View {
        InfoTextInstructionGridRow(
          showInfo: $showProcessFramesInfo,
          addSpacer: { addSpacer },
          infoText: """
            How many frames do we process concurrently?  Number of CPUs is likely too high, as much of the processing has been parallized.  2-5 is a good number here.
            """
        ) {
            EditableNumberOfFramesToProcessConcurrentlyView(
              focusedField: $focusedField,
              textColor: .white,
              alwaysOpen: true
            )
        }
    }

    private var neighborFrameCountView: some View {
        InfoTextInstructionGridRow(
          showInfo: $showNeighborFrameInfo,
          addSpacer: { addSpacer },
          infoText: """
            During star alignment, we use this number for aligning and processing neighboring frames.  Lowest possible number is 1, which does work in most cases.  However, 8 is a better option for general use, as it covers the case where neighboring frames have bad pixels at the same location.
            """
        ) {
            EditableNumberOfNeighborFrames(
              focusedField: $focusedField,
              textColor: .white,
              alwaysOpen: true
            )
        }
    }

    private var pixelThresholdView: some View {
        InfoTextInstructionGridRow(
          showInfo: $showPixelThresholdInfo,
          addSpacer: { addSpacer },
          infoText: """
            The pixel threshold is a factor used to weed out pixels that are statistically too much brigher than other aligned pixels at the same location.  Lower values like 0.5 get rid of more brighter pixels, higher values like 2.0 will allow more brighter pixels to pass through.  Used for both the subtraction image and for calculating what pixel values to replace airplanes with.
            """
        ) {
            EditablePixelThresholdView(
              focusedField: $focusedField,
              textColor: .white,
              alwaysOpen: true
            )
        }
    }

    private var processingModeView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showProcessingModeInfo,
          addSpacer: { addSpacer },
          infoText: """
            Star supports a number of different processing modes for selective processing.  On one end is faster processing and less accuracy, on the other end is slower processing and more touch up work.
            """
        ) {
            HStack {
                Text("Processing Mode:")
                  .foregroundColor(.white)
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
        }
    }

    private func applySettings() {

        switch self.pixelReplacementMethod {
        case .automatic:
            viewModel.pixelReplacementMethod = .automatic(autoPreservationMode.boolValue)
        case .selective:
            viewModel.pixelReplacementMethod = .selective
        }

        if !viewModel.pixelReplacementMethod.usesOutliers {
            viewModel.selectionMode = .none
        }
    }
    
    private func startProcessing() {
        Log.d("Start")
        self.applySettings()
        viewModel.shouldShowInitialInstructions = false

        viewModel.showIgnoreLowerBar = false

        if viewModel.horizonDetectionEnabled {

            viewModel.processHorizonForAllFrames() {
                // after we get horizons for all frames, render frames
                viewModel.renderAllFrames()
            }
        } else {

            viewModel.ignoreLowerPixels = 0

            viewModel.renderAllFrames()
        }
    }
}

struct InfoTextInstructionGridRow<Content: View>: View {
    @Binding var showInfo: Bool
    let addSpacer: () -> Bool
    let infoText: String
    let contentView: () -> Content

    var body: some View {
        InstructionGridRow(
          showInfo: $showInfo,
          addSpacer: addSpacer,
          infoView: {
              Text(infoText)
                .foregroundColor(.white)
                .lineLimit(nil)
                .fixedSize(horizontal: false, vertical: true)
          },
          contentView: contentView
        )
    }
}

// base grid row
struct InstructionGridRow<Content: View, InfoContent: View>: View {
    @Binding var showInfo: Bool
    let addSpacer: () -> Bool
    let infoView: () -> InfoContent
    let contentView: () -> Content

    var body: some View {
        GridRow {
            // --- Column 1 ---
            HStack {
                Spacer()
                contentView()
                Spacer()
            }

            // --- Column 2 ---
            Button {
                withAnimation { showInfo.toggle() }
            } label: {
                Text("ⓘ")
                    .font(.title2)
                    .foregroundColor(showInfo ? .red : .green)
                    .help(showInfo ? "Hide Information" : "Show Information")
            }
            .buttonStyle(PlainButtonStyle())

            // --- Column 3 ---
            HStack {
                if showInfo {
                    infoView()
                } else {
                    Text("Show Info")
                        .foregroundColor(.white)
                    if addSpacer() { Spacer() }
                }
            }
        }
    }
}
