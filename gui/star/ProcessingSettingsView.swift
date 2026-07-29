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

    @State private var showAlignmentHalfResolutionKeypointsInfo = false
    @State private var showAlignmentWriteDebugImagesInfo = false
    @State private var showAlignmentAllowEarthAlignmentInfo = false
    @State private var showUseReferenceHorizonSmoothingInfo = false
    @State private var showReferenceHorizonSmoothingMaxDistanceInfo = false
    @State private var showUseReferenceHorizonBrightnessRefinementInfo = false
    @State private var showReferenceHorizonBrightnessRefinementSearchRadiusInfo = false
    @State private var showReferenceHorizonBrightnessRefinementHistogramBucketsInfo = false
    @State private var showReferenceHorizonNeighborhoodSizeInfo = false
    @State private var showHorizonSpikeRemovalEnabledInfo = false
    @State private var showHorizonSpikeMaxWidthInfo = false
    @State private var showHorizonSpikeMaxDeviationFractionInfo = false
    @State private var showHorizonSpikeWindowHalfInfo = false

    @State private var showMaxConcurrentHorizonsView = false
    @State private var showMaxConcurrentKeypointsView = false
    @State private var showMaxConcurrentHomographiesView = false
    @State private var showMaxConcurrentMergesView = false
    @State private var showHomographySmoothingEpsilon = false

    @State private var showMemoryBudgetFractionInfo = false
    @State private var showKeypointMultiplierInfo = false
    @State private var showOutlierMultiplierInfo = false
    @State private var showMergeMultiplierInfo = false
    @State private var showHorizonMultiplierInfo = false
    @State private var showHorizonFloorInfo = false


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
        showAlignmentHalfResolutionKeypointsInfo ||
        showAlignmentWriteDebugImagesInfo ||
        showAlignmentAllowEarthAlignmentInfo ||
        showUseReferenceHorizonSmoothingInfo ||
        showReferenceHorizonSmoothingMaxDistanceInfo ||
        showUseReferenceHorizonBrightnessRefinementInfo ||
        showReferenceHorizonBrightnessRefinementSearchRadiusInfo ||
        showReferenceHorizonBrightnessRefinementHistogramBucketsInfo ||
        showHorizonSpikeRemovalEnabledInfo ||
        showHorizonSpikeMaxWidthInfo ||
        showHorizonSpikeMaxDeviationFractionInfo ||
        showHorizonSpikeWindowHalfInfo ||
        showMaxConcurrentHorizonsView ||
        showMaxConcurrentKeypointsView ||
        showMaxConcurrentHomographiesView ||
        showMaxConcurrentMergesView ||
        showHomographySmoothingEpsilon ||
        showMemoryBudgetFractionInfo ||
        showKeypointMultiplierInfo ||
        showOutlierMultiplierInfo ||
        showMergeMultiplierInfo ||
        showHorizonMultiplierInfo ||
        showHorizonFloorInfo
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
        showAlignmentHalfResolutionKeypointsInfo = true
        showAlignmentWriteDebugImagesInfo = true
        showAlignmentAllowEarthAlignmentInfo = true
        showUseReferenceHorizonSmoothingInfo = true
        showReferenceHorizonSmoothingMaxDistanceInfo = true
        showUseReferenceHorizonBrightnessRefinementInfo = true
        showReferenceHorizonBrightnessRefinementSearchRadiusInfo = true
        showReferenceHorizonBrightnessRefinementHistogramBucketsInfo = true
        showHorizonSpikeRemovalEnabledInfo = true
        showHorizonSpikeMaxWidthInfo = true
        showHorizonSpikeMaxDeviationFractionInfo = true
        showHorizonSpikeWindowHalfInfo = true
        showMaxConcurrentHorizonsView = true
        showMaxConcurrentKeypointsView = true
        showMaxConcurrentHomographiesView = true
        showMaxConcurrentMergesView = true
        showHomographySmoothingEpsilon = true
        showMemoryBudgetFractionInfo = true
        showKeypointMultiplierInfo = true
        showOutlierMultiplierInfo = true
        showMergeMultiplierInfo = true
        showHorizonMultiplierInfo = true
        showHorizonFloorInfo = true
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
        showAlignmentHalfResolutionKeypointsInfo = false
        showAlignmentWriteDebugImagesInfo = false
        showAlignmentAllowEarthAlignmentInfo = false
        showUseReferenceHorizonSmoothingInfo = false
        showReferenceHorizonSmoothingMaxDistanceInfo = false
        showUseReferenceHorizonBrightnessRefinementInfo = false
        showReferenceHorizonBrightnessRefinementSearchRadiusInfo = false
        showReferenceHorizonBrightnessRefinementHistogramBucketsInfo = false
        showHorizonSpikeRemovalEnabledInfo = false
        showHorizonSpikeMaxWidthInfo = false
        showHorizonSpikeMaxDeviationFractionInfo = false
        showHorizonSpikeWindowHalfInfo = false
        showMaxConcurrentHorizonsView = false
        showMaxConcurrentKeypointsView = false
        showMaxConcurrentHomographiesView = false
        showMaxConcurrentMergesView = false
        showHomographySmoothingEpsilon = false
        showMemoryBudgetFractionInfo = false
        showKeypointMultiplierInfo = false
        showOutlierMultiplierInfo = false
        showMergeMultiplierInfo = false
        showHorizonMultiplierInfo = false
        showHorizonFloorInfo = false
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
                          //self.cuncurrentProcessingLimitView
                          //Divider()
                         
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
                                  self.alignmentAllowEarthAlignmentView
                                  Divider()
                                  self.alignmentHalfResolutionKeypointsView
                                  Divider()
                                  self.alignmentWriteDebugImagesViewValueView
                                  Divider()
                                  self.homographySmoothingEpsilonView
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
                                  self.useCannyEdgeDetectionGridRow
                                  Divider()
                                  self.cannyMinThresholdView
                                  Divider()
                                  self.cannyMaxThresholdView
                                  Divider()
                                  self.l2GradientGridRow
                                  Divider()
                                  self.horizonVerticalShiftAmountView
                                  Divider()
                                  self.useReferenceHorizonSmoothingView
                                  Divider()
                                  self.referenceHorizonSmoothingMaxDistanceView
                                  Divider()
                                  self.useReferenceHorizonBrightnessRefinementView
                                  Divider()
                                  self.referenceHorizonBrightnessRefinementSearchRadiusView
                                  Divider()
                                  self.referenceHorizonBrightnessRefinementHistogramBucketsView
                                  Divider()
                                  self.referenceHorizonNeighborhoodSizeView
                                  Divider()
                                  self.horizonSpikeRemovalEnabledView
                                  Divider()
                                  self.horizonSpikeMaxWidthView
                                  Divider()
                                  self.horizonSpikeMaxDeviationFractionView
                                  Divider()
                                  self.horizonSpikeWindowHalfView
                              }
                          } label: {
                              Text("Horizon Settings")
                                .font(.title2)
                                .foregroundColor(.white)
                                .opacity(0.6)
                          }
                          .tint(.secondary)

                          Divider()
                          DisclosureGroup {
                              Grid {
                                  self.memoryBudgetFractionView
                                  Divider()
                                  self.keypointMultiplierView
                                  Divider()
                                  self.outlierMultiplierView
                                  Divider()
                                  self.mergeMultiplierView
                                  Divider()
                                  self.horizonMultiplierView
                                  Divider()
                                  self.horizonFloorView
                              }
                          } label: {
                              Text("Memory Settings")
                                .font(.title2)
                                .foregroundColor(.white)
                                .opacity(0.6)
                          }
                          .tint(.orange)
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
                        .disabled(viewModel.isProcessingFrames)

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

    private var alignmentHalfResolutionKeypointsView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentHalfResolutionKeypointsInfo,
          addSpacer: { addSpacer },
          infoText: """
            Detect keypoints on a half-size copy of each frame instead of the full image.

            Keypoint detection is by far the most memory hungry step, and its cost scales with the number of pixels it is given — about 210 bytes per pixel, or roughly 38x the size of the frame itself.  Halving each dimension quarters the pixel count, which cuts peak memory for this step by around 4x.  On a 42 megapixel sequence that is the difference between about 9GB and about 2GB per frame in flight, which is usually what decides whether a large sequence runs smoothly or thrashes the machine.

            The tradeoff is quality: fewer stars are found, and their positions are less precise, so alignment can be worse on some sequences.  Coordinates are scaled back up to full resolution so everything downstream still works, but the detail lost at half size cannot be recovered.

            Off by default.  Worth trying on high resolution sequences that struggle, and comparing the result against a full resolution run.  Keypoint files are stored separately for each setting, so switching back and forth does not mix the two.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Half Resolution Keypoints:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: $viewModel.alignmentHalfResolutionKeypoints) {
                        Text("")
                    }
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
    
    private var homographySmoothingEpsilonView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHomographySmoothingEpsilon,
          addSpacer: { addSpacer },
          infoText: """
            How close do we want the deviation of neighbor homography to be when smoothing neighbor homography across frames when processing moving videos?  Smaller ε values give more smoothing.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Homography Smoothing ε:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.homographySmoothingEpsilon,
                      minValue: 0,
                      maxValue: 10,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .homographySmothingEpsilon,
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

    private var useReferenceHorizonSmoothingView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showUseReferenceHorizonSmoothingInfo,
          addSpacer: { addSpacer },
          infoText: """
            For moving timelapses with user-defined reference horizon frames, enabling this uses those \
            reference horizons to filter out obviously wrong per-column horizon values on nearby frames. \
            Columns whose detected position is a statistical outlier relative to the reference are \
            replaced by the reference value; columns within normal variation are kept as detected. \
            Frames beyond the max distance window fall through to normal horizon smoothing.
            Only applies when Camera Motion is set to Moving.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Reference Horizon Smoothing:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: $viewModel.useReferenceHorizonSmoothing) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed)
    }

    private var referenceHorizonSmoothingMaxDistanceView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showReferenceHorizonSmoothingMaxDistanceInfo,
          addSpacer: { addSpacer },
          infoText: """
            The maximum number of frames away from a user-defined reference horizon within which \
            reference-based horizon smoothing is applied. For example, a value of 30 means any \
            frame within 30 frames of a reference horizon frame will be smoothed against it. \
            Frames further away than this distance use the normal median-merge horizon smoothing instead.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Reference Smoothing Distance:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.referenceHorizonSmoothingMaxDistance,
                      minValue: 1,
                      maxValue: 10000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .referenceHorizonSmoothingMaxDistance,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonSmoothing)
    }

    private var useReferenceHorizonBrightnessRefinementView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showUseReferenceHorizonBrightnessRefinementInfo,
          addSpacer: { addSpacer },
          infoText: """
            For moving timelapses with user-defined reference horizon frames, enabling this uses the \
            brightness statistics from those reference frames to refine per-pixel sky/ground \
            classification near the horizon. Each pixel within the search radius of the widest known \
            horizon bounds is scored by both its brightness (relative to the reference frame's median \
            sky and ground brightness) and its vertical position, then reclassified as sky or ground. \
            Only applies when Camera Motion is set to Moving.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Reference Horizon Brightness Refinement:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: $viewModel.useReferenceHorizonBrightnessRefinement) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed)
    }

    private var referenceHorizonBrightnessRefinementSearchRadiusView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showReferenceHorizonBrightnessRefinementSearchRadiusInfo,
          addSpacer: { addSpacer },
          infoText: """
            The number of pixels above and below the widest known horizon Y range (across all \
            reference frames) within which brightness+position refinement is applied. Pixels \
            outside this band are left unchanged. Larger values refine more of the image near \
            the horizon; smaller values limit changes to pixels very close to the horizon.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Brightness Refinement Search Radius:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.referenceHorizonBrightnessRefinementSearchRadius,
                      minValue: 1,
                      maxValue: 10000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .referenceHorizonBrightnessRefinementSearchRadius,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonBrightnessRefinement)
    }

    private var referenceHorizonBrightnessRefinementHistogramBucketsView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showReferenceHorizonBrightnessRefinementHistogramBucketsInfo,
          addSpacer: { addSpacer },
          infoText: """
            The number of buckets in the intensity histograms used to classify each pixel as \
            sky or ground during brightness refinement. Each histogram spans the actual \
            intensity range observed in that region (sky or ground) in the nearest reference \
            frames, giving finer resolution within the real data range. Higher values provide \
            more precise intensity matching but require more reference pixels per bucket to be \
            reliable; lower values are more robust when few reference pixels are available.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Brightness Refinement Histogram Buckets:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.referenceHorizonBrightnessRefinementHistogramBuckets,
                      minValue: 2,
                      maxValue: 65536,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .referenceHorizonBrightnessRefinementHistogramBuckets,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonBrightnessRefinement)
    }

    private var referenceHorizonNeighborhoodSizeView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showReferenceHorizonNeighborhoodSizeInfo,
          addSpacer: { addSpacer },
          infoText: """
            The side length of the square neighbourhood used when sampling pixel colour and \
            intensity for reference-horizon statistics and per-pixel refinement. For each pixel, \
            values from the neighbourhood are averaged (excluding pixels on the opposite side of \
            the horizon mask in the stats pass) to produce a more stable colour estimate. Use an \
            odd number (e.g. 1, 3, 5, 7); even values are treated as the next lower odd. Set to \
            1 to use single-pixel sampling. Default is 5 (5×5 neighbourhood).
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Reference Horizon Neighbourhood Size:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.referenceHorizonNeighborhoodSize,
                      minValue: 1,
                      maxValue: 99,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .referenceHorizonNeighborhoodSize,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonBrightnessRefinement)
    }

    private var horizonSpikeRemovalEnabledView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonSpikeRemovalEnabledInfo,
          addSpacer: { addSpacer },
          infoText: """
            When enabled, a spike-removal pass runs after brightness refinement to eliminate \
            narrow upward protrusions (wind turbines, towers, isolated star pixels) from the \
            horizon line.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Horizon Spike Removal:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Toggle(isOn: $viewModel.horizonSpikeRemovalEnabled) {
                        EmptyView()
                    }
                    .toggleStyle(.switch)
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonBrightnessRefinement)
    }

    private var horizonSpikeMaxWidthView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonSpikeMaxWidthInfo,
          addSpacer: { addSpacer },
          infoText: """
            Maximum number of consecutive columns that can be removed as a spike. Runs wider \
            than this are treated as legitimate terrain features (hills, ridgelines) and left \
            unchanged. Increase this value to remove wider structures such as broad tower bases.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Spike Max Width (columns):")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonSpikeMaxWidth,
                      minValue: 1,
                      maxValue: 500,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .horizonSpikeMaxWidth,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonBrightnessRefinement ||
                  !viewModel.horizonSpikeRemovalEnabled)
    }

    private var horizonSpikeMaxDeviationFractionView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonSpikeMaxDeviationFractionInfo,
          addSpacer: { addSpacer },
          infoText: """
            A column is considered a spike when its horizon Y is more than this fraction of the \
            image height above the local median. For example, 0.02 means 2% of image height \
            (≈9 px on a 460 px image, ≈80 px on a 4000 px image). Lower values catch shorter \
            spikes; higher values only remove very tall protrusions.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Spike Max Deviation Fraction:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonSpikeMaxDeviationFraction,
                      minValue: 0.001,
                      maxValue: 0.5,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .horizonSpikeMaxDeviationFraction,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonBrightnessRefinement ||
                  !viewModel.horizonSpikeRemovalEnabled)
    }

    private var horizonSpikeWindowHalfView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonSpikeWindowHalfInfo,
          addSpacer: { addSpacer },
          infoText: """
            Half-width of the local-median window (in columns) used to establish the reference \
            horizon level for spike detection. A larger window is more robust because the spike \
            value itself is a smaller fraction of the median sample, so it has less influence on \
            the reference level. Reduce if the horizon changes rapidly across the frame.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Spike Detection Window Half:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonSpikeWindowHalf,
                      minValue: 10,
                      maxValue: 2000,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .horizonSpikeWindowHalf,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
        .disabled(viewModel.sceneType == .skyOnly || viewModel.cameraMotion == .fixed ||
                  !viewModel.useReferenceHorizonBrightnessRefinement ||
                  !viewModel.horizonSpikeRemovalEnabled)
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


// MARK: - Memory rows

extension ProcessingSettingsView {

    private var memoryBudgetFractionView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showMemoryBudgetFractionInfo,
          addSpacer: { addSpacer },
          infoText: """
            The fraction of total physical RAM that Star is allowed to reserve for in-flight operations. \
            Values range from 0.1 (10%) to 0.95 (95%). The default of 0.85 leaves the OS and other apps \
            roughly 15% headroom.

            Lowering this value reduces the number of operations that can run concurrently, \
            which prevents RAM exhaustion on machines shared with other heavy apps. \
            Raising it can increase throughput if your system is mostly idle.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Memory Budget:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.memoryBudgetFraction,
                      minValue: 0.1,
                      maxValue: 0.95,
                      allowDecimal: true,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .memoryBudgetFraction,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
    }

    private var keypointMultiplierView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showKeypointMultiplierInfo,
          addSpacer: { addSpacer },
          infoText: """
            How many times the raw frame size (in bytes) to reserve per keypoint detection operation.

            Keypoint detection (SIFT/AKAZE) builds a multi-octave Gaussian pyramid and keeps the full \
            frame plus working buffers in memory. For 33 MP 16-bit images this can easily reach 6–10 GB \
            per operation.

            Raise this value if your system thrashes during keypoint detection — it reduces the number \
            of concurrent operations allowed. Lower it if you have abundant RAM and want more throughput.
            Default: 42, measured one operation at a time in a fresh process: 38x the frame at \
            12 megapixels, 38x at 24 and 40x at 42, so 42 leaves only a little room to spare \
            at the largest sizes. Not a value to lower.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Keypoint Mem ×:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.keypointMemoryMultiplier,
                      minValue: 1,
                      maxValue: 200,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .keypointMemoryMultiplier,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
    }

    private var outlierMultiplierView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showOutlierMultiplierInfo,
          addSpacer: { addSpacer },
          infoText: """
            How many times the raw frame size (in bytes) to reserve per outlier-detection operation.

            Outlier detection subtracts the star-aligned frame from the original and blobs the \
            difference. The blobber is the bulk of it, and unlike the other steps its cost \
            depends on the picture, not just its size: it keeps one record per bright pixel, so \
            a frame with a lot of residual left after alignment costs much more than a clean one. \
            Measured one operation at a time in a fresh process, the blobber alone ran 1.3x the \
            frame with nothing bright in it, 5.4x at a tenth of a percent of pixels bright, and \
            7x at the worst density tried. The original and a copy of the subtraction image's \
            pixels sit on top of that throughout. It also builds the aligned frame if that is \
            not on disk yet.

            Raise this if you see heavy swap usage during the outlier phase, especially on hazy \
            sequences or ones that align poorly. Default: 9, plus the neighbor count of any merge \
            inside the op that is small enough to keep all of its source frames in memory (see \
            the merge streaming threshold).
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Outlier Mem ×:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.outlierMemoryMultiplier,
                      minValue: 1,
                      maxValue: 50,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .outlierMemoryMultiplier,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
    }

    private var mergeMultiplierView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showMergeMultiplierInfo,
          addSpacer: { addSpacer },
          infoText: """
            How many times the raw frame size (in bytes) to reserve per merge operation.

            The merge step composites the final output frame from the original and the \
            star-aligned frame, building that aligned frame first if it is not on disk yet. \
            The aligned build warps each neighbor in turn and spills it to a scratch file, so \
            its cost no longer grows with the number of neighbors.

            Raise this if you see thrashing during the merge phase. Default: 6, plus the neighbor \
            count of any merge inside the op that is small enough to keep all of its source \
            frames in memory (see the merge streaming threshold).
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Merge Mem ×:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.mergeMemoryMultiplier,
                      minValue: 1,
                      maxValue: 50,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .mergeMemoryMultiplier,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
    }

    private var horizonMultiplierView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonMultiplierInfo,
          addSpacer: { addSpacer },
          infoText: """
            How many times the frame size (in bytes) to reserve per horizon-detection operation.

            Unlike the other multipliers, this one is a poor fit for the work it describes. \
            Horizon detection runs its base methods on a 512-pixel-wide copy of the frame and \
            caps the refinement step at 4096 wide, so its cost barely changes with the size of \
            the frame you give it — measured one op at a time in a fresh process, 424MB at 6 \
            megapixels against 966MB at 42, for seven times the pixels.

            Because of that, the small end is covered by the horizon reservation floor below \
            rather than by raising this. Raising it to cover 6 megapixels would need 13x, and \
            13x at 42 megapixels would reserve close to 3GB for an operation that needs 1GB. \
            Default: 7, calibrated at 24 megapixels.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Horizon Mem ×:")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonMemoryMultiplier,
                      minValue: 1,
                      maxValue: 50,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .horizonMemoryMultiplier,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
    }

    private var horizonFloorView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showHorizonFloorInfo,
          addSpacer: { addSpacer },
          infoText: """
            The least memory, in megabytes, to reserve for one horizon-detection operation, \
            whatever the horizon multiplier above works out to.

            This exists because a horizon operation costs about the same no matter how big the \
            frame is, so a plain multiple of the frame comes out too small on small frames. \
            Measured one operation at a time in a fresh process, the multiplier alone covered \
            only 57% of what one operation needed at 6 megapixels and 76% at 12, while covering \
            133% at 24 and 175% at 42. Under-reserving is the harmful direction: it lets too \
            many operations run at once and the machine runs out of memory.

            Default: 900MB, which stops mattering at about 17 megapixels, where the multiplier \
            grows past it — so this only affects smaller frames, and changes nothing at the size \
            the multiplier was calibrated on. Raise it if a small-frame sequence still thrashes \
            during the horizon phase. Set it to 0 to use the multiplier alone.
            """
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text("Horizon Floor (MB):")
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonReservationFloorMB,
                      minValue: 0,
                      maxValue: 16384,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .horizonReservationFloorMB,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
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
