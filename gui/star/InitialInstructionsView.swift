import SwiftUI
import StarCore
import logging


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
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var processingMethod: PixelReplacementMethod = .automatic(false)
    @State private var cameraMotion: CameraMotion = .fixed
    @State private var sceneType: SceneType = .skyHorizon
    @State private var autoPreservationMode: AutoPreservationMode = .no

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
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return
          VStack {
              Text("Choose from the following options to let Star know the best way to process this video.")
                .lineLimit(nil)
              //                .fixedSize(horizontal: false, vertical: true)
              //                .frame(maxWidth: .infinity, alignment: .center)
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
                        .disabled(processingMethod == .selective)

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
          //.frame(maxWidth: 2000)
        //          .fixedSize(horizontal: true, vertical: false)
          .padding(20)
          .background(.gray)
        //          .cornerRadius(16)
    }

    private var sceneTypeGridRow: some View {
        GridRow {
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
                    Picker("", selection: $sceneType) {
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
        GridRow {
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
                    Picker("", selection: $cameraMotion) {
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
                //.font(.largeTitle)
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
        GridRow {
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
                    Picker("", selection: $processingMethod) {
                        ForEach(PixelReplacementMethod.allCases, id: \.id) { processingMethod in
                            Text(processingMethod.titleText).tag(sceneType)
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
            Button {
                withAnimation {
                    showProcessingMethodInfo = !showProcessingMethodInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                //.font(.largeTitle)
                  .foregroundColor(showProcessingMethodInfo ? .red : .green)
                  .help(showProcessingMethodInfo ? "Hide Processing Method Information" : "Show Processing Method Information")
            }
              .buttonStyle(PlainButtonStyle())

            HStack {
                if showProcessingMethodInfo {
                    VStack(alignment: .leading) {
                        ForEach(PixelReplacementMethod.allCases, id: \.id) { processingMethod in
                            Text(processingMethod.titleText)
                              .foregroundColor(.white)
                              .font(.largeTitle)
                            
                            Text(processingMethod.description)
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
    
    private var cuncurrentProcessingLimitView: some View {
        GridRow {
            HStack {
                Spacer()
                EditableNumberOfFramesToProcessConcurrentlyView(
                  focusedField: $focusedField,
                  textColor: .white,
                  alwaysOpen: true
                )
                Spacer()
            }

            Button {
                withAnimation {
                    showProcessFramesInfo = !showProcessFramesInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                  .foregroundColor( showProcessFramesInfo ? .red : .green)
                  .help(showProcessFramesInfo ? "Hide Processing Limit Information" : "Show Processing Limit Information")
                
            }
              .buttonStyle(PlainButtonStyle())
        
            HStack {
                if showProcessFramesInfo {
                    
                    Text("How many frames do we process concurrently?  Number of CPUs is likely too high, as much of the processing has been parallized.  2-5 is a good number here.")
                      .foregroundColor(.white)
                      .lineLimit(nil)
                      .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Show Info")
                      .foregroundColor(.white)
                    if addSpacer { Spacer() }
                }
            }
        }

    }

    private var neighborFrameCountView: some View {
        GridRow {
            HStack {
                Spacer()
                EditableNumberOfNeighborFrames(
                  focusedField: $focusedField,
                  textColor: .white,
                  alwaysOpen: true
                )
                Spacer()
            }
            
            Button {
                withAnimation {
                    showNeighborFrameInfo = !showNeighborFrameInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                  .foregroundColor( showNeighborFrameInfo ? .red : .green)
                  .help(showNeighborFrameInfo ? "Hide Frame Count Information" : "Show Frame Count Information")
                
            }
              .buttonStyle(PlainButtonStyle())
            
            HStack {
                if showNeighborFrameInfo {
                    Text("During star alignment, we use this number for aligning and processing neighboring frames.  Lowest possible number is 1, which does work in most cases.  However, 8 is a better option for general use, as it covers the case where neighboring frames have bad pixels at the same location.")
                      .foregroundColor(.white)
                      .lineLimit(nil)
                      .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Show Info")
                      .foregroundColor(.white)
                    if addSpacer { Spacer() }

                }
            }
        }
    }


    private var pixelThresholdView: some View {
        GridRow {
            HStack {
                Spacer()
                EditablePixelThresholdView(
                  focusedField: $focusedField,
                  textColor: .white,
                  alwaysOpen: true
                )
                Spacer()
            }
            Button {
                withAnimation {
                    showPixelThresholdInfo = !showPixelThresholdInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                  .foregroundColor( showPixelThresholdInfo ? .red : .green)
                  .help(showPixelThresholdInfo ? "Hide Pixel Threshold Information" : "Show Pixel Threshold Information")
                
            }
              .buttonStyle(PlainButtonStyle())
            
            HStack {
                if showPixelThresholdInfo {
                    Text("The pixel threshold is a factor used to weed out pixels that are statistically too much brigher than other aligned pixels at the same location.  Lower values like 0.5 get rid of more brighter pixels, higher values like 2.0 will allow more brighter pixels to pass through.  Used for both the subtraction image and for calculating what pixel values to replace airplanes with.")
                      .lineLimit(nil)
                      .foregroundColor(.white)
                      .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Show Info")
                      .foregroundColor(.white)
                    if addSpacer { Spacer() }
                }
            }
        }
    }

    private var processingModeView: some View {
        @Bindable var viewModel = viewModel
        return GridRow {
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
            Button {
                withAnimation {
                    showProcessingModeInfo = !showProcessingModeInfo
                }
            } label: {
                Text("ⓘ")
                  .font(.title2)
                  .foregroundColor( showProcessingModeInfo ? .red : .green)
                  .help(showProcessingModeInfo ? "Hide Processing Information" : "Show Processing Information")
            }
              .buttonStyle(PlainButtonStyle())
            
            HStack {
                if showProcessingModeInfo {
                    Text("Star supports a number of different processing modes for selective processing.  On one end is faster processing and less accuracy, on the other end is slower processing and more touch up work.")
                      .lineLimit(nil)
                      .foregroundColor(.white)
                      .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Show Info")
                      .foregroundColor(.white)
                    if addSpacer { Spacer() }
                }
            }
        }
    }

    private func startProcessing() {
        Log.d("Start")

        processingMethod = processingMethod.apply(
          autoPreservationMode: autoPreservationMode
        )
        
        if let config = viewModel.config {
            var newConfig = config.config()
            newConfig.pixelReplacementMethod = processingMethod
            newConfig.horizonDetectionEnabled = sceneType == .skyHorizon
            newConfig.tripodHeadWasMoving = cameraMotion != .fixed
            config.update(newConfig)
        }
        viewModel.horizonDetectionEnabled = sceneType == .skyHorizon
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
