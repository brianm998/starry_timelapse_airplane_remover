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
            localized("ui.l1_norm")
        case .L2norm:
            localized("ui.l2_norm")
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
    
    public static var topTitle: String { localized("ui.canny_gradient_method") }
    
    public var helpText: String {
        switch self {
        case .L1norm:
            localized("ui.l1_norm_help")
        case .L2norm:
            localized("ui.l2_norm_help")
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
            localized("ui.yes")
        case .no:
            localized("ui.no")
        }
    }

    public static var topTitle: String { localized("ui.canny_edge_detection") }
    
    public var helpText: String {
        switch self {
        case .yes:
            localized("ui.canny_yes_help")
        case .no:
            localized("ui.canny_no_help")
        }
    }

    public var descriptionText: String {
        switch self {
        case .yes:
            localized("ui.canny_yes_desc")
        case .no:
            localized("ui.canny_no_desc")
        }
    }
}
      
enum SceneType: String, InstructionOption, Identifiable {
    case skyHorizon = "Sky + Horizon"
    case skyOnly = "Sky Only"

    var id: Self { self }

    static var topTitle: String { localized("ui.scene_type") }
    
    var titleText: String {
        switch self {
        case .skyHorizon: localized("scene_type.sky_horizon")
        case .skyOnly:    localized("scene_type.sky_only")
        }
    }

    var helpText: String {
        switch self {
        case .skyOnly:
            localized("ui.sky_only_help")
        case .skyHorizon:
            localized("ui.sky_horizon_help")
        }
    }

    var descriptionText: String {
        switch self {
        case .skyOnly:
            localized("ui.sky_only_desc")
        case .skyHorizon:
            localized("ui.sky_horizon_desc")
        }
    }
}

enum CameraMotion: String, InstructionOption, Identifiable {
    case fixed = "Fixed"
    case moving = "Moving"

    var id: Self { self }

    static var topTitle: String { localized("ui.camera_motion") }
    
    var titleText: String {
        switch self {
        case .fixed:  localized("camera_motion.fixed")
        case .moving: localized("camera_motion.moving")
        }
    }

    var helpText: String {
        switch self {
        case .fixed:
            localized("ui.camera_fixed_help")
        case .moving:
            localized("ui.camera_moving_help")
        }
    }

    var descriptionText: String {
        switch self {
        case .fixed:
            localized("ui.camera_fixed_desc")
        case .moving:
            localized("ui.camera_moving_desc")
        }
    }
}

/// The tabs of the settings sheet, in the order they are shown.  The desktop client's `SettingsTab` is
/// the same list (`gherkin/ui/vectors/constants.json`, `settingsTabs`, which a test on each side reads).
enum SettingsTab: String, CaseIterable, Identifiable {
    /// What the footage is and how it is cleaned: the choices anyone makes, so the sheet opens here.
    case cleaning
    case gpu
    case alignment
    case horizon
    case memory

    /// The one the sheet opens on.
    static let first = SettingsTab.cleaning

    var id: Self { self }

    var titleText: String {
        switch self {
        case .cleaning:  localized("settings_tab.cleaning")
        case .gpu:       localized("settings_tab.gpu")
        case .alignment: localized("settings_tab.alignment")
        case .horizon:   localized("settings_tab.horizon")
        case .memory:    localized("settings_tab.memory")
        }
    }

    /// What a UI test finds the tab by (`gherkin/ui/ids.json`).
    var accessibilityId: String {
        switch self {
        case .cleaning:  "settings.tab.cleaning"
        case .gpu:       "settings.tab.gpu"
        case .alignment: "settings.tab.alignment"
        case .horizon:   "settings.tab.horizon"
        case .memory:    "settings.tab.memory"
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


    @State private var showAlignmentMaxKeypointsInfo = false
    @State private var showAlignmentGroundHorizonExtensionInfo = false
    @State private var showAlignmentSkyHorizonExtensionInfo = false
    @State private var showAlignmentBaseImageDilateSizeInfo = false
    @State private var showAlignmentBaseImageThresholdValueInfo = false
    @State private var showAlignmentNeighborDilateSizeInfo = false
    @State private var showAlignmentNeighborThresholdValueInfo = false

    @State private var showAlignmentKeypointDivisorInfo = false
    @State private var showAlignmentWriteDebugImagesInfo = false
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
    @State private var showCloudAwareMergeInfo = false
    @State private var showAllowEarthAlignmentInfo = false
    @State private var showMaxKeypointOpsInfo = false
    @State private var showMergeStreamingInfo = false
    @State private var showUseGPUForMergeInfo = false
    @State private var showUseGPUForSIFTInfo = false
    @State private var showUseGPUForAKAZEInfo = false

    /// The tab the sheet is showing.  It opens on the first, every time: which tab was last looked at
    /// is not something the next sheet needs to remember.
    @State private var selectedTab: SettingsTab = .first

    private var addSpacer: Bool {
        showCameraMotionInfo || showSceneTypeInfo || showProcessingMethodInfo ||
        showAutoPreservationMethodInfo || showProcessFramesInfo ||
        showNeighborFrameInfo || showPixelThresholdInfo || showProcessingModeInfo ||
        showUseCannyInfo || showCannyMinThresholdView ||
        showCannyMaxThresholdView || showCannyL2GradientView ||
        showStaticNeighborFrameInfo ||
        showMinAlignmentFramesInfo ||
        showAlignmentMaxKeypointsInfo ||
        showAlignmentGroundHorizonExtensionInfo ||
        showAlignmentSkyHorizonExtensionInfo ||
        showAlignmentBaseImageDilateSizeInfo ||
        showAlignmentBaseImageThresholdValueInfo ||
        showAlignmentNeighborDilateSizeInfo ||
        showAlignmentNeighborThresholdValueInfo ||
        showAlignmentKeypointDivisorInfo ||
        showAlignmentWriteDebugImagesInfo ||
        showUseReferenceHorizonSmoothingInfo ||
        showReferenceHorizonSmoothingMaxDistanceInfo ||
        showUseReferenceHorizonBrightnessRefinementInfo ||
        showReferenceHorizonBrightnessRefinementSearchRadiusInfo ||
        showReferenceHorizonBrightnessRefinementHistogramBucketsInfo ||
        showReferenceHorizonNeighborhoodSizeInfo ||
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
        showHorizonFloorInfo ||
        showCloudAwareMergeInfo ||
        showAllowEarthAlignmentInfo ||
        showMaxKeypointOpsInfo ||
        showMergeStreamingInfo ||
        showUseGPUForMergeInfo ||
        showUseGPUForSIFTInfo ||
        showUseGPUForAKAZEInfo
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
        showUseCannyInfo = true
        showCannyMinThresholdView = true
        showCannyMaxThresholdView = true
        showCannyL2GradientView = true
        showAlignmentMaxKeypointsInfo = true
        showAlignmentGroundHorizonExtensionInfo = true
        showAlignmentSkyHorizonExtensionInfo = true
        showAlignmentBaseImageDilateSizeInfo = true
        showAlignmentBaseImageThresholdValueInfo = true
        showAlignmentNeighborDilateSizeInfo = true
        showAlignmentNeighborThresholdValueInfo = true
        showAlignmentKeypointDivisorInfo = true
        showAlignmentWriteDebugImagesInfo = true
        showUseReferenceHorizonSmoothingInfo = true
        showReferenceHorizonSmoothingMaxDistanceInfo = true
        showUseReferenceHorizonBrightnessRefinementInfo = true
        showReferenceHorizonBrightnessRefinementSearchRadiusInfo = true
        showReferenceHorizonBrightnessRefinementHistogramBucketsInfo = true
        showReferenceHorizonNeighborhoodSizeInfo = true
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
        showCloudAwareMergeInfo = true
        showAllowEarthAlignmentInfo = true
        showMaxKeypointOpsInfo = true
        showMergeStreamingInfo = true
        showUseGPUForMergeInfo = true
        showUseGPUForSIFTInfo = true
        showUseGPUForAKAZEInfo = true
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
        showProcessingModeInfo = false
        showUseCannyInfo = false
        showCannyMinThresholdView = false
        showCannyMaxThresholdView = false
        showCannyL2GradientView = false
        showAlignmentMaxKeypointsInfo = false
        showAlignmentGroundHorizonExtensionInfo = false
        showAlignmentSkyHorizonExtensionInfo = false
        showAlignmentBaseImageDilateSizeInfo = false
        showAlignmentBaseImageThresholdValueInfo = false
        showAlignmentNeighborDilateSizeInfo = false
        showAlignmentNeighborThresholdValueInfo = false
        showAlignmentKeypointDivisorInfo = false
        showAlignmentWriteDebugImagesInfo = false
        showUseReferenceHorizonSmoothingInfo = false
        showReferenceHorizonSmoothingMaxDistanceInfo = false
        showUseReferenceHorizonBrightnessRefinementInfo = false
        showReferenceHorizonBrightnessRefinementSearchRadiusInfo = false
        showReferenceHorizonBrightnessRefinementHistogramBucketsInfo = false
        showReferenceHorizonNeighborhoodSizeInfo = false
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
        showCloudAwareMergeInfo = false
        showAllowEarthAlignmentInfo = false
        showMaxKeypointOpsInfo = false
        showMergeStreamingInfo = false
        showUseGPUForMergeInfo = false
        showUseGPUForSIFTInfo = false
        showUseGPUForAKAZEInfo = false
    }
    
    /// Whether the "already processed frames have different settings" confirmation is up.
    @State private var showUpdateConfirmation = false

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
              Text(localized("ui.choose_from_the_following_options_to_let"))
                .lineLimit(nil)
                .font(.largeTitle)
                .foregroundColor(.white)

              // Under the top label, and only over a sequence that has work on disk this
              // change contradicts.  A sequence nothing has been done to is what this whole
              // view was built for, and there is nothing to warn about there.
              if viewModel.settingsContradictFinishedWork {
                  Text(localized("ui.already_processed_frames_have_different_settings"))
                    .font(.title2)
                    .foregroundColor(.red)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .help(localized("ui.already_processed_frames_have_different_settings_help"))
              }

              HStack {
                  Spacer()
                  Button {
                      self.hideAll()
                  } label: {
                      ZStack {
                          Color.white
                            .cornerRadius(10)

                          Text(localized("ui.hide_info"))
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
                          Text(localized("ui.show_info"))
                            .font(.body)
                            .foregroundColor(.white)
                            .padding(10)
                      }
                  }
                    .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                    .fixedSize(horizontal: true, vertical: true)
              }
              
              Space(height: 20)

              // Tabs rather than one long sheet, so none of it is taller than a screen: the
              // choices anyone makes first, then each group of tuning settings on its own.
              StarPicker(selection: $selectedTab) { tab, isEnabled in
                  Text(tab.titleText)
                    .foregroundColor(isEnabled ? .black : .yellow)
                    .accessibilityIdentifier(tab.accessibilityId)
              }

              Space(height: 20)

              // Each tab scrolls by itself.  The id gives every tab its own scroll view, so one
              // opened after another was scrolled down starts at its top rather than wherever
              // the other one was left.
              ScrollView(.vertical) {
                  self.tabContent
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(.trailing, 12)
              }
                .id(selectedTab)
                .frame(minHeight: 300, idealHeight: 480, maxHeight: .infinity)

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

                              Text(localized("ui.dismiss"))
                                .font(.title2)
                                .padding(20)
                          }
                      }
                        .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                        .fixedSize(horizontal: true, vertical: true)
                  }

                  HStack {
                      Button {
                          if showsProgress {
                              Log.d("show progress")
                              showProgress()
                          } else {
                              Log.d("processAll")
                              startProcessing()
                          }
                      } label: {
                          ZStack {
                              Color.blue
                                .cornerRadius(20)

                              // "Update" rather than "Process Now" once there is finished
                              // work this change contradicts, because that is what the
                              // button does then: it does not start a run over an untouched
                              // sequence, it changes one that is already part done.  And
                              // "Show Progress" over a live run it has nothing to change
                              // in, since a second run is exactly what it must not start.
                              Text(showsProgress
                                     ? localized("ui.show_progress")
                                     : viewModel.settingsContradictFinishedWork
                                       ? localized("ui.update")
                                       : localized("ui.process_now"))
                                .font(.title2)
                                .padding(20)
                                .foregroundColor(.white)
                          }
                      }
                        .buttonStyle(PlainButtonStyle()) // XXX these styles suck
                        .fixedSize(horizontal: true, vertical: true)
                        .accessibilityIdentifier("settings.process")

                      Spacer()
                  }
              }
          }
          .frame(minWidth: 1000)
          .padding(20)
          .background(.gray)
          .onAppear {
              // Only when there is not one already.  A settings change the user made and
              // then dismissed without processing is still a change the frames on disk do
              // not have, and re-taking the baseline here would forget it — the run that
              // adopts it is what clears it (see `beginProcessing`).
              if viewModel.settingsSnapshot == nil {
                  viewModel.settingsSnapshot = viewModel.config.config()
              }
          }
          // The clean method is the one setting this view holds locally rather than
          // writing straight through, so without these the warning below could not see it
          // move — the user would switch from automatic to selective, which changes every
          // output frame, and be told nothing.
          .onChange(of: cleanMethod) { self.applySettings() }
          .onChange(of: autoPreservationMode) { self.applySettings() }
          // The whole question as the title, with no message under it.  Splitting it would
          // put the first clause in the bold title and the second in the body, which reads
          // as the same sentence said twice.
          .alert(localized("ui.reprocess_already_processed_frames_question"),
                 isPresented: $showUpdateConfirmation)
          {
              // No first and Yes second.  Measured: the cancel role takes Escape and sits
              // on the left, and Yes takes Return — which is what makes it the default
              // button, and the default button of a macOS alert is the blue one.  Escape
              // therefore lands on the choice that deletes nothing.
              Button(localized("ui.no"), role: .cancel) { finishUpdate(reprocess: false) }
              Button(localized("ui.yes")) { finishUpdate(reprocess: true) }
                .keyboardShortcut(.defaultAction)
          }
    }

    // MARK: - Tabs

    @ViewBuilder
    private var tabContent: some View {
        switch selectedTab {
        case .cleaning:  cleaningTab
        case .gpu:       gpuTab
        case .alignment: alignmentTab
        case .horizon:   horizonTab
        case .memory:    memoryTab
        }
    }

    /// What the footage is, how it is cleaned, and whether the clouds get their own merge: the choices
    /// anyone makes, in the order the questions come.
    private var cleaningTab: some View {
        Grid {
            self.sceneTypeGridRow
            Divider()
            self.cameraMotionGridRow
            Divider()
            self.processingMethodGridRow
            Divider()
            // Selective always reviews outliers, so the next two only mean something under
            // some methods; each greys itself out under the others.
            self.automaticSelectionGridRow
            Divider()
            self.processingModeView
            Divider()
            // Whether clouds come out banded is something anyone shooting a moving sky wants
            // to be able to turn on.
            self.cloudAwareMergeView
        }
    }

    /// This is one of three independent toggles, not a master switch: each controls the one step it
    /// is named for (see `ui.gpu_settings_scope_note`), which is exactly the misreading
    /// `useGPUForMerge` (née `useGPU`) was renamed to avoid at the property-name level.
    private var gpuTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(localized("ui.gpu_settings_scope_note"))
              .font(.body)
              .foregroundColor(.white)
              .opacity(0.8)
              .fixedSize(horizontal: false, vertical: true)
            Text(Config.gpuAccelerationStatusText())
              .font(.body)
              .foregroundColor(.white)
              .opacity(0.8)
              .fixedSize(horizontal: false, vertical: true)
            Grid {
                self.useGPUForMergeView
                Divider()
                self.useGPUForSIFTView
                Divider()
                self.useGPUForAKAZEView
            }
        }
    }

    private var alignmentTab: some View {
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
            self.alignmentKeypointDivisorView
            Divider()
            self.allowEarthAlignmentView
            Divider()
            self.alignmentWriteDebugImagesViewValueView
            Divider()
            self.homographySmoothingEpsilonView
        }
    }

    private var horizonTab: some View {
        Grid {
            self.useCannyEdgeDetectionGridRow
            Divider()
            self.cannyMinThresholdView
            Divider()
            self.cannyMaxThresholdView
            Divider()
            self.l2GradientGridRow
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
    }

    private var memoryTab: some View {
        Grid {
            // Only Custom reads this: the other profiles size the budget
            // themselves (Full 0.85, Balanced 0.60, Light 0.35).
            if viewModel.resourceProfile == .custom {
                self.memoryBudgetFractionView
                Divider()
            }
            self.keypointMultiplierView
            Divider()
            self.outlierMultiplierView
            Divider()
            self.mergeMultiplierView
            Divider()
            self.horizonMultiplierView
            Divider()
            self.horizonFloorView
            Divider()
            self.maxKeypointOpsView
            Divider()
            self.mergeStreamingView
        }
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
          infoText: localized("setting_help.neighbor_frames")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.neighbor_frame_count"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.numberOfAlignedNeighborFrames,
                      minValue: 1,
                      maxValue: viewModel.imageSequenceSize - 1,
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
          infoText: localized("setting_help.static_neighbor_frames")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.static_neighbor_frame_count"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                   EditableNumberView(
                      value: $viewModel.numberStaticNeighborFrames,
                      minValue: 1,
                      maxValue: viewModel.imageSequenceSize - 1,
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
          infoText: localized("setting_help.pixel_threshold")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.pixel_threshold"))
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
          infoText: localized("setting_help.ground_horizon_extension")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.ground_horizon_extension"))
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
          infoText: localized("setting_help.sky_horizon_extension")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.sky_horizon_extension"))
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
          infoText: localized("setting_help.max_keypoints")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.max_keypoints"))
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

    private var alignmentKeypointDivisorView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentKeypointDivisorInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.keypoint_divisor")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.keypoint_divisor"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    EditableNumberView(
                      value: $viewModel.alignmentKeypointDetectionDivisor,
                      minValue: 1,
                      maxValue: 8,
                      allowDecimal: true,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .alignmentKeypointDivisor,
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
          infoText: localized("setting_help.write_debug_images")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.write_debug_images"))
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

    private var alignmentBaseImageThresholdValueView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAlignmentBaseImageThresholdValueInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.base_image_threshold")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.base_image_threshold"))
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
          infoText: localized("setting_help.base_image_dilation_size")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.base_image_dilation_size"))
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

    private var cannyMinThresholdView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showCannyMinThresholdView,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.canny_min_threshold")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.canny_min_threshold"))
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
          infoText: localized("setting_help.homography_smoothing")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.homography_smoothing"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.homographySmoothingEpsilon,
                      minValue: 0,
                      maxValue: 10,
                      allowDecimal: true,
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
          infoText: localized("setting_help.canny_max_threshold")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.canny_max_threshold"))
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

    /// `Config.allowEarthAlignment`: on a moving camera, also line up the ground from frame to frame.  The startup question sets it; the
    /// desktop client's sheet has always had it as a row, and now this one does.
    private var allowEarthAlignmentView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showAllowEarthAlignmentInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.allow_earth_alignment")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.allow_earth_alignment"))
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

    /// `Config.maxConcurrentKeypointOps`: a cap on how many keypoint detections run at once (0 = no cap beyond the memory budget's).
    private var maxKeypointOpsView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showMaxKeypointOpsInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.max_keypoint_ops")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.max_keypoint_ops"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.maxConcurrentKeypointOps,
                      minValue: 0,
                      maxValue: 256,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .maxConcurrentKeypointOps,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
    }

    /// `Config.mergeStreamingThresholdMB`: past this many megabytes of source frames a median merge streams them from scratch files.
    private var mergeStreamingView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showMergeStreamingInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.merge_streaming_mb")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.merge_streaming_mb"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.mergeStreamingThresholdMB,
                      minValue: 0,
                      maxValue: 65536,
                      fullTextProvider: { _ in "" },
                      prefixText: "",
                      suffixTextProvider: { _ in "" },
                      textColor: .white,
                      focusedField: $focusedField,
                      focusField: .mergeStreamingThresholdMB,
                      alwaysOpen: true
                    )
                    Spacer()
                }
            }
        }
    }

    /// `Config.cloudAwareMerge`: a second merge aligned to the motion of the clouds, blended in
    /// where it explains the frame better. Off by default; see the property's doc comment for
    /// what it does, what it costs, and why changing it re-does the star aligned merge.
    private var cloudAwareMergeView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showCloudAwareMergeInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.cloud_aware_merge")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.cloud_aware_merge"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: $viewModel.cloudAwareMerge) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
    }

    /// This whole group is disabled (and each toggle forced to display off, not merely
    /// dimmed-while-still-checked) whenever `Config.isGPUHardwareAvailable` is false, so "off"
    /// and "on but this Mac has no supported GPU" never look the same as "genuinely on." The
    /// hardware status line lives once, on the group's label, rather than repeated under each
    /// toggle — see `Config.gpuAccelerationStatusText()`. Not gated by scene type or camera
    /// motion like most rows in this file; whether the GPU kernels apply is a per-machine
    /// question, not a per-sequence one.
    ///
    /// Named (and labeled) "for merge," not a plain "GPU acceleration," so it reads as one
    /// of three independent toggles rather than a master switch — see
    /// `Config.useGPUForMerge`'s doc comment for why the property itself was renamed away
    /// from `useGPU`.
    private var useGPUForMergeView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showUseGPUForMergeInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.gpu_merge")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.use_gpu_for_merge"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: Binding(
                      get: { Config.isGPUHardwareAvailable && viewModel.useGPUForMerge },
                      set: { viewModel.useGPUForMerge = $0 }
                    )) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
        .disabled(!Config.isGPUHardwareAvailable)
    }

    /// On by default when a GPU is available — see `Config.useGPUForSIFT`'s doc comment for why it
    /// ships behind its own toggle instead of being folded into the one above. Disabled the
    /// same way as `useGPUView` when this machine has no supported GPU.
    private var useGPUForSIFTView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showUseGPUForSIFTInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.gpu_sift")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.use_gpu_for_sift"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: Binding(
                      get: { Config.isGPUHardwareAvailable && viewModel.useGPUForSIFT },
                      set: { viewModel.useGPUForSIFT = $0 }
                    )) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
        .disabled(!Config.isGPUHardwareAvailable)
    }

    /// On by default when a GPU is available — see `Config.useGPUForAKAZE`'s doc comment for why it
    /// ships behind its own toggle instead of being folded into the one above. Disabled the
    /// same way as `useGPUView` when this machine has no supported GPU.
    private var useGPUForAKAZEView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showUseGPUForAKAZEInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.gpu_akaze")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.use_gpu_for_akaze"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Space(width: 10)
                    Toggle(isOn: Binding(
                      get: { Config.isGPUHardwareAvailable && viewModel.useGPUForAKAZE },
                      set: { viewModel.useGPUForAKAZE = $0 }
                    )) {
                        Text("")
                    }
                    Spacer()
                }
            }
        }
        .disabled(!Config.isGPUHardwareAvailable)
    }

    private var useReferenceHorizonSmoothingView: some View {
        @Bindable var viewModel = viewModel
        return InfoTextInstructionGridRow(
          showInfo: $showUseReferenceHorizonSmoothingInfo,
          addSpacer: { addSpacer },
          infoText: localized("setting_help.reference_smoothing")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.reference_horizon_smoothing"))
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
          infoText: localized("setting_help.reference_smoothing_distance")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.reference_smoothing_distance"))
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
          infoText: localized("setting_help.brightness_refinement")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.reference_horizon_brightness_refinement"))
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
          infoText: localized("setting_help.brightness_refinement_search_radius")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.brightness_refinement_search_radius"))
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
          infoText: localized("setting_help.brightness_refinement_buckets")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.brightness_refinement_histogram_buckets"))
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
          infoText: localized("setting_help.neighbourhood_size")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.reference_horizon_neighbourhood_size"))
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
          infoText: localized("setting_help.spike_removal")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.horizon_spike_removal"))
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
          infoText: localized("setting_help.spike_max_width")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.spike_max_width_columns"))
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
          infoText: localized("setting_help.spike_max_deviation")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.spike_max_deviation_fraction"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    EditableNumberView(
                      value: $viewModel.horizonSpikeMaxDeviationFraction,
                      minValue: 0.001,
                      maxValue: 0.5,
                      allowDecimal: true,
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
          infoText: localized("setting_help.spike_window_half")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.spike_detection_window_half"))
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
          infoText: localized("setting_help.selective_processing_mode")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.selective_processing_mode"))
                      .font(.title2)
                      .foregroundColor(.white)
                      .opacity(0.6)
                }
                HStack {
                    Picker("", selection: $viewModel.detectionType) {
                        ForEach(DetectionType.allCases, id: \.self) { value in
                            Text(value.localizedName).tag(value)
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
          // Selective always uses outliers, whatever auto-preservation was left at
          .disabled(cleanMethod == .automatic && autoPreservationMode == .no)
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
    
    /// Whether the button reports on the run that is going rather than starting one.
    ///
    /// While a run is going and nothing here contradicts what it has done, there is nothing
    /// for Process Now to do — starting a second run over the same frames is exactly what it
    /// must not do — so it takes the user to the processing status instead, as the left
    /// panel's Status button does.  A change that does contradict finished work keeps the
    /// button as Update: over a live run that is the one thing that makes the change reach
    /// the frames the run has not got to yet.
    private var showsProgress: Bool {
        viewModel.isProcessingFrames && !viewModel.settingsContradictFinishedWork
    }

    /// Close the sheet and put `ProcessingModalView` back over the window.  The sheet goes
    /// first because it sits above the overlay and would hide it.
    private func showProgress() {
        self.applySettings()
        viewModel.shouldShowProcessingSettings = false
        viewModel.processingModalShowing = true
    }

    private func startProcessing() {
        Log.d("processAll Starting processing")
        self.applySettings()
        Log.d("processAll settings applied")

        // Over a sequence with work on disk that this change contradicts, the button is
        // Update and it asks before it acts.  Asked here rather than in the view model
        // because it is a question about this settings session, and the sheet is the only
        // thing that knows one is happening.
        if viewModel.settingsContradictFinishedWork {
            showUpdateConfirmation = true
            return
        }

        viewModel.shouldShowProcessingSettings = false
        viewModel.processAll()
        Log.d("processAll process all returned")
    }

    /// The answer to the confirmation.  Yes throws away what the change invalidated and
    /// builds it again; No keeps it, and the new settings apply only to the frames that are
    /// left.
    private func finishUpdate(reprocess: Bool) {
        viewModel.shouldShowProcessingSettings = false
        viewModel.updateSettingsAndProcess(reprocess: reprocess)
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
                        .fixedSize(horizontal: false, vertical: true)
                      
                      Text(item.descriptionText)
                        .foregroundColor(.white)
                        .font(.body)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
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
          infoText: localized("setting_help.memory_budget")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.memory_budget"))
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
          infoText: localized("setting_help.keypoint_mem")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.keypoint_mem"))
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
          infoText: localized("setting_help.outlier_mem")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.outlier_mem"))
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
          infoText: localized("setting_help.merge_mem")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.merge_mem"))
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
          infoText: localized("setting_help.horizon_mem")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.horizon_mem"))
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
          infoText: localized("setting_help.horizon_floor")
        ) {
            HStack {
                HStack {
                    Spacer()
                    Text(localized("ui.horizon_floor_mb"))
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
                    .help(showInfo ? localized("ui.hide_information") : localized("ui.show_information"))
            }
            .buttonStyle(PlainButtonStyle())

            // --- Column 3 ---
            // Leading-aligned and as wide as the grid gives it: a grid centres a cell narrower than its
            // column, which starts every row's explanation at a different place, and the explanation
            // wraps within this width rather than being cut short.
            HStack {
                if showInfo {
                    infoView()
                } else {
                    Text(localized("ui.show_info"))
                      .foregroundColor(.white)
                      .opacity(isEnabled ? 1.0 : 0.6)
                      .onTapGesture {
                          withAnimation { showInfo.toggle() }
                      }
                    if addSpacer() { Spacer() }
                }
            }
              .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
