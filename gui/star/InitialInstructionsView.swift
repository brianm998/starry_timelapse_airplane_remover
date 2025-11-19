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

// XXX combine this with PixelReplaementMethod
enum ProcessingMethod: String, CaseIterable, Identifiable {
    case auto = "Auto Clean"
    case selective = "Selective Clean"

    var id: Self { self }

    var helpText: String {
        switch self {
        case .auto:
            "Fully automatic removal of airplanes/satellites; replaces each frame with a clean median composite."
        case .selective:
            "Selective Clean – Detects only streak-like outliers and lets you decide which to remove; good for clouds or when you want control."
        }
    }

    var description: String {
        switch self {
        case .auto:
            "This mode automatically builds a clean “best version” of every frame using neighboring frames. It removes streaks extremely well when skies are clear. It requires almost no user input and is faster to use, but it can struggle around dawn/dusk and may distort fast-moving clouds."
        case .selective:
            "This mode compares each original frame to a clean reference frame and highlights only the differences that look like airplane or satellite streaks. You can review and approve these changes. It works better when clouds are present or when you want to keep certain objects (like meteors). It takes more interaction but gives you finer control."
        }
    }

    var replacementMethod: PixelReplacementMethod {
        switch self {
        case .auto:
            .automatic
        case .selective:
            .selective
        }        
    }
}

func autoCleanSelectiveHelpText(isOn: Bool) -> String {
    if isOn {
        "Apply Selective Clean after Auto Clean to keep important objects from the original frame."
    } else {
        "Use pure Auto Clean with full automatic replacement."
    }
}

func autoCleanSelectiveDescription(isOn: Bool) -> String {
    if isOn {
        "After Auto Clean creates a streak-free frame, Selective Clean can be run in reverse to restore specific bright events—such as meteors or flares—from the original footage. This lets you keep rare celestial events while still removing planes and satellites."
    } else {
        "The processor will use the fully automatic method only. This gives the cleanest sky possible but removes all bright moving objects, including meteors."
    }
}

struct InitialInstructionsView: View {
    @Environment(ImageSequenceViewModel.self) var viewModel: ImageSequenceViewModel

    @State private var processingMethod: ProcessingMethod = .auto
    @State private var cameraMotion: CameraMotion = .fixed
    @State private var sceneType: SceneType = .skyHorizon
    @State private var preserveEvents = false

    @State private var showSceneTypeInfo = true
    @State private var showCameraMotionInfo = true
    @State private var showProcessingMethodInfo = true
    
    var body: some View {
        @Bindable var viewModel = viewModel
        return
          ScrollView {
          VStack {
              Text("Video Processing Options")
                .font(.largeTitle)
                .foregroundColor(.white)

              Space(height: 10)
              Text("Choose from the following options to let Star know the best way to process this video.")
                .lineLimit(nil)
//                .fixedSize(horizontal: false, vertical: true)
//                .frame(maxWidth: .infinity, alignment: .center)
                .font(.title)
                .foregroundColor(.white)

              Space(height: 20)

//              ScrollView {
//                  VStack {

              self.sceneTypeView

              self.cameraMotionView
              
              self.processingMethodView

                  /*

                   This is not implemented past here yet

                   need a config flag that turns on/off outlier detection
                   
                  Divider()

                  Toggle("Preserve Meteors / Flares", isOn: $preserveEvents)
                    .foregroundColor(.white)
                    .disabled(processingMethod != .auto)

                   */
//                  }
//                    .fixedSize(horizontal: true, vertical: true)
//              }
//                .fixedSize(horizontal: true, vertical: true)

              Space(height: 20)
              
              HStack {
                  Button {
                      viewModel.shouldShowInitialInstructions = false
                  } label: {
                      ZStack {
                          Color.white
                            .cornerRadius(20)

                          Text("Cancel")
                            .font(.title2)
                            .padding(20)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck

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
              }
                .fixedSize(horizontal: true, vertical: true)
          }
            .frame(minWidth: 1000)
          //  .fixedSize(horizontal: true, vertical: false)

          }
            .frame(maxWidth: 2000)
        //          .fixedSize(horizontal: true, vertical: false)
          .padding(20)
          .background(.gray)
        //          .cornerRadius(16)
    }

    private var sceneTypeView: some View {
        VStack {
            HStack(alignment: .top) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Scene Type:")
                          .font(.title2)
                          .foregroundColor(.white)
                        Button {
                            Task {
                                withAnimation {
                                    showSceneTypeInfo = !showSceneTypeInfo
                                }
                            }
                        } label: {
                            Text("ⓘ")
                              .font(.title2)
                            //.font(.largeTitle)
                              .foregroundColor(showSceneTypeInfo ? .red : .green)
                              .help(showSceneTypeInfo ? "Hide Scene Type Information" : "Show Scene Type Information")
                            
                        }
                          .buttonStyle(PlainButtonStyle())
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
                    //                                .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            Divider()

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
                Divider()
            }
        }
    }

    private var cameraMotionView: some View {
        VStack {
            HStack(alignment: .top) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Camera Motion:")
                          .font(.title2)
                          .foregroundColor(.white)

                        Button {
                            Task {
                                withAnimation {
                                    showCameraMotionInfo = !showCameraMotionInfo
                                }
                            }
                        } label: {
                            Text("ⓘ")
                              .font(.title2)
                            //.font(.largeTitle)
                              .foregroundColor(showCameraMotionInfo ? .red : .green)
                              .help(showCameraMotionInfo ? "Hide Camera Motion Information" : "Show Camera Motion Information")
                        }
                          .buttonStyle(PlainButtonStyle())
                    }
                }
                HStack {
                    Picker("", selection: $cameraMotion) {
                        ForEach(CameraMotion.allCases, id: \.id) { cameraMotion in
                            Text(cameraMotion.rawValue).tag(sceneType)
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
            Divider()
            
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
                Divider()
            }
        }
    }

    private var processingMethodView: some View {
        VStack {
            HStack(alignment: .top) {
                HStack {
                    Spacer()
                    VStack(alignment: .trailing) {
                        Text("Processing Method:")
                          .font(.title2)
                          .foregroundColor(.white)

                        Button {
                            Task {
                                withAnimation {
                                    showProcessingMethodInfo = !showProcessingMethodInfo
                                }
                            }
                        } label: {
                            Text("ⓘ")
                              .font(.title2)
                            //.font(.largeTitle)
                              .foregroundColor(showProcessingMethodInfo ? .red : .green)
                              .help(showProcessingMethodInfo ? "Hide Processing Method Information" : "Show Processing Method Information")
                        }
                          .buttonStyle(PlainButtonStyle())
                    }
                }
                HStack {
                    Picker("", selection: $processingMethod) {
                        ForEach(ProcessingMethod.allCases, id: \.id) { processingMethod in
                            Text(processingMethod.rawValue).tag(sceneType)
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

            if showProcessingMethodInfo {
                VStack(alignment: .leading) {
                    ForEach(ProcessingMethod.allCases, id: \.id) { processingMethod in
                        Text(processingMethod.rawValue)
                          .foregroundColor(.white)
                          .font(.largeTitle)
                        
                        Text(processingMethod.description)
                          .foregroundColor(.white)
                          .font(.body)
                    }
                }
                Divider()
            }
        }
    }
    
    private func startProcessing() {
        Log.d("Start")

        var pixelReplacementMethod: PixelReplacementMethod = .automatic
        
        if let config = viewModel.config {
            var newConfig = config.config()
            newConfig.pixelReplacementMethod = processingMethod.replacementMethod
            pixelReplacementMethod = processingMethod.replacementMethod
            newConfig.horizonDetectionEnabled = sceneType == .skyHorizon
            newConfig.tripodHeadWasMoving = cameraMotion != .fixed
            config.update(newConfig)
        }
        viewModel.horizonDetectionEnabled = sceneType == .skyHorizon
        viewModel.shouldShowInitialInstructions = false


        viewModel.showIgnoreLowerBar = false

        if viewModel.horizonDetectionEnabled {

            viewModel.processHorizonForAllFrames() {
                Log.d("FUCKING CLOSURE CALLED")
                // after we get horizons for all frames, then either
                switch pixelReplacementMethod {
                case .automatic:
                    // render all frames automatically
                    viewModel.renderAllFramesAutomatic()
                    
                case .selective:
                    // or show a dialog to tell new users what to do next
                    viewModel.showProcessingOptionsSheet = true
                }
            }
        } else {

            viewModel.ignoreLowerPixels = 0

            switch pixelReplacementMethod {
            case .automatic:
                // render all frames automatically
                viewModel.renderAllFramesAutomatic()
                
            case .selective:
                // or show a dialog to tell new users what to do next
                viewModel.showProcessingOptionsSheet = true
            }
        }
    }
}
