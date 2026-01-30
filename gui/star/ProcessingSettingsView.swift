import SwiftUI
import StarCore
import logging

public enum CannyGradientMethod: InstructionOption,
                                 Sendable,
                                 Codable
{
    case L1norm
    case L2norm

    public var id: Self { self }

    public var titleText: String {
        switch self {
        case .L1norm:
            "L1 Norm"
        case .L2norm:
            "L2 Norm"
        }
    }

    public var cvArgValue: Bool {
        switch self {
        case .L1norm:
            false
        case .L2norm:
            true
        }
    }
    
    public static let topTitle = "Canny Gradient Method:"
    
    public var helpText: String {
        switch self {
        case .L1norm:
            "L1 Norm faster, less accurate"
        case .L2norm:
            "L2 Norm more accurate, slightly slower"
        }
    }

    public var descriptionText: String {
        switch self {
        case .L1norm:
            """
                  mag=∣dX∣+∣dY∣
              
               - Faster
               - Less accurate
               - Historically the original Canny implementation in OpenCV
            """
        case .L2norm:
            """
                 mag = √(dX²+dY²)
              
               - More accurate edge magnitude
               - Slightly slower due to square root
               - Produces cleaner, more precise edges (especially on low-contrast areas)
              """
        }
    }
}

public enum UseCannyEdgeDetectionForHorizon: InstructionOption,
                                             Sendable,
                                             Codable
{
    case yes
    case no

    public var id: Self { self }

    public var titleText: String {
        switch self {
        case .yes:
            "Yes"
        case .no:
            "No"
        }
    }

    public static let topTitle = "Canny Edge Detection:"
    
    public var helpText: String {
        switch self {
        case .yes:
            "Use Canny Edge Detection in addition to Otsu's thresholding for doing horizon detection."
        case .no:
            "Only use Otsu's tresholding when doing horizon detection."
        }
    }

    public var descriptionText: String {
        switch self {
        case .yes:
            "Using Canny Edge Detection can help find horizons that have bright patches below the horizon.  One example is mountains with snow on them.  Otsu's Thresholding can include these brighter areas in the sky.  Using Canny edge detection in addition to Otsu's Thresholding gives better results in this case"
        case .no:
            "Using only Otsu's Thresholding for horizon detection can work when the ground is really dark.  This will be a little faster than also doing Canny edge detection."
        }
    }
}
      
enum SceneType: String, InstructionOption, Identifiable {
    case skyHorizon = "Sky + Horizon"
    case skyOnly = "Sky Only"

    var id: Self { self }

    static let topTitle = "Scene Type:"
    
    var titleText: String { self.rawValue }

    var helpText: String {
        switch self {
        case .skyOnly:
            "Video contains only the sky; no land or horizon line."
        case .skyHorizon:
            "Video shows both sky and ground (horizon line visible)."
        }
    }

    var descriptionText: String {
        switch self {
        case .skyOnly:
            "Choose this option if every frame contains only stars, sky glow, and clouds, with no land features. In this mode, frames are aligned only to the stars, which is faster and avoids unnecessary processing."
        case .skyHorizon:
            "Select this if the video includes ground, mountains, treetops, or a clear horizon line. The processor will automatically align the sky to the stars and the ground to the horizon separately. This produces cleaner results in scenes containing both earth and sky."
        }
    }
}

enum CameraMotion: String, InstructionOption, Identifiable {
    case fixed = "Fixed"
    case moving = "Moving"

    var id: Self { self }

    static let topTitle = "Camera Motion:"
    
    var titleText: String { self.rawValue }

    var helpText: String {
        switch self {
        case .fixed:
            "Camera was stationary."
        case .moving:
            "Camera panned or tracked."
        }
    }

    var descriptionText: String {
        switch self {
        case .fixed:
            "Choose this if the tripod/head stayed in one place all night. This gives the processor a stable reference, allowing more accurate alignment of the horizon."
        case .moving:
            "Select this if the camera was panning, tracking stars, or following a programmed movement. This helps the processor account for frame-to-frame motion and align images properly even as the scene shifts."
        }
    }
}

struct ProcessingSettingsView: View {
    var viewModel: ImageSequenceViewModel

    @State private var cleanMethod: HighLevelCleanMethod
    @State private var autoPreservationMode: AutoPreservationMode

    @State private var showSceneTypeInfo = false
    @State private var showCameraMotionInfo = false
    @State private var showProcessingMethodInfo = false
    @State private var showAutoPreservationMethodInfo = false
    @State private var showUseCannyInfo = false

    @State private var showProcessFramesInfo = false
    @State private var showNeighborFrameInfo = false
    @State private var showMinAlignmentFramesInfo = false
    @State private var showStaticNeighborFrameInfo = false
    @State private var showPixelThresholdInfo = false
    @State private var showProcessingModeInfo = false
    @State private var showCannyMinThresholdView = false
    @State private var showCannyMaxThresholdView = false
    @State private var showCannyL2GradientView = false
    @State private var showHorizonVerticalShiftAmountView = false

    @State private var showHorizonStripInfo = false

    @State private var showAlignmentMaxKeypointsInfo = false
    @State private var showAlignmentGroundHorizonExtensionInfo = false
    @State private var showAlignmentSkyHorizonExtensionInfo = false
    @State private var showAlignmentBaseImageDilateSizeInfo = false
    @State private var showAlignmentBaseImageThresholdValueInfo = false
    @State private var showAlignmentNeighborDilateSizeInfo = false
    @State private var showAlignmentNeighborThresholdValueInfo = false

    @State private var showAlignmentWriteDebugImagesInfo = false
    @State private var showAlignmentAllowEarthAlignmentInfo = false

    private var addSpacer: Bool {
        showCameraMotionInfo || showSceneTypeInfo || showProcessingMethodInfo ||
        showAutoPreservationMethodInfo || showProcessFramesInfo ||
        showNeighborFrameInfo || showPixelThresholdInfo || showProcessingModeInfo ||
        showUseCannyInfo || showHorizonStripInfo || showCannyMinThresholdView ||
        showCannyMaxThresholdView || showCannyL2GradientView ||
        showStaticNeighborFrameInfo || showHorizonVerticalShiftAmountView ||
        showMinAlignmentFramesInfo ||
        showAlignmentMaxKeypointsInfo ||
        showAlignmentGroundHorizonExtensionInfo ||
        showAlignmentSkyHorizonExtensionInfo ||
        showAlignmentBaseImageDilateSizeInfo ||
        showAlignmentBaseImageThresholdValueInfo ||
        showAlignmentNeighborDilateSizeInfo ||
        showAlignmentNeighborThresholdValueInfo ||
        showAlignmentWriteDebugImagesInfo ||
        showAlignmentAllowEarthAlignmentInfo 
    }
    
    private func showAll() {
        showCameraMotionInfo = true
        showSceneTypeInfo = true
        showProcessingMethodInfo = true
        showAutoPreservationMethodInfo = true
        showProcessFramesInfo = true
        showNeighborFrameInfo = true
        showMinAlignmentFramesInfo = true
        showStaticNeighborFrameInfo = true
        showPixelThresholdInfo = true
        showProcessingModeInfo = true
        showHorizonStripInfo = true
        showUseCannyInfo = true
        showCannyMinThresholdView = true
        showCannyMaxThresholdView = true
        showCannyL2GradientView = true
        showHorizonVerticalShiftAmountView = true
        showAlignmentMaxKeypointsInfo = true
        showAlignmentGroundHorizonExtensionInfo = true
        showAlignmentSkyHorizonExtensionInfo = true
        showAlignmentBaseImageDilateSizeInfo = true
        showAlignmentBaseImageThresholdValueInfo = true
        showAlignmentNeighborDilateSizeInfo = true
        showAlignmentNeighborThresholdValueInfo = true
        showAlignmentWriteDebugImagesInfo = true
        showAlignmentAllowEarthAlignmentInfo = true
    }

    private func hideAll() {
        showCameraMotionInfo = false
        showSceneTypeInfo = false
        showProcessingMethodInfo = false
        showAutoPreservationMethodInfo = false
        showProcessFramesInfo = false
        showNeighborFrameInfo = false
        showMinAlignmentFramesInfo = false        
        showStaticNeighborFrameInfo = false
        showPixelThresholdInfo = false
        showHorizonStripInfo = false
        showProcessingModeInfo = false
        showUseCannyInfo = false
        showCannyMinThresholdView = false
        showCannyMaxThresholdView = false
        showCannyL2GradientView = false
        showHorizonVerticalShiftAmountView = false
        showAlignmentMaxKeypointsInfo = false
        showAlignmentGroundHorizonExtensionInfo = false
        showAlignmentSkyHorizonExtensionInfo = false
        showAlignmentBaseImageDilateSizeInfo = false
        showAlignmentBaseImageThresholdValueInfo = false
        showAlignmentNeighborDilateSizeInfo = false
        showAlignmentNeighborThresholdValueInfo = false
        showAlignmentWriteDebugImagesInfo = false
        showAlignmentAllowEarthAlignmentInfo = false
    }
    
    @FocusState private var focusedField: FocusedField?

    init(viewModel: ImageSequenceViewModel) {
        self.viewModel = viewModel

        // grab that shit from the view model
        if viewModel.cleanMethod.usesOutliers {
            autoPreservationMode = .yes
        } else {
            autoPreservationMode = .no
        }
        switch viewModel.cleanMethod {
        case .automatic(_):
            cleanMethod = .automatic
        case .selective:
            cleanMethod = .selective
        }
    }

    var body: some View {
        @Bindable var viewModel = viewModel
        return VStack {
              Text("Choose from the following options to let Star know the best way to process this video.")
                .lineLimit(nil)
                .font(.largeTitle)
                .foregroundColor(.white)

              HStack {
                  Spacer()
                  Button {
                      self.hideAll()
                  } label: {
                      ZStack {
                          Color.white
                            .cornerRadius(10)

                          Text("Hide Info")
                            .font(.body)
                            .padding(10)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                    .fixedSize(horizontal: true, vertical: true)
                  Button {
                      self.showAll()
                  } label: {
                      ZStack {
                          Color.blue
                            .cornerRadius(10)
                          Text("Show Info")
                            .font(.body)
                            .foregroundColor(.white)
                            .padding(10)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                    .fixedSize(horizontal: true, vertical: true)
              }
              
              Space(height: 20)
              
              ScrollView {
                  Grid {
                      self.sceneTypeGridRow
                      Divider()
                      self.cameraMotionGridRow
                      Divider()
                      self.processingMethodGridRow

                      if viewModel.showExpertSettings {
                          Divider()
                          self.automaticSelectionGridRow
                          Divider()
                          self.processingModeView
                          Divider()
                          self.cuncurrentProcessingLimitView
                          Divider()
                          DisclosureGroup {
                              Grid {
                                  self.neighborFrameCountView
                                  Divider()
                                  self.staticNeighborFrameCountView
                                  Divider()
                                  self.pixelThresholdView
                                  Divider()
                                  self.alignmentMaxKeypointsView
                                  Divider()
                                  self.alignmentGroundHorizonExtensionView
                                  Divider()
                                  self.alignmentSkyHorizonExtensionView
                                  Divider()
                                  self.alignmentBaseImageDilateSizeView
                                  Divider()
                                  self.alignmentBaseImageThresholdValueView
                                  Divider()
                                  self.alignmentNeighborDilateSizeView
                                  Divider()
                                  self.alignmentNeighborThresholdValueView
                                  Divider()
                                  self.alignmentAllowEarthAlignmentView
                                  Divider()
                                  self.alignmentWriteDebugImagesViewValueView
                              }
                          } label: {
                              Text("Alignment Settings") 
                                .font(.title2)
                                .foregroundColor(.white)
                                .opacity(0.6)
                          }
                          .tint(.primary)

                          Divider()
                          DisclosureGroup {
                              Grid {
                                  self.horizonStripWidthView
                                  Divider()
                                  self.maxConcurrentHorizonsView
                                  Divider()
                                  self.useCannyEdgeDetectionGridRow
                                  Divider()
                                  self.cannyMinThresholdView
                                  Divider()
                                  self.cannyMaxThresholdView
                                  Divider()
                                  self.l2GradientGridRow
                                  Divider()
                                  self.horizonVerticalShiftAmountView
                              }
                          } label: {
                              Text("Horizon Settings") 
                                .font(.title2)
                                .foregroundColor(.white)
                                .opacity(0.6)
                          }
                          .tint(.secondary)
                      }
                  }
              }
              
              Space(height: 20)
              
              HStack {
                  HStack {
                      Spacer()
                      Button {
                          self.applySettings()
                          viewModel.shouldShowProcessingSettings = false
                      } label: {
                          ZStack {
                              Color.white
                                .cornerRadius(20)

                              Text("Dismiss")
                                .font(.title2)
                                .padding(20)
                          }
                      }
                        .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                        .fixedSize(horizontal: true, vertical: true)
                  }

                  HStack {
                      Button {
                          Log.d("processAll")
                          startProcessing()
                      } label: {
                          ZStack {
                              Color.blue
                                .cornerRadius(20)

                              Text("Process Now")
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
                              viewModel.showExpertSettings.toggle()
                          }
                      } label: {
                          ZStack {
                              Color.blue
                                .cornerRadius(10)

                              Text(viewModel.showExpertSettings ? "Hide Expert Settings" : "Show Expert Settings")
                                .foregroundColor(.white)
                                .padding(10)
                          }
                      }
                        .buttonStyle(PlainButtonStyle())
                        .fixedSize(horizontal: true, vertical: true)
                  }
              }
          }
          .frame(minWidth: 800)
          .padding(20)
          .background(.gray)
    }

    private var sceneTypeGridRow: some View {
        @Bindable var viewModel = viewModel
        return EnumInstructionGridRow<SceneType>(
          selection: $viewModel.sceneType,
          showInfo: $showSceneTypeInfo,
          addSpacer: { addSpacer }
        )        
    }

    private var l2GradientGridRow: some View {
        @Bindable var viewModel = viewModel
        return EnumInstructionGridRow<CannyGradientMethod>(
          selection: $viewModel.cannyUseL2Gradient,
          showInfo: $showCannyL2GradientView,
          addSpacer: { addSpacer },
          isPrimary: false
        )        
          .disabled(viewModel.sceneType == .skyOnly || viewModel.useCannyForHorizonDetection == .no)
    }
     
    private var cameraMotionGridRow: some View {
        @Bindable var viewModel = viewModel
        return EnumInstructionGridRow<CameraMotion>(
          selection: $viewModel.cameraMotion,
          showInfo: $showCameraMotionInfo,
          addSpacer: { addSpacer }
        )        
    }

    private var automaticSelectionGridRow: some View {
        EnumInstructionGridRow<AutoPreservationMode>(
          selection: $autoPreservationMode,
          showInfo: $showAutoPreservationMethodInfo,
          addSpacer: { addSpacer },
          isPrimary: false
        )        
          .disabled(self.cleanMethod == .selective)
    }
    
    private var processingMethodGridRow: some View {
        EnumInstructionGridRow<HighLevelCleanMethod>(
          selection: $cleanMethod,
          showInfo: $showProcessingMethodInfo,
          addSpacer: { addSpacer }
        )        
    }

    private var useCannyEdgeDetectionGridRow: some View {
        @Bindable var viewModel = viewModel
        return EnumInstructionGridRow<UseCannyEdgeDetectionForHorizon>(
          selection: $viewModel.useCannyForHorizonDetection,
          showInfo: $showUseCannyInfo,
          addSpacer: { addSpacer },
          isPrimary: false
        )
          .disabled(viewModel.sceneType == .skyOnly)
    }
    

    
    private var cuncurrentProcessingLimitView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showProcessFramesInfo,
          addSpacer: { addSpacer },
          infoText: """
            How many frames do we process concurrently?  Number of CPUs is likely too high, as much of the processing has been parallized.  2-5 is a good number here.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Max Concurrent Frames:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.numberOfFramesToProcessConcurrently,
                      minValue: 1,
                      maxValue: viewModel.imageSequenceSize,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .numberOfFramesToProcessConcurrently,
                      alwaysOpen: true,
                      commitAction: { newVal in
                          // persist to prefs & global
                          viewModel.userPreferences.concurrentFrames = newVal
                          Task { await maxFramesProcessing.set(value: newVal) }
                      }
                    )
                    Spacer()
                }
            }
        }
    }

    private var neighborFrameCountView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showNeighborFrameInfo,
          addSpacer: { addSpacer },
          infoText: """
            During star alignment, we use this number for aligning and processing neighboring frames.  Lowest possible number is 1, which does work for many cases in selective processing.  However, 8 is a better option for general use, as it covers the case where neighboring frames have bad pixels at the same location.
            Giving a value of 8 means that four neighboring frames on each side will be used, except for the edge cases at the ends of the video, where 8 neighbors are still used, but more on one side or the other as necessary.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Neighbor Frame Count:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.numberOfAlignedNeighborFrames,
                      minValue: 1,
                      maxValue: viewModel.imageSequenceSize,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .numberOfNeighborFrames,
                      alwaysOpen: true
                    )
                    Spacer()   
                }
            }
        }
    }

    private var staticNeighborFrameCountView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showStaticNeighborFrameInfo,
          addSpacer: { addSpacer },
          infoText: """
            With difficult horizons, star can get better horizon results by merging
            more neighboring horizons together.
            Use this field when the camera is not moving, and include as many as you need to get a smoother horizon that doesn't change much between frames.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Static Neighbor Frame Count:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.numberStaticNeighborFrames,
                      minValue: 1,
                      maxValue: viewModel.imageSequenceSize,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .numberStaticNeighborFrames,
                      alwaysOpen: true
                    )
                    Spacer()   
                }
            }
        }
          .disabled(viewModel.cameraMotion != .fixed)
    }

    private var pixelThresholdView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showPixelThresholdInfo,
          addSpacer: { addSpacer },
          infoText: """
            The pixel threshold is a factor used to weed out pixels that are statistically too much brigher than other aligned pixels at the same location.  Lower values like 0.5 get rid of more brighter pixels, higher values like 2.0 will allow more brighter pixels to pass through.  Used for both the subtraction image and for calculating what pixel values to replace airplanes with.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Pixel Threshold:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.pixelThreshold,
                      minValue: 0.001,
                      maxValue: 10,
                      allowDecimal: true,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .pixelThreshold,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var alignmentGroundHorizonExtensionView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentGroundHorizonExtensionInfo,
          addSpacer: { addSpacer },
          infoText: """
            Specify a number of pixels to extend the horizon by when aligning the ground.  This can help to make sure that the horizon itself is included in the area to find keypoints.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Ground Horizon Extension:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.alignmentGroundHorizonExtension,
                      minValue: 0,
                      maxValue: 10000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentGroundHorizonExtension,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var alignmentSkyHorizonExtensionView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentSkyHorizonExtensionInfo,
          addSpacer: { addSpacer },
          infoText: """
            Specify a number of pixels to extend the horizon by when aligning the sky.  This can help to avoid finding keypoints on the horizon itself, which moves differently than the sky does throughout videos.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Sky Horizon Extension:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.alignmentSkyHorizonExtension,
                      minValue: 0,
                      maxValue: 10000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentSkyHorizonExtension,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var alignmentMaxKeypointsView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentMaxKeypointsInfo,
          addSpacer: { addSpacer },
          infoText: """
            Specify the maximum number of keypoints that should be considered by the alignment code.  Setting a lower value may speed things up but give worse alignment results.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Max Keypoints:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.alignmentMaxKeypoints,
                      minValue: 4,
                      maxValue: 10000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentMaxKeypoints,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var alignmentWriteDebugImagesViewValueView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentWriteDebugImagesInfo,
          addSpacer: { addSpacer },
          infoText: """
            Turn this on to write out temporary alignment images to help debug what is going on if something is not right.  The files end up in /tmp.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Write Debug Images:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: $viewModel.alignmentWriteDebugImages) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
    }

    private var alignmentAllowEarthAlignmentView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentAllowEarthAlignmentInfo,
          addSpacer: { addSpacer },
          infoText: """
            Try using the experimental earth alignment for moving videos.
            This can help to get rid of things like car headlights if the earth can be aligned properly.  Off by default for now.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Allow Earth Alignment:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: $viewModel.allowEarthAlignment) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
    }

    private var alignmentNeighborThresholdValueView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentNeighborThresholdValueInfo,
          addSpacer: { addSpacer },
          infoText: """
            The Star alignment algorithm computes a mask for keypoint detection in neighbor frames when aligning them to a base image.  When computing this mask, in addition to discarding the ground, the sky is thresholded by this value.  What that means is only areas this bright or brighter will be scanned for keypoints.  This helps focus keypoint detection on the bright stars, and avoid clouds and other atmospheric phenomenon.  Lower values will give more key points on neighboring frames during alignment.  Max value is 255.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Neighbor Image Threshold:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.alignmentNeighborThresholdValue,
                      minValue: 1,
                      maxValue: 255,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentNeighborThresholdValue,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var alignmentNeighborDilateSizeView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentNeighborDilateSizeInfo,
          addSpacer: { addSpacer },
          infoText: """
            The Star alignment algorithm computes a mask for keypoint detection each neighboring frame.  When computing this mask, in addition to discarding the ground, the sky is thresholded by this value.  After thresholding, star will then dilate, or expand, the mask to include the given amount of pixels around the thresholded pixels.  This allows for the keypoint detection to see more of the transition of intensity, which can help keypoint detection.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Neighbor Dilation Size:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.alignmentNeighborDilateSize,
                      minValue: 4,
                      maxValue: 10000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentNeighborDilateSize,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var alignmentBaseImageThresholdValueView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentBaseImageThresholdValueInfo,
          addSpacer: { addSpacer },
          infoText: """
            The Star alignment algorithm computes a mask for keypoint detection in the base image.  When computing this mask, in addition to discarding the ground, the sky is thresholded by this value.  What that means is only areas this bright or brighter will be scanned for keypoints.  This helps focus keypoint detection on the bright stars, and avoid clouds and other atmospheric phenomenon.  Lower values will give more key points on the base image during alignment.  Max value is 255.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Base Image Threshold:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.alignmentBaseImageThresholdValue,
                      minValue: 1,
                      maxValue: 255,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentBaseImageThresholdValue,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var alignmentBaseImageDilateSizeView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentBaseImageDilateSizeInfo,
          addSpacer: { addSpacer },
          infoText: """
            The Star alignment algorithm computes a mask for keypoint detection in the base image.  When computing this mask, in addition to discarding the ground, the sky is thresholded by this value.  After thresholding, star will then dilate, or expand, the mask to include the given amount of pixels around the thresholded pixels.  This allows for the keypoint detection to see more of the transition of intensity, which can help keypoint detection.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Base Image Dilation Size:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.alignmentBaseImageDilateSize,
                      minValue: 4,
                      maxValue: 10000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentBaseImageDilateSize,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
    }

    private var horizonStripWidthView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonStripInfo,
          addSpacer: { addSpacer },
          infoText: """
            When Star is calculating the horizon for a frame, the Otsu Thresholding works better when the image is split up into strips of a smaller width than the full image frame.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Horizon Strip Width:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonStripWidth,
                      minValue: 1,
                      maxValue: 8000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .horizonStripWidth,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
          .disabled(viewModel.sceneType == .skyOnly)
    }

    private var cannyMinThresholdView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showCannyMinThresholdView,
          addSpacer: { addSpacer },
          infoText: """
            When Star is calculating the horizon for a frame, the Canny Edge Detection algorithm can be used to help define a better horizon.
            This value is the min canny threshold.  Lower values give more edges, higher values less.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Canny Min Threshold:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.cannyMinThreshold,
                      minValue: 1,
                      maxValue: 300,
                      allowDecimal: true,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .cannyMinThreshold,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
          .disabled(viewModel.sceneType == .skyOnly || viewModel.useCannyForHorizonDetection == .no)
    }

    private var maxConcurrentHorizonsView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showCannyMinThresholdView,
          addSpacer: { addSpacer },
          infoText: """
            How many horizon calculations should star do at once?  Can be more than the number of cpus, horizon calculation is pretty quick.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Concurrent Horizon Calculations:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.maxConcurrentHorizonCalculations,
                      minValue: 1,
                      maxValue: 300,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .maxConcurrentHorizons,
                      alwaysOpen: true            
                    )
                    Spacer()
                }
            }
        }
          .disabled(viewModel.sceneType == .skyOnly)
    }
    
    private var cannyMaxThresholdView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showCannyMaxThresholdView,
          addSpacer: { addSpacer },
          infoText: """
            When Star is calculating the horizon for a frame, the Canny Edge Detection algorithm can be used to help define a better horizon.
            This value is the max canny threshold.  Lower values give more edges, higher values less.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Canny Max Threshold:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.cannyMaxThreshold,
                      minValue: 1,
                      maxValue: 300,
                      allowDecimal: true,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .cannyMaxThreshold,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.useCannyForHorizonDetection == .no)
    }

    private var horizonVerticalShiftAmountView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonVerticalShiftAmountView,
          addSpacer: { addSpacer },
          infoText: """
            This value is used with Automatic Clean Mode.
            In short, any positive, non zero value here causes Star to scoot the horizon mask up by the given number of pixels before composting the star and earth aligned images for the final result.  The result is that more of the pixels close to the horizon are taken from the earth aligned image.
            The star aligned image doesn't always have the best horizon, as it is aligned with the stars, and the median horizon value may not be steady like is wanted for a video.  The downside is that rising or setting stars will appear to disappear this many pixels before they hit the horizon, as the earth aligned images typically have few if any stars in the sky.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Horizon Shift:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonVerticalShiftAmount,
                      minValue: 0,
                      maxValue: 300,
                      allowDecimal: true,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .horizonVerticalShiftAmount,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cleanMethod == .selective)
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
                HStack {
                    Spacer()
                    Text("Selective Processing Mode:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
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
                    Spacer()
                }
           }
        }
          .disabled(autoPreservationMode == .no)
    }

    private func applySettings() {

        switch self.cleanMethod {
        case .automatic:
            viewModel.cleanMethod = .automatic(autoPreservationMode.boolValue)
        case .selective:
            viewModel.cleanMethod = .selective
        }

        if !viewModel.cleanMethod.usesOutliers {
            viewModel.selectionMode = .none
        }
    }
    
    private func startProcessing() {
        Log.d("processAll Starting processing")
        self.applySettings()
        viewModel.shouldShowProcessingSettings = false
        Log.d("processAll settings applied")
        viewModel.showHorizonBar = false

        viewModel.processAll()
        Log.d("processAll process all returned")
    }
}

// grid row for not enums
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

// grid row for enums
struct EnumInstructionGridRow<E: InstructionOption>: View {

    @Binding var selection: E
    @Binding var showInfo: Bool
    let addSpacer: () -> Bool
    let isPrimary: Bool
    
    init(
      selection: Binding<E>,
      showInfo: Binding<Bool>,
      addSpacer: @escaping () -> Bool,
      isPrimary: Bool = true
    ) {
        self._selection = selection
        self._showInfo = showInfo
        self.addSpacer = addSpacer
        self.isPrimary = isPrimary
    }
    
    var body: some View {
        InstructionGridRow(
          showInfo: $showInfo,
          addSpacer: addSpacer,
          infoView: {
              VStack(alignment: .leading) {
                  ForEach(E.allCases, id: \.id) { item in
                      Text(item.titleText)
                        .foregroundColor(.white)
                        .font(.largeTitle)
                      
                      Text(item.descriptionText)
                        .foregroundColor(.white)
                        .font(.body)
                  }
              }
          },
          contentView: {
              HStack(alignment: .top) {
                  HStack {
                      Spacer()
                      VStack(alignment: .trailing) {
                          Text(E.topTitle)
                            .font(.title2)
                            .foregroundColor(.white)
                            .opacity(isPrimary ? 1.0 : 0.6)
                      }
                  }
                  HStack {
                      Picker("", selection: $selection) {
                          ForEach(E.allCases, id: \.id) { item in
                              Text(item.titleText)
                                .tag(item)
                                .foregroundColor(.white)
                                .help(item.helpText)
                                .opacity(isPrimary ? 1.0 : 0.6)
                          }
                      }
                        .pickerStyle(.inline)
                        .foregroundColor(.white)
                      Spacer()
                  }
                }
            }
        )
    }
}


// base grid row
struct InstructionGridRow<Content: View, InfoContent: View>: View {
    @Environment(\.isEnabled) private var isEnabled

    @Binding var showInfo: Bool
    let addSpacer: () -> Bool
    let infoView: () -> InfoContent
    let contentView: () -> Content

    var body: some View {
        GridRow {
            // --- Column 1 ---
            contentView()
              .opacity(isEnabled ? 1.0 : 0.6)

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
                      .opacity(isEnabled ? 1.0 : 0.6)
                      .onTapGesture {
                          withAnimation { showInfo.toggle() }
                      }
                    if addSpacer() { Spacer() }
                }
            }
        }
    }
}
