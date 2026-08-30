import Foundation
import SwiftUI
import Cocoa
import StarCore
import Semaphore
import logging
import StarCppBridge

public enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
}

enum HorizonPainterMode: Sendable {
    case normal
    case startup
}

public enum ToolType: String, Equatable, CaseIterable {
    case remove
    case keep
    case razor
    case shovel
    case trash
    case removeFromTrash
    case multi
    case information
    case none
    
    var localizedName: String {
        localized("tool.\(rawValue)")
    }

    public static var allCases: [ToolType] {
        [
          .remove,
          .keep,
          .razor,
          .shovel,
          .trash,
          .removeFromTrash,
          .multi,
          .information
        ]
    }
    
    var iconName: String {
        switch self {
        case .remove:
            return "remove_icon"
        case .keep:
            return "keep_icon"
        case .razor:
            return "razor_icon"
        case .shovel:
            return "shovel_icon"
        case .trash:
            return "add_to_trash_icon"
        case .removeFromTrash:
            return "remove_from_trash_icon"
        case .multi:
            return "multi_choice_icon"
        case .information:
            return "info_icon"
        case .none:
            return "shovel_icon"
        }
    }

    var displayName: String {
        switch self {
        case .remove:
            return localized("tool.remove")
        case .keep:
            return localized("tool.keep")
        case .razor:
            return localized("tool.razor")
        case .shovel:
            return localized("tool.shovel")
        case .trash:
            return localized("tool.trash")
        case .removeFromTrash:
            return localized("tool.removeFromTrash")
        case .multi:
            return localized("tool.multi")
        case .information:
            return localized("tool.information")
        case .none:
            return localized("tool.none")
        }
    }
}

public enum InteractionMode: String, Equatable, CaseIterable {
    case edit
    case scrub
    case grid

    var localizedName: String {
        localized("interaction_mode.\(rawValue)")
    }
}

// used to limit processing of frames to this max concurrent number
public let frameProcessingMonitor = FileSystemMonitor(max: 32) // XXX make this configurable

// view model for a sequence of images
@MainActor @Observable
public final class ImageSequenceViewModel {
    let config: ConfigManager

    /// A view onto the one live copy, not a copy of it — see `UserPreferencesStore`.
    var userPreferences: UserPreferences {
        get { UserPreferencesStore.shared.preferences }
        set {
            UserPreferencesStore.shared.preferences = newValue
            applyUserPreferences()
        }
    }

    /// Seed the video settings this view model works from with whatever the preferences hold.
    ///
    /// Called on every write through `userPreferences` — which is what the `didSet` on the
    /// old stored property did — and by `ViewModel` on a freshly opened sequence, whose
    /// settings start at their defaults until this runs.
    func applyUserPreferences() {
        if let detectionType = userPreferences.processingType {
            self.detectionType = detectionType
        }
        if let frameRate = userPreferences.frameRate {
            self.frameRate = frameRate
        }
        if let codec = userPreferences.codec {
            self.codec = codec
        }
        if let encoder = userPreferences.encoder {
            self.encoder = encoder
        }
        if let pixelFormat = userPreferences.pixelFormat {
            self.pixelFormat = pixelFormat
        }
        if let muxer = userPreferences.muxer {
            self.muxer = muxer
        }
    }

    // how far zoomed in the edit view is.
    // 1 is pixel to pixel, less than one is smaller.
    var currentZoomScale: CGFloat = 1
    var minZoomScale: CGFloat = 0.1
    var maxZoomScale: CGFloat = 1

    // use these if nothing is in the config
    var frameRate: FrameRate = .fps_24
    var codec: FFmpegCodec = .prores
    var encoder: FFmpegEncoder = .prores
    var pixelFormat: FFmpegPixelFormat = .yuv444p10le
    var muxer: FFmpegMuxer = .mov
    var hasAudio = false
    
    var noImageExplainationText: String = localized("ui.loading_ellipsis")

    var backgroundColor = ViewModel.defaultBackgroundColor

    var frameStateMap: [FrameProcessingState: Set<FrameAirplaneRemover>] = [:]

    // XXX report this from processAll
    var sequenceProcessingState: SequenceProcessingState = .unprocessed

    // bumped on Stop so in-flight processAll closures know to ignore their final state write
    private var processingGeneration = 0

    // the number of frames that are the given processing state
    func count(for state: FrameProcessingState) -> Int {
        self.frameStateMap[state]?.count ?? 0
    }
    
    var frameSaveQueue = FrameSaveQueue()

    var frameOpacity: Double = 1.0
    
    var videoPlayMode: VideoPlayMode = .forward
    
    var videoPlaying = false

    var leftPanelShowing = true
    var rightPanelShowing = true

    func toggleSidePanels() {
        if leftPanelShowing && rightPanelShowing {
            leftPanelShowing = false
            rightPanelShowing = false
        } else {
            leftPanelShowing = true
            rightPanelShowing = true
        }
    }
    
    var fastAdvancementType: FastAdvancementType = .normal

    // if fastAdvancementType == .normal, fast forward and reverse do a set number of frames
    var fastSkipAmount = 20
    
    var frameWidth: CGFloat = 600 // placeholders until first frame is read
    var frameHeight: CGFloat = 450

    // how long the arrows are
    var outlierArrowLength: CGFloat = 70 // relative to the frame width above

    let finalProcessingCount = CountActor()
    
    var detectionType = DetectionType.strong

    var frameSize: CGSize {
        var ret = CGSize()
        ret.width = frameWidth
        ret.height = frameHeight
        return ret
    }
    
    var arrowLength: CGFloat {
        self.frameWidth/self.outlierArrowLength
    }
    
    var arrowHeight: CGFloat {
        self.frameWidth/self.outlierArrowHeight
    }

    var lineWidth: CGFloat { self.arrowHeight/8 }

    // how high they are (if pointing sideways)
    var outlierArrowHeight: CGFloat = 180
    
    // view class for each frame in the sequence in order
    var frames: [FrameViewModel] = []

    weak var topViewModel: ViewModel? = nil

    var showErrorAlert = false
    var errorMessage: String = ""

    func report(error: String) {
        self.showErrorAlert = true
        self.errorMessage = error
        topViewModel?.report(error: error)
    }

    var initialLoadInProgress = false
    var loadingAllOutliers = false
    var loadingOutliers = false
    
    var numberOfFramesWithOutliersLoaded = 0
    
    var numberOfFramesLoaded = 0

    var outlierGroupTableRows: [OutlierGroupTableRow] = []
    var outlierGroupWindowFrame: FrameAirplaneRemover?

    var selectedOutliers = Set<OutlierGroupTableRow.ID>()

    var selectionMode = ToolType.remove {
        didSet {
            if selectionMode == .removeFromTrash {
                shouldShowTrash = true
            }
        }
    }
    var renderingCurrentFrame = false

    var isProcessingFrames = false
    var numberOfFramesProcessed = 0

    var isRenderingVideo = false

    var hasPendingWork: Bool {
        isProcessingFrames ||
        isRenderingVideo ||
        frameSaveQueue.savingCount > 0 ||
        frameSaveQueue.pendingSavingCount > 0 ||
        frameSaveQueue.purgatoryCount > 0
    }

    var pendingWorkDescription: String {
        var parts: [String] = []
        if isProcessingFrames { parts.append(localized("ui.pending.processing_frames")) }
        if isRenderingVideo { parts.append(localized("ui.pending.rendering_video")) }
        let saving = frameSaveQueue.savingCount + frameSaveQueue.pendingSavingCount + frameSaveQueue.purgatoryCount
        if saving > 0 {
            parts.append(saving == 1
                           ? localized("ui.pending.saving_frame_one")
                           : localized("ui.pending.saving_frames_many", saving))
        }
        return parts.joined(separator: ", ")
    }
    
    var ignoreLowerPixels: CGFloat = 0

    var outlierOpacity = 1.0

    var trashOpacity = 0.7

    var interactionMode: InteractionMode = .scrub

    // Multi-frame selection. Always contains currentIndex when non-empty.
    // Count > 1 means a genuine multi-selection is active.
    var selectedFrameIndices: Set<Int> = []

    var isMultiSelecting: Bool { selectedFrameIndices.count > 1 }

    var sortedSelectedIndices: [Int] { selectedFrameIndices.sorted() }

    // Scale factor for grid-mode cells relative to the preview image size
    var gridThumbnailScale: CGFloat = 0.3

    // The scale at which gridHorizonOverlay was last generated on each frame.
    // Zero means it has never been generated.
    var gridHorizonRenderedScale: CGFloat = 0

    /// Regenerate grid horizon overlays on all frames that have horizon data,
    /// sized to match the current grid cell dimensions at `scale`.
    func refreshGridHorizonOverlays(at scale: CGFloat) {
        gridHorizonRenderedScale = scale
        let w = max(1, Int(CGFloat(config.config().previewWidth)  * scale))
        let h = max(1, Int(CGFloat(config.config().previewHeight) * scale))
        for frameView in frames where frameView.horizonOverlay != nil {
            frameView.refreshGridHorizonOverlay(width: w, height: h)
        }
    }

    var previousInteractionMode: InteractionMode = .scrub

    var previousFrameViewMode = FrameViewMode.final

    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    var showFullResolution = false

    var showFilmstrip = true

    // causes tapping an outlier to open a dialog with multiple choices
    var multiChoice = false
    
    var updatingFrameBatch = false

    var videoPlaybackFramerate = 30

    var multiSelectSheetShowing = false

    var renderVideoSheetShowing = false

    // when true, the next presentation of `renderVideoSheetShowing` should
    // immediately kick off rendering with the current settings instead of
    // showing the settings/choice view.
    var renderVideoAutoStart = false

    // controls the "render video after processing?" sheet shown before
    // processing begins.
    var preProcessingRenderPromptShowing = false

    // controls the "processing complete, render video?" sheet shown after
    // processing finishes.
    var postProcessingRenderPromptShowing = false

    // set by the pre-processing prompt's "Yes" button — when processing
    // finishes successfully, automatically start a video render.
    private var autoRenderAfterProcessing = false

    /// When `true` the horizon-painting overlay is shown over the frame view.
    var isShowingHorizonPainter = false

    /// Differentiates how the horizon painter was opened.
    var horizonPainterMode: HorizonPainterMode = .normal

    /// Which screen the startup sheet should display.  Owned by the view model
    /// (rather than `@State` inside `StartupView`) so that the painter exit
    /// flow can re-route the sheet synchronously without racing against
    /// SwiftUI's `.onAppear` on sheet re-presentation.
    var startupState: StartupState = .horizon

    /// Frame indices (in the sequence) that the user has chosen to paint horizons for
    /// during the startup flow. Empty for the static single-frame case.
    var horizonPainterStartupFrameIndices: [Int] = []

    /// Which position in `horizonPainterStartupFrameIndices` is currently being painted.
    var horizonPainterStartupFramePosition: Int = 0

    /// Last sky/ground brush mode chosen by the user in the horizon painter.
    /// Persisted here so it survives the painter being closed and reopened.
    var horizonPainterIsErasing: Bool = false

    /// Mirror `horizonPainterStartupFrameIndices` / `...FramePosition` into the config, so a
    /// selection the user is part way through survives the session.
    ///
    /// Written on every step rather than once at the end, because the session this protects
    /// against does not get to run any cleanup: it was killed, or quit, mid-paint.
    private func recordStartupHorizonProgress() {
        var cfg = config.config()
        cfg.startupHorizonFrameIndices = horizonPainterStartupFrameIndices
        cfg.startupHorizonFramePosition = horizonPainterStartupFramePosition
        config.update(cfg)
    }

    /// Called by the horizon painter toolbar when the user confirms a horizon
    /// during the startup flow — marks the reference saved and advances to the
    /// removal step.  For static sequences also sets the hasStaticReferenceHorizon flag.
    func continueToRemovalFromHorizonPainter() {
        if !config.config().tripodHeadWasMoving {
            var cfg = config.config()
            cfg.hasStaticReferenceHorizon = true
            config.update(cfg)
            // Refresh every frame so the filmstrip thumbnails and the main
            // frame edit view both pick up the global reference horizon and
            // display it as a blue line.

            for frameView in frames {
                frameView.refreshHorizonOverlay()
                frameView.refreshFrameHorizonOverlay()
            }
        }
        horizonPainterMode = .normal
        horizonPainterStartupFrameIndices = []
        horizonPainterStartupFramePosition = 0
        recordStartupHorizonProgress()   // now empty: nothing left to resume
        startupState = .removal
        isShowingHorizonPainter = false
        shouldShowInitialInstructions = true
    }

    /// Called by the horizon painter toolbar Cancel in startup flow — returns
    /// the user to the "Was the camera moving?" question.
    func returnToMovingViewFromHorizonPainter() {
        horizonPainterMode = .normal
        horizonPainterStartupFrameIndices = []
        horizonPainterStartupFramePosition = 0
        recordStartupHorizonProgress()   // the user backed out; there is nothing to resume
        startupState = .moving
        isShowingHorizonPainter = false
        shouldShowInitialInstructions = true
    }

    /// Begins the moving-video startup horizon flow: calculates evenly-spaced frame
    /// indices, navigates to the first one, and opens the painter.
    func startMovingHorizonStartupFlow(count: Int) {
        let indices = Self.calculateFrameIndices(count: count, total: imageSequenceSize)
        horizonPainterStartupFrameIndices = indices
        horizonPainterStartupFramePosition = 0
        recordStartupHorizonProgress()
        if let first = indices.first { currentIndex = first }
        horizonPainterMode = .startup
        shouldShowInitialInstructions = false
        isShowingHorizonPainter = true
    }

    /// Begins the static single-horizon startup flow — `SelectHorizonView`'s "Yes".
    ///
    /// The one frame goes through the same list as the moving flow's several, so that an
    /// interrupted session resumes by the same route.  A one element list changes nothing
    /// downstream: everything that distinguishes the two flows asks for `count > 1`, and the
    /// painter's "is there another frame after this one" test is false either way.
    func startStaticHorizonStartupFlow() {
        horizonPainterStartupFrameIndices = [currentIndex]
        horizonPainterStartupFramePosition = 0
        recordStartupHorizonProgress()
        horizonPainterMode = .startup
        shouldShowInitialInstructions = false
        isShowingHorizonPainter = true
    }

    /// Re-open a hand-painted horizon selection the last session did not finish, putting the
    /// painter back on the frame it stopped at.
    ///
    /// Returns whether it took over.  When it did, the caller must not raise the re-open
    /// progress panel or start processing: the horizons the user asked to define are still
    /// missing, and running without them silently substitutes the automatic detection they
    /// had already turned down.
    ///
    /// The painted horizons themselves are already on disk in `horizonReference/`, so
    /// nothing is re-painted — only the frames after `startupHorizonFramePosition` are
    /// still to do.
    func resumeStartupHorizonSelectionIfUnfinished() -> Bool {
        let cfg = config.config()
        let indices = cfg.startupHorizonFrameIndices
        let position = cfg.startupHorizonFramePosition
        guard let frameIndex = Self.startupHorizonResumeFrame(indices: indices,
                                                              position: position,
                                                              frameCount: frames.count)
        else { return false }

        Log.i("resuming hand painted horizon selection at \(position + 1) of \(indices.count)")

        horizonPainterStartupFrameIndices = indices
        horizonPainterStartupFramePosition = position
        currentIndex = frameIndex
        horizonPainterMode = .startup
        shouldShowInitialInstructions = false
        // The painter is an overlay on `FrameEditView`, which only exists in edit mode — a
        // re-opened sequence starts in `.scrub`, where setting the flag below would show
        // nothing at all.  Same trap as the sheets; see `enterEditMode`.
        interactionMode = .edit
        isShowingHorizonPainter = true
        return true
    }

    /// The frame a recorded horizon selection should resume on, or nil when there is
    /// nothing to resume.
    ///
    /// Nil for a selection that was never started (empty list) or that ran to the end (the
    /// list is cleared then, so a position past it means the record is inconsistent) — and
    /// for a frame the sequence does not have.  That last one is not paranoia for its own
    /// sake: config.json can be hand edited, and a sequence can be re-extracted at a
    /// different length while its config survives, either of which would trap on `frames[]`.
    static func startupHorizonResumeFrame(indices: [Int],
                                          position: Int,
                                          frameCount: Int) -> Int?
    {
        guard position >= 0, position < indices.count else { return nil }
        let frameIndex = indices[position]
        guard frameIndex >= 0, frameIndex < frameCount else {
            Log.w("startup horizon selection names frame \(frameIndex) of \(frameCount); not resuming")
            return nil
        }
        return frameIndex
    }

    /// Advances to the next frame in the startup horizon flow.  Called after the
    /// user hits Continue on a frame that still has successors.
    func advanceToNextStartupHorizonFrame() {
        horizonPainterStartupFramePosition += 1
        recordStartupHorizonProgress()
        guard horizonPainterStartupFramePosition < horizonPainterStartupFrameIndices.count else { return }
        currentIndex = horizonPainterStartupFrameIndices[horizonPainterStartupFramePosition]
        // FrameEditView watches currentIndex while painter is open in startup mode
        // and resets the HorizonPaintState for the new frame automatically.
    }

    /// How many reference horizons to suggest painting for a moving sequence of `total`
    /// frames.  A moving camera drifts further over a longer sequence, so one reference is
    /// never enough, but asking for one every N frames makes the suggestion grow without
    /// bound: a 5000 frame sequence would ask for over forty hand painted horizons.
    ///
    /// `sqrt(total/10)` grows slowly enough to stay reasonable while still tracking the
    /// length: 12 for the 1450 frame sequence that 12 was measured to work well on, 14 at
    /// 2000, 22 at 5000.  The floor of 3 keeps the old fixed suggestion for anything under
    /// about 120 frames, where the spacing is already tight.
    ///
    /// A suggestion only — the stepper beside it lets the user pick any count up to `total`,
    /// and what they pick is remembered as a multiple of this baseline.  See
    /// `preferredMovingHorizonCount(total:multiplier:)`.
    static func suggestedMovingHorizonCount(total: Int) -> Int {
        guard total > 0 else { return 1 }
        let scaled = Int((Double(total) / 10).squareRoot().rounded())
        return min(max(3, scaled), total)
    }

    /// `suggestedMovingHorizonCount(total:)` bent by what the user picked last time, as
    /// recorded in `UserPreferences.movingHorizonCountMultiplier`.  A `nil` multiplier —
    /// the user has never moved the stepper — leaves the suggestion alone.
    ///
    /// The floor of 3 in the baseline deliberately does not apply here: a user who asked for
    /// fewer references than star suggests gets fewer, down to one.  The result is still
    /// bounded by the sequence, since the stepper cannot offer more horizons than frames.
    static func preferredMovingHorizonCount(total: Int, multiplier: Double?) -> Int {
        let baseline = suggestedMovingHorizonCount(total: total)
        guard let multiplier, multiplier > 0, multiplier.isFinite else { return baseline }
        let ceiling = max(1, total)
        // capped as a Double before it becomes an Int: nothing stops a hand-edited
        // preferences file from holding a multiplier that scales past what an Int can
        // hold, and that conversion traps rather than clamping
        let scaled = (Double(baseline) * multiplier).rounded()
        guard scaled < Double(ceiling) else { return ceiling }
        return max(1, Int(scaled))
    }

    /// What to record when the user picks `chosen` horizons for a sequence of `total` frames:
    /// how their choice compares to what star suggested for that length.
    ///
    /// Deliberately unclamped.  A multiplier is only ever produced from a count the user
    /// actually dialled in, and clamping it would mean re-opening that same sequence offered
    /// a different number than the one they chose.
    static func movingHorizonCountMultiplier(chosen: Int, total: Int) -> Double {
        Double(chosen) / Double(suggestedMovingHorizonCount(total: total))
    }

    /// The horizon count to offer for this sequence, personalised by the stored preference.
    var preferredMovingHorizonCount: Int {
        Self.preferredMovingHorizonCount(total: imageSequenceSize,
                                         multiplier: userPreferences.movingHorizonCountMultiplier)
    }

    /// Remember that the user asked for `chosen` horizons on a sequence this long, so that a
    /// sequence of a different length gets proportionally more or fewer next time.  Called on
    /// every step, so the preference survives even if the user abandons the prompt afterwards.
    func recordMovingHorizonCount(_ chosen: Int) {
        userPreferences.movingHorizonCountMultiplier =
          Self.movingHorizonCountMultiplier(chosen: chosen, total: imageSequenceSize)
    }

    private static func calculateFrameIndices(count: Int, total: Int) -> [Int] {
        guard count > 0, total > 0 else { return [] }
        if count == 1 { return [0] }
        if count >= total { return Array(0..<total) }
        return (0..<count).map { i in
            Int((Double(i) * Double(total - 1) / Double(count - 1)).rounded())
        }
    }

    var showAllFrameViewModes = false
    var showAllFrameProcessingStates = false
    var showAllImageCacheStats = false

    var multiSelectionType: MultiSelectionType = .all
    var multiSelectionRemovalType: MultiSelectionRemovalType = .keep

    var multiChoiceSheetShowing = false
    var multiChoicePaintType: MultiChoicePaintType = .keep
    var multiChoiceType: MultiSelectionType = .all

    // the outlier grop we're starting a multi choice from
    var multiChoiceOutlierView: OutlierGroupView?
    
    var selectionStart: CGPoint? 
    var selectionEnd: CGPoint?
    
    var number_of_frames: Int = 50

    // the frame number of the frame we're currently showing
    var currentIndex = 0 {
        didSet {
            if currentIndex >= 0,
               currentIndex < self.frames.count
            {
                if let method = self.frames[currentIndex].frameObserver.cleanMethod {
                    switch method {
                    case .automatic(let useOutliers):
                        self._currentFrameHighLevelCleanMethod = .automatic
                        self._currentFrameAutoPreservationMode = useOutliers ? .yes : .no
                        
                    case .selective:
                        self._currentFrameHighLevelCleanMethod = .selective
                        self._currentFrameAutoPreservationMode = .no
                    }
                    
                } else {
                    switch self.currentFrameCleanMethod {
                    case .automatic(let useOutliers):
                        self._currentFrameHighLevelCleanMethod = .automatic
                        self._currentFrameAutoPreservationMode = useOutliers ? .yes : .no

                    case .selective:
                        self._currentFrameHighLevelCleanMethod = .selective
                        self._currentFrameAutoPreservationMode = .no
                    }
                }
            }
        }
    }

    // for final processing of outliers
    var numberOfNeighborFrames: Int {
        didSet {
            var realConfig = config.config()
            realConfig.numberFinalProcessingNeighborsNeeded = numberOfNeighborFrames
            config.update(realConfig)
        }
    }

    // used when camera is not moving for merging earth
    var numberStaticNeighborFrames: Int {
        didSet {
            var realConfig = config.config()
            realConfig.numberStaticNeighborFrames = numberStaticNeighborFrames
            config.update(realConfig)
        }
    }

    // for alignment
    var numberOfAlignedNeighborFrames: Int {
        didSet {
            var realConfig = config.config()
            realConfig.numberAlignedNeighborFrames = numberOfAlignedNeighborFrames
            config.update(realConfig)
        }
    }

    var horizonDetectionEnabled: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.horizonDetectionEnabled = horizonDetectionEnabled
            config.update(realConfig)
        }
    }

    var useCannyForHorizonDetection: UseCannyEdgeDetectionForHorizon {
        didSet {
            var realConfig = config.config()
            realConfig.useCannyForHorizonDetection = useCannyForHorizonDetection == .yes
            config.update(realConfig)
        }
    }
    
    var cannyMinThreshold: Double {
        didSet {
            var realConfig = config.config()
            realConfig.cannyMinThreshold = cannyMinThreshold
            config.update(realConfig)
        }
    }
    
    var cannyMaxThreshold: Double {
        didSet {
            var realConfig = config.config()
            realConfig.cannyMaxThreshold = cannyMaxThreshold
            config.update(realConfig)
        }
    }

    var cannyUseL2Gradient: CannyGradientMethod {
        didSet {
            var realConfig = config.config()
            realConfig.cannyUseL2Gradient = cannyUseL2Gradient.cvArgValue
            config.update(realConfig)
        }
    }

    var sceneType: SceneType {
        get {
            if horizonDetectionEnabled {
                .skyHorizon
            } else {
                .skyOnly
            }
        }
        set {
            switch newValue {
            case .skyOnly:
                self.horizonDetectionEnabled = false
            case .skyHorizon:
                self.horizonDetectionEnabled = true
            }
        }
    }
    
    // fallback replacement method if not specified per frame
    var cleanMethod: CleanMethod {
        didSet {
            Log.d("didSet cleanMethod \(cleanMethod)")
            var realConfig = config.config()
            realConfig.cleanMethod = cleanMethod
            config.update(realConfig)

            // Update All Frame View Models
            for frame in frames {
                frame.frameObserver.set(
                  cleanMethod: getCleanMethod(
                    forFrame: frame.frameIndex
                  )
                )
            }
            Log.d("didSet cleanMethod \(cleanMethod) done")
        }
    }

    var currentFrameCleanMethod: CleanMethod {
        getCleanMethod(forFrame: currentIndex)
    }
    
    func getCleanMethod(forFrame frame: Int) -> CleanMethod {
        let realConfig = config.config()
        if let value = realConfig.pixelReplacementOverrides[frame] {
            return value
        } else {
            return realConfig.cleanMethod
        }
    }

    var currentFrameHasOverriddenCleanMethod: Bool {
        self.hasOverriddenCleanMethod(forFrame: currentIndex)
    }
    
    func hasOverriddenCleanMethod(forFrame frame: Int) -> Bool {
        let realConfig = config.config()
        if let value = realConfig.pixelReplacementOverrides[frame] {
            return true
        } else {
            return false
        }
    }
    
    func set(cleanMethod: CleanMethod, forFrame frameIndex: Int) {
        // update the frame view model
        frames[frameIndex].frameObserver.set(cleanMethod: cleanMethod)

        Task { await frames[frameIndex].frame?.set(cleanMethod: cleanMethod) }
        
        // update local overrides
        pixelReplacementOverrides[frameIndex] = cleanMethod

        // update the config too
        var realConfig = config.config()
        realConfig.pixelReplacementOverrides = pixelReplacementOverrides
        config.update(realConfig)
    }
    
    var pixelReplacementOverrides: [Int:CleanMethod] {
        didSet {
            var realConfig = config.config()
            realConfig.pixelReplacementOverrides = pixelReplacementOverrides
            config.update(realConfig)
        }
    }

    // per-frame overrides for numberStaticNeighborFrames
    var staticNeighborFrameOverrides: [Int:Int] {
        didSet {
            var realConfig = config.config()
            realConfig.staticNeighborFrameOverrides = staticNeighborFrameOverrides
            config.update(realConfig)
        }
    }

    /// The static-neighbor-frame count actually in effect for the current frame
    /// (either an override or the global default).
    var currentFrameStaticNeighborCount: Int {
        staticNeighborFrameOverrides[currentIndex] ?? numberStaticNeighborFrames
    }

    /// True when the current frame has a per-frame override for numberStaticNeighborFrames.
    var currentFrameHasStaticNeighborOverride: Bool {
        staticNeighborFrameOverrides[currentIndex] != nil
    }

    /// Set a per-frame override for numberStaticNeighborFrames on `frameIndex`.
    /// If a merged horizon already exists for that frame, it is invalidated and
    /// recomputed immediately using the new neighbor count.
    func set(staticNeighborFrames count: Int, forFrame frameIndex: Int) {
        staticNeighborFrameOverrides[frameIndex] = count
        var realConfig = config.config()
        realConfig.staticNeighborFrameOverrides = staticNeighborFrameOverrides
        config.update(realConfig)

        Task {
            if frameIndex < frames.count,
               let frame = frames[frameIndex].frame
            {
                await frame.setNumberOfStaticNeighborFrames()
                try? await frame.recomputeMergedHorizonIfExists()
            }
        }
    }

    /// Remove any per-frame override for numberStaticNeighborFrames on `frameIndex`,
    /// reverting it to the global default.  Invalidates and recomputes the merged
    /// horizon if one already exists.
    func clearStaticNeighborFrameOverride(forFrame frameIndex: Int) {
        staticNeighborFrameOverrides.removeValue(forKey: frameIndex)
        var realConfig = config.config()
        realConfig.staticNeighborFrameOverrides = staticNeighborFrameOverrides
        config.update(realConfig)

        Task {
            if frameIndex < frames.count,
               let frame = frames[frameIndex].frame
            {
                await frame.setNumberOfStaticNeighborFrames()
                try? await frame.recomputeMergedHorizonIfExists()
            }
        }
    }

    // per-frame overrides for numberAlignedNeighborFrames
    var alignedNeighborFrameOverrides: [Int:Int] {
        didSet {
            var realConfig = config.config()
            realConfig.alignedNeighborFrameOverrides = alignedNeighborFrameOverrides
            config.update(realConfig)
        }
    }

    /// The aligned-neighbor-frame count actually in effect for the current frame
    /// (either an override or the global default).
    var currentFrameAlignedNeighborCount: Int {
        alignedNeighborFrameOverrides[currentIndex] ?? numberOfAlignedNeighborFrames
    }

    /// True when the current frame has a per-frame override for numberAlignedNeighborFrames.
    var currentFrameHasAlignedNeighborOverride: Bool {
        alignedNeighborFrameOverrides[currentIndex] != nil
    }

    /// Set a per-frame override for numberAlignedNeighborFrames on `frameIndex`.
    /// If star-alignment images already exist for that frame, they are invalidated
    /// and reprocessing is triggered immediately using the new neighbor count.
    func set(alignedNeighborFrames count: Int, forFrame frameIndex: Int) {
        alignedNeighborFrameOverrides[frameIndex] = count
        var realConfig = config.config()
        realConfig.alignedNeighborFrameOverrides = alignedNeighborFrameOverrides
        config.update(realConfig)

        Task {
            if frameIndex < frames.count,
               let frame = frames[frameIndex].frame
            {
                await frame.setNumberOfAlignedFrames()
                let wasInvalidated = (try? await frame.invalidateStarAlignmentIfExists()) ?? false
                if wasInvalidated {
                    processFrames(from: frameIndex, to: frameIndex, performClean: false)
                }
            }
        }
    }

    /// Remove any per-frame override for numberAlignedNeighborFrames on `frameIndex`,
    /// reverting it to the global default.  Invalidates and re-triggers star
    /// alignment if it has already been computed.
    func clearAlignedNeighborFrameOverride(forFrame frameIndex: Int) {
        alignedNeighborFrameOverrides.removeValue(forKey: frameIndex)
        var realConfig = config.config()
        realConfig.alignedNeighborFrameOverrides = alignedNeighborFrameOverrides
        config.update(realConfig)

        Task {
            if frameIndex < frames.count,
               let frame = frames[frameIndex].frame
            {
                await frame.setNumberOfAlignedFrames()
                let wasInvalidated = (try? await frame.invalidateStarAlignmentIfExists()) ?? false
                if wasInvalidated {
                    processFrames(from: frameIndex, to: frameIndex, performClean: false)
                }
            }
        }
    }

    var cameraMotion: CameraMotion {
        didSet {
            var realConfig = config.config()
            realConfig.tripodHeadWasMoving = cameraMotion != .fixed
            config.update(realConfig)
        }
    }

    var allowEarthAlignment: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.allowEarthAlignment = allowEarthAlignment
            config.update(realConfig)
        }
    }

    var useReferenceHorizonSmoothing: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.useReferenceHorizonSmoothing = useReferenceHorizonSmoothing
            config.update(realConfig)
        }
    }

    var referenceHorizonSmoothingMaxDistance: Int {
        didSet {
            var realConfig = config.config()
            realConfig.referenceHorizonSmoothingMaxDistance = referenceHorizonSmoothingMaxDistance
            config.update(realConfig)
        }
    }

    var useReferenceHorizonBrightnessRefinement: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.useReferenceHorizonBrightnessRefinement = useReferenceHorizonBrightnessRefinement
            config.update(realConfig)
        }
    }

    var referenceHorizonBrightnessRefinementSearchRadius: Int {
        didSet {
            var realConfig = config.config()
            realConfig.referenceHorizonBrightnessRefinementSearchRadius = referenceHorizonBrightnessRefinementSearchRadius
            config.update(realConfig)
        }
    }

    var referenceHorizonBrightnessRefinementHistogramBuckets: Int {
        didSet {
            var realConfig = config.config()
            realConfig.referenceHorizonBrightnessRefinementHistogramBuckets = referenceHorizonBrightnessRefinementHistogramBuckets
            config.update(realConfig)
        }
    }

    var referenceHorizonNeighborhoodSize: Int {
        didSet {
            var realConfig = config.config()
            realConfig.referenceHorizonNeighborhoodSize = referenceHorizonNeighborhoodSize
            config.update(realConfig)
        }
    }

    var horizonSpikeRemovalEnabled: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.horizonSpikeRemovalEnabled = horizonSpikeRemovalEnabled
            config.update(realConfig)
        }
    }

    var horizonSpikeMaxWidth: Int {
        didSet {
            var realConfig = config.config()
            realConfig.horizonSpikeMaxWidth = horizonSpikeMaxWidth
            config.update(realConfig)
        }
    }

    var horizonSpikeMaxDeviationFraction: Double {
        didSet {
            var realConfig = config.config()
            realConfig.horizonSpikeMaxDeviationFraction = horizonSpikeMaxDeviationFraction
            config.update(realConfig)
        }
    }

    var horizonSpikeWindowHalf: Int {
        didSet {
            var realConfig = config.config()
            realConfig.horizonSpikeWindowHalf = horizonSpikeWindowHalf
            config.update(realConfig)
        }
    }

    // MARK: - Horizon refinement tracking

    /// Reference frame indices updated this session (via HorizonPainterView).
    var updatedReferenceHorizonFrameIndices: Set<Int> = []

    /// Non-reference frame indices that will be re-refined when the user presses
    /// "Re-run Horizon Refinement".
    var affectedHorizonRefinementFrameIndices: Set<Int> = []

    /// Called from HorizonPainterView after a reference horizon is saved.
    /// Recomputes the affected set and marks those frames orange.
    func recordReferenceHorizonUpdated(frameIndex: Int) {
        updatedReferenceHorizonFrameIndices.insert(frameIndex)
        let newAffected = computeAffectedHorizonRefinementFrameIndices()
        let oldAffected = affectedHorizonRefinementFrameIndices
        affectedHorizonRefinementFrameIndices = newAffected
        // clear pending flag for frames that are no longer affected
        for i in oldAffected.subtracting(newAffected) where i < frames.count {
            frames[i].isPendingHorizonRefinement = false
        }
        // set pending flag for newly affected frames
        for i in newAffected where i < frames.count {
            frames[i].isPendingHorizonRefinement = true
        }
    }

    // MARK: - Horizon refinement confirmation

    /// Raises the "re-run the refinement now, or later?" alert, which `ImageSequenceView`
    /// attaches.
    var showHorizonRefinementPrompt = false

    /// The numbers that alert quotes.  Captured when it goes up rather than read live:
    /// answering it clears the two sets they are counted from.
    private(set) var horizonRefinementPromptFrameCount = 0
    private(set) var horizonRefinementPromptRenderCount = 0

    /// Frame output whose presence means a frame has to be rendered again when the horizon
    /// under it moves — the same set `reprocessHorizonsForUpdatedReferences` deletes.
    private static let horizonRefinementOutputTypes: Set<FrameViewMode> =
      [.autoProcessed, .autoSelectiveProcessed, .selectiveProcessed, .final]

    /// What the horizon painter calls after saving a reference with "apply to nearby
    /// frames" on: mark the affected frames, then *ask* whether to re-run now.
    ///
    /// This used to start the run itself, which put a span of frames back into the
    /// pipeline the instant the painter closed — before anything on screen said why, and
    /// often for one reference of several the user was about to paint.  Nothing is lost by
    /// saying later: the frames stay marked, and the right panel's "Re-run Horizon
    /// Refinement" button does exactly this work over every reference painted since.
    func promptToReprocessHorizons(forUpdatedReference frameIndex: Int) {
        recordReferenceHorizonUpdated(frameIndex: frameIndex)

        let affected = affectedHorizonRefinementFrameIndices
        let toRender = framesNeedingHorizonRerender(
          affected.union(updatedReferenceHorizonFrameIndices)
        )

        // No horizons to recompute and no output to render again — there is nothing to
        // ask about.  Run it anyway, which in this state only clears the tracking.
        guard !affected.isEmpty || !toRender.isEmpty else {
            reprocessHorizonsForUpdatedReferences()
            return
        }

        horizonRefinementPromptFrameCount = affected.union(toRender).count
        horizonRefinementPromptRenderCount = toRender.count
        showHorizonRefinementPrompt = true
    }

    /// The body of that alert: what each answer costs, in this sequence's numbers.
    var horizonRefinementPromptMessage: String {
        localized("ui.horizon_refinement_prompt_message",
                  horizonRefinementPromptFrameCount,
                  horizonRefinementPromptRenderCount)
    }

    /// Of `indices`, the frames a re-run would have to render again: the ones that already
    /// have output the changed horizon went into.
    ///
    /// Read off `existingImages`, which is where each frame's own `imageExists` survey put
    /// its types, so this agrees with the check `reprocessHorizonsForUpdatedReferences`
    /// makes against the disk — and can be asked on the main actor, before that pass has
    /// run, by the alert and by the modal's first step list.
    private func framesNeedingHorizonRerender(_ indices: Set<Int>) -> Set<Int> {
        indices.filter { index in
            guard index < frames.count else { return false }
            return !frames[index].existingImages
              .isDisjoint(with: Self.horizonRefinementOutputTypes)
        }
    }

    /// The steps a re-run over these frames looks like it will take, as far as can be told
    /// before the frames themselves have been looked at.  Corrected to what the work
    /// actually came to once the pass over them finishes.
    private func expectedHorizonRefinementSteps(
      refining toProcess: Set<Int>,
      references: Set<Int>
    ) -> [OperationType] {
        var steps: [OperationType] = []
        if !toProcess.isEmpty { steps.append(.mergedHorizon) }
        if !framesNeedingHorizonRerender(toProcess.union(references)).isEmpty {
            steps.append(.merge)
        }
        return steps
    }

    private func computeAffectedHorizonRefinementFrameIndices() -> Set<Int> {
        let allReferenceIndices = frames.indices
            .filter { frames[$0].existingImages.contains(.userHorizon) }
            .sorted()
        let referenceSet = Set(allReferenceIndices)

        var affected = Set<Int>()
        for updatedIdx in updatedReferenceHorizonFrameIndices {
            let prevRef = allReferenceIndices.last(where: { $0 < updatedIdx }).map { $0 } ?? -1
            let nextRef = allReferenceIndices.first(where: { $0 > updatedIdx }).map { $0 } ?? frames.count
            for i in (prevRef + 1)..<nextRef where !referenceSet.contains(i) {
                affected.insert(i)
            }
        }
        return affected
    }

    /// Clears the reference-stats cache for updated frames, recomputes merged
    /// horizons for all affected frames, then clears the tracking state.
    /// If any affected frame (interpolated or reference) already has processed
    /// output (star/earth aligned images), its alignment is invalidated and it
    /// is re-queued for a full reprocess using the updated horizon.
    func reprocessHorizonsForUpdatedReferences() {
        let toProcess = affectedHorizonRefinementFrameIndices
        let toInvalidate = updatedReferenceHorizonFrameIndices

        updatedReferenceHorizonFrameIndices = []
        affectedHorizonRefinementFrameIndices = []
        // Leave isPendingHorizonRefinement = true for affected frames so the
        // filmstrip and frame view show orange horizon lines while re-merge is queued.
        // It will be cleared per-frame once its merge completes (or immediately below
        // for frames that have no alignment output and won't be re-merged).

        // Up here, on the main actor, and not where the operations are finally enqueued:
        // the pass below stats and deletes files one frame at a time and can take a minute
        // or two on a large sequence, and that was a minute or two of the window looking
        // as though answering the prompt had done nothing at all.  The rows start from
        // what this can tell without touching the disk and are corrected below to what the
        // work came to; if it comes to nothing, the run ends and takes the modal with it.
        //
        // Skipped while a run is already going: raising the modal re-takes the progress
        // baseline, which would leave that run's bars measuring from the wrong place.
        let expectedSteps = expectedHorizonRefinementSteps(refining: toProcess,
                                                           references: toInvalidate)
        let showsModal = !expectedSteps.isEmpty && !isProcessingFrames
        let toExamine = toProcess.union(toInvalidate).count
        if showsModal {
            isProcessingFrames = true
            startProcessingModal(
              steps: expectedSteps,
              status: localized("ui.horizon_refinement_preparing", 0, toExamine)
            )
        }

        Task.detached(priority: .userInitiated) { [self] in
            for idx in toInvalidate {
                await referenceHorizonStatsCache.clearStats(for: idx)
            }

            // Affected interpolated frames need their merged horizon recomputed
            // (unconditional variant — frames that previously only had a raw
            // .horizon mask get another attempt at producing a merged one).
            var refinementFrames: [FrameAirplaneRemover] = []
            for i in toProcess.sorted() {
                guard i < (await self.frames.count),
                      let frame = await self.frames[i].frame else { continue }
                refinementFrames.append(frame)
            }

            // For every modified frame (interpolated or manually-edited reference)
            // that was already processed, delete only its merge output so it gets
            // re-queued for re-compositing with the updated horizon.  Star/earth
            // alignment output is preserved.
            let allModified = toProcess.union(toInvalidate).sorted()
            var framesToMerge: [FrameAirplaneRemover] = []
            for (examined, i) in allModified.enumerated() {
                // This loop is the wait: `imageExists` and `deleteMergeOutput` are both
                // disk, per frame.  Counting it out is the only honest thing the modal can
                // show until the operations exist.
                if showsModal {
                    await MainActor.run {
                        self.processingStatusText = localized("ui.horizon_refinement_preparing",
                                                              examined + 1, allModified.count)
                    }
                }
                guard i < (await self.frames.count),
                      let frame = await self.frames[i].frame else { continue }
                // Re-queue any frame that already has final output, regardless of whether
                // it has alignment files. Frames in gaps where alignment was skipped still
                // have auto-processed output and need their horizon re-composited.
                let hasOutput =
                    frame.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                                    ofType: .autoProcessed, atSize: .original) ||
                    frame.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                                    ofType: .autoSelectiveProcessed, atSize: .original) ||
                    frame.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                                    ofType: .selectiveProcessed, atSize: .original) ||
                    frame.imageAccessor.imageExists(frameIndex: frame.frameIndex,
                                                    ofType: .final, atSize: .original)
                guard hasOutput else {
                    // Frame hasn't been processed yet — nothing to re-merge, clear orange now.
                    await MainActor.run { self.frames[i].isPendingHorizonRefinement = false }
                    continue
                }
                await frame.deleteMergeOutput()
                await MainActor.run {
                    self.frames[i].existingImages.subtract(
                        [.autoProcessed, .autoSelectiveProcessed, .selectiveProcessed, .final]
                    )
                }
                framesToMerge.append(frame)
            }

            guard !refinementFrames.isEmpty || !framesToMerge.isEmpty else {
                // Nothing came of it, so end the run this started — otherwise the modal
                // sits there over a sequence that is not processing anything.
                if showsModal {
                    await MainActor.run {
                        self.isProcessingFrames = false
                        self.processingStatusText = nil
                    }
                }
                return
            }

            let mergeIndices = framesToMerge.map { $0.frameIndex }
            // What the work actually came to, now that the frames have been looked at: a
            // row for a step with no operations would sit at zero and read as stuck, and
            // these rows are never filtered — that needs a graph build to complete, and
            // this kind of run completes none.
            var steps: [OperationType] = []
            if !refinementFrames.isEmpty { steps.append(.mergedHorizon) }
            if !framesToMerge.isEmpty { steps.append(.merge) }
            await MainActor.run {
                self.isProcessingFrames = true
                if showsModal {
                    self.processingStepTypes = steps
                    // There are operations to count now, so the bars say it better.
                    self.processingStatusText = nil
                }
            }

            await frameGraphBuilder.enqueueHorizonRefinement(
              refinementFrames: refinementFrames,
              mergeFrames: framesToMerge,
              refinementCompletion: { [weak self] frame in
                  guard let self else { return }
                  await MainActor.run {
                      let i = frame.frameIndex
                      if i < self.frames.count {
                          self.frames[i].refreshHorizonOverlay()
                          self.frames[i].refreshFrameHorizonOverlay()
                      }
                  }
              },
              errorClosure: { errorString in Log.e(errorString) }
            ) { _ in
                Task { @MainActor in
                    for i in mergeIndices where i < self.frames.count {
                        self.frames[i].isPendingHorizonRefinement = false
                    }
                    self.isProcessingFrames = false
                }
            }
        }
    }

    public var alignmentMaxKeypoints: Int {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentMaxKeypoints = alignmentMaxKeypoints
            config.update(realConfig)
        }
    }
    
    public var alignmentWriteDebugImages: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentWriteDebugImages = alignmentWriteDebugImages
            config.update(realConfig)
        }
    }

    public var alignmentKeypointDetectionDivisor: Double {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentKeypointDetectionDivisor = alignmentKeypointDetectionDivisor
            config.update(realConfig)
        }
    }
    
    public var alignmentGroundHorizonExtension: Int {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentGroundHorizonExtension = alignmentGroundHorizonExtension
            config.update(realConfig)
        }
    }
    
    public var alignmentSkyHorizonExtension: Int {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentSkyHorizonExtension = alignmentSkyHorizonExtension
            config.update(realConfig)
        }
    }
    
    public var alignmentBaseImageDilateSize: Int {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentBaseImageDilateSize = alignmentBaseImageDilateSize
            config.update(realConfig)
        }
    }
    
    public var alignmentBaseImageThresholdValue: Int {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentBaseImageThresholdValue = alignmentBaseImageThresholdValue
            config.update(realConfig)
        }
    }
    
    var numberOfFramesToProcessConcurrently: Int {
        didSet {
            var realConfig = config.config()
            realConfig.numberOfFramesToProcessConcurrently = numberOfFramesToProcessConcurrently
            Log.d("FUCKING update numberOfFramesToProcessConcurrently \(numberOfFramesToProcessConcurrently)")
            config.update(realConfig)
        }
    }

    /// Whether a run whose settings have changed since the artifacts on disk were built
    /// throws those artifacts away and builds them again.
    ///
    /// The answer to the confirmation the settings sheet puts up over a sequence that has
    /// already been processed.  Not a control anywhere: `updateSettingsAndProcess(reprocess:)`
    /// is the only thing that sets it, and it sets it from the button the user pressed.
    var reprocessOnSettingsChange: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.reprocessOnSettingsChange = reprocessOnSettingsChange
            config.update(realConfig)
        }
    }

    var memoryBudgetFraction: Double {
        didSet {
            var realConfig = config.config()
            realConfig.maxMatMemoryFraction = memoryBudgetFraction
            config.update(realConfig)
        }
    }

    var keypointMemoryMultiplier: Int {
        didSet {
            var realConfig = config.config()
            realConfig.keypointMemoryMultiplier = keypointMemoryMultiplier
            config.update(realConfig)
        }
    }

    /// 0 = no explicit cap; the limit then comes from the memory budget and the frame
    /// concurrency alone.  Use this rather than inflating keypointMemoryMultiplier,
    /// which also distorts every keypoint op's memory reservation.
    var maxConcurrentKeypointOps: Int {
        didSet {
            var realConfig = config.config()
            realConfig.maxConcurrentKeypointOps = maxConcurrentKeypointOps
            config.update(realConfig)
        }
    }

    var outlierMemoryMultiplier: Int {
        didSet {
            var realConfig = config.config()
            realConfig.outlierMemoryMultiplier = outlierMemoryMultiplier
            config.update(realConfig)
        }
    }

    var mergeMemoryMultiplier: Int {
        didSet {
            var realConfig = config.config()
            realConfig.mergeMemoryMultiplier = mergeMemoryMultiplier
            config.update(realConfig)
        }
    }

    var horizonMemoryMultiplier: Int {
        didSet {
            var realConfig = config.config()
            realConfig.horizonMemoryMultiplier = horizonMemoryMultiplier
            config.update(realConfig)
        }
    }

    /// Least bytes to reserve for one horizon op, whatever the multiplier works out to.
    /// A horizon op's cost is mostly fixed rather than per pixel, so the multiplier alone
    /// under-reserves on small frames.  0 = no floor, multiplier only.
    var horizonReservationFloorMB: Int {
        didSet {
            var realConfig = config.config()
            realConfig.horizonReservationFloorMB = horizonReservationFloorMB
            config.update(realConfig)
        }
    }

    var homographySmoothingEpsilon: Double {
        didSet {
            var realConfig = config.config()
            realConfig.homographySmoothingEpsilon = homographySmoothingEpsilon
            config.update(realConfig)
        }
    }
    
    // the threshold used in goodPixels(thresholdFactor: )
    var pixelThreshold: Double = 1.2
    
    // number of frames in the sequence we're processing
    var imageSequenceSize: Int = 0

    var shouldShowInitialInstructions: Bool = false

    var shouldShowProcessingSettings: Bool = false

    // MARK: - Settings changed over work already done

    /// The configuration as it was when the settings sheet was opened.
    ///
    /// The settings view is built for a sequence nothing has been done to, where every
    /// switch it offers affects only work still to come.  Over a sequence that is part way
    /// through, the same switch splits the sequence in two — some frames merged with earth
    /// alignment and some without — and the only way to say so is to know what the settings
    /// were before the user started changing them.
    ///
    /// Not the record `FrameGraphBuilder` keeps on disk, which would be the other candidate:
    /// that one is written only by a run that covers the whole sequence, so it is absent for
    /// exactly the half-finished sequences this is for, and absent again for every sequence
    /// processed before it existed.  A snapshot is always available and answers the narrower
    /// question the user is actually asking — "does what I just changed contradict what is
    /// already done?"
    var settingsSnapshot: Config? {
        didSet { recomputeStagesChangedInSettings() }
    }

    /// Which cached stages the settings changed in this settings session would invalidate.
    ///
    /// Empty when nothing output-affecting has moved.  `ArtifactInputs` is what draws that
    /// line, and it draws it in one place for every client: the concurrency and memory
    /// knobs change how the work is done rather than what comes out, so turning one of
    /// those does not raise a warning about frames that are already finished.
    ///
    /// Stored rather than computed, because it is derived from the *whole* `Config` and
    /// `ConfigManager` is not `@Observable`.  A computed property reading it would be
    /// recomputed only when something else happened to redraw the settings sheet — and the
    /// controls that change these settings are child views holding bindings, which the
    /// sheet's own body never reads.  So the warning would appear a keystroke late, or not
    /// at all.
    private(set) var stagesChangedInSettings: Set<ArtifactStage> = []

    /// Called from the `ConfigManager.onUpdate` hook that every setting's `didSet` goes
    /// through, so this is as current as the config is.
    private func recomputeStagesChangedInSettings() {
        guard let settingsSnapshot else {
            stagesChangedInSettings = []
            return
        }
        stagesChangedInSettings =
          ArtifactInputs.current(from: config.config())
            .staleStages(comparedTo: ArtifactInputs.current(from: settingsSnapshot))
    }

    /// Whether the settings sheet should be warning that this change contradicts work
    /// already done, and offering Update rather than Process Now.  The rule is
    /// `SettingsChangeState`'s; this is where the numbers it needs are.
    var settingsContradictFinishedWork: Bool {
        SettingsChangeState.contradictsFinishedWork(
          isProcessingFrames: isProcessingFrames,
          completeFrameCount: count(for: .complete),
          userModifiedFrameCount: count(for: .userModified),
          openedSequenceWasUntouched: progressWhenOpened?.isUntouched,
          changedStages: stagesChangedInSettings
        )
    }

    /// Start processing under settings that have just changed over work already done.
    ///
    /// `reprocess` is the answer to the confirmation: true throws away what the changed
    /// settings invalidated and builds it again, false keeps it and applies the new
    /// settings only to the frames that are left.
    ///
    /// A run already in progress is stopped and started again rather than left to finish.
    /// Its graph was planned — and its stale artifacts surveyed — under the settings as
    /// they were, so the operations still queued would go on skipping frames whose
    /// artifacts the change has just made wrong.  Only a fresh build re-surveys, and the
    /// wait is what keeps the new build's invalidation pass from deleting artifacts the
    /// old build's stragglers are still writing.
    func updateSettingsAndProcess(reprocess: Bool) {
        reprocessOnSettingsChange = reprocess

        guard isProcessingFrames else {
            processAll()
            return
        }
        cancelProcessing()
        Task {
            await frameGraphBuilder.cancelAllOperationsAndWait()
            self.processAll()
        }
    }

    /// Whether `ProcessingModalView` is up over the rest of the window.
    ///
    /// Only ever consulted together with `isProcessingFrames`, so a run that ends — for any
    /// reason, including one this view model does not hear about directly — takes the modal
    /// with it and nothing has to remember to close it.
    var processingModalShowing: Bool = false

    /// Whether `SequenceProgressModalView` is up over the rest of the window.
    ///
    /// Raised by `ViewModel` on the paths that re-open a sequence from a config file it
    /// wrote earlier, and by nothing else: a sequence being set up for the first time gets
    /// the startup questionnaire instead, which asks the questions this panel reports the
    /// answers to.
    var sequenceProgressModalShowing: Bool = false

    /// How far a previous run had got when this sequence was opened, read off the artifacts
    /// it left behind.  `nil` until the survey at the end of `setup` finishes.
    ///
    /// A snapshot, as the name says: it is not refreshed as a run progresses, because the
    /// thing that reports a live run is `ProcessingModalView` and it measures operations.
    var progressWhenOpened: SequenceProgress?

    /// What `FrameGraphViewModel`'s counters read when the current run started.
    ///
    /// Those counters are cumulative for as long as a sequence is open, so this is what
    /// lets the modal's bars show the run in front of the user rather than every op since
    /// the sequence was loaded.  See `ProcessingSteps.progress(for:counts:since:)`.
    var processingStepBaseline: [OperationType: [OperationState: UInt]] = [:]

    /// The steps the current run will take, settled when it starts from the same
    /// configuration `FrameGraphBuilder` is about to read.
    var processingStepTypes: [OperationType] = []

    /// `FrameGraphViewModel.graphBuildsCompleted` when the current run started, so that the
    /// modal can tell "this step has nothing to do" from "the builder has not got to this
    /// step yet".  The two look the same in the counts, and only the first should hide a
    /// row.
    var processingBuildCount: Int = 0

    /// What the run is doing before it has any operations to count, shown in the modal's
    /// header in place of the frames-complete line.
    ///
    /// `nil` for a run whose work is known as soon as it starts, which is every run that
    /// builds a frame graph.  The horizon refinement re-run is the exception: it spends its
    /// first minute or two reading the frames on disk to find out what it has to redo, and
    /// during that the step rows have nothing in them and the frames-complete line still
    /// reads as the finished sequence it is about to take apart.
    var processingStatusText: String? = nil

    // used in initial instructions view
    var showExpertSettings = false

    var shouldShowTrash: Bool = false

    var minimumClassificationSize: Int = 20
    var minimumClassificationSizeString = ""

    var classifyOnlyUnclassified: Bool = true

    var trashLevel: Double {
        didSet {
            Task { await constants.set(trashLevel: self.trashLevel) }
        }
    }

    var trashLevelString: String = ""
    
    var smallTrashMax: Int {
        didSet {
            Task { await constants.set(smallTrashMax: self.smallTrashMax) }
        }
    }

    var smallTrashMaxString: String = ""

    var numberOfFramesToProcess: Int = 1

    var reprocessingType: FrameReprocessingType = .none

    // total number of cv::Mat (MatWrapper*) objects currently in ram
    var totalMatInstances = 0
    // and their total size
    var totalMatBytes = 0
    
    convenience init(
      viewModel: ViewModel,
      withConfig jsonConfigFilename: String,
      closure: @escaping @Sendable (Int, Double) -> Void) async throws
    {
        Log.d("outlier_json_startup with \(jsonConfigFilename)")
        // first read config from json
        let config = try ConfigManager(configFilename: jsonConfigFilename)

        try await self.init(
          viewModel: viewModel,
          with: config,
          closure: closure
        )
    }
    
    convenience init(
      viewModel: ViewModel,
      withNewImageSequence imageSequenceDirname: String,
      and videoInfo: VideoInfo? = nil,
      closure: @Sendable @escaping (Int, Double) -> Void) async throws
    {
        let shouldWriteOutlierGroupFiles = true // XXX see what happens
        
        // XXX copied from star.swift
        var inputImageSequenceDirname = imageSequenceDirname 

        while inputImageSequenceDirname.hasSuffix("/") {
            // remove any trailing '/' chars,
            // otherwise our created output dir(s) will end up inside this dir,
            // not alongside it
            _ = inputImageSequenceDirname.removeLast()
        }

        if !inputImageSequenceDirname.hasPrefix("/") {
            let fullPath =
              FileManager.default.currentDirectoryPath + "/" +
              inputImageSequenceDirname
            inputImageSequenceDirname = fullPath
        }

        var filenamePaths = inputImageSequenceDirname.components(separatedBy: "/")
        var inputImageSequencePath: String = ""
        var inputImageSequenceName: String = ""
        if let lastElement = filenamePaths.last {
            filenamePaths.removeLast()
            inputImageSequencePath = filenamePaths.joined(separator: "/")
            if inputImageSequencePath.count == 0 { inputImageSequencePath = "/" }
            inputImageSequenceName = lastElement
        } else {
            inputImageSequencePath = "/"
            inputImageSequenceName = inputImageSequenceDirname
        }

        var config = Config(
          outputPath: inputImageSequencePath,
          imageSequenceName: inputImageSequenceName,
          imageSequencePath: inputImageSequencePath,
          writeOutlierGroupFiles: shouldWriteOutlierGroupFiles,
          writeFramePreviewFiles: shouldWriteOutlierGroupFiles,
          writeFrameProcessedPreviewFiles: shouldWriteOutlierGroupFiles,
          writeFrameThumbnailFiles: shouldWriteOutlierGroupFiles
        )

        if let videoInfo {
            config.set(videoInfo: videoInfo)
        }
        
        config.ignoreLowerPixels = 0
        
        let configFilename = "config.json"
        
        let configManager = ConfigManager(configFilename: configFilename, config: config)

        try await self.init(
          viewModel: viewModel,
          with: configManager,
          closure: closure
        )

        if config.writeOutlierGroupFiles {
            mkdir(config.outlierOutputDirname)
        }
        self.interactionMode = .edit
        self.shouldShowInitialInstructions = true
        self.frameViewMode = .original
        if let videoInfo {
            self.frameRate = videoInfo.frameRate
            self.codec = videoInfo.codec
            if let encoder = videoInfo.encoder {
                self.encoder = encoder
            }
            self.pixelFormat = videoInfo.pixelFormat
            self.muxer = videoInfo.muxer
            self.hasAudio = videoInfo.hasAudio
        }
        
    }

    public func disable() {
        self.appNapDisabler.end()
    }
    
    deinit {
        Log.i("DEINIT")         // XXX not always called :(
    }
    
    private var matInstancesTask: Task<Void,Never>? = nil

    private var appNapDisabler: AppNapDisabler
    
    init(
      viewModel: ViewModel,
      with configManager: ConfigManager,
      closure: @Sendable @escaping (Int, Double) -> Void
    ) async throws {
        self.topViewModel = viewModel
        self.trashLevel = await constants.getTrashLevel()
        self.smallTrashMax = await constants.getSmallTrashMax()

        self.appNapDisabler = AppNapDisabler()
        
        var config = configManager.config()

        // turn on previews if they're off as the gui needs them
        if !config.writeFramePreviewFiles {
            config.writeFramePreviewFiles = true
            configManager.update(config)
        }
        
        if !config.cleanMethod.usesOutliers {
            self.selectionMode = .none
        } 
        
        self.numberOfAlignedNeighborFrames = config.numberAlignedNeighborFrames
        self.numberStaticNeighborFrames = config.numberStaticNeighborFrames
        self.horizonDetectionEnabled = config.horizonDetectionEnabled
        self.useCannyForHorizonDetection = config.useCannyForHorizonDetection ? .yes : .no
        self.cannyMinThreshold = config.cannyMinThreshold
        self.cannyMaxThreshold = config.cannyMaxThreshold
        self.cannyUseL2Gradient = config.cannyUseL2Gradient ? .L2norm : .L1norm
        self.numberOfNeighborFrames = config.numberFinalProcessingNeighborsNeeded
        self.cleanMethod = config.cleanMethod
        self.pixelReplacementOverrides = config.pixelReplacementOverrides
        self.staticNeighborFrameOverrides = config.staticNeighborFrameOverrides
        self.alignedNeighborFrameOverrides = config.alignedNeighborFrameOverrides
        self.cameraMotion = config.tripodHeadWasMoving ? .moving : .fixed
        self.numberOfFramesToProcessConcurrently = config.numberOfFramesToProcessConcurrently
        self.reprocessOnSettingsChange = config.reprocessOnSettingsChange
        self.memoryBudgetFraction = config.maxMatMemoryFraction
        self.keypointMemoryMultiplier = config.keypointMemoryMultiplier
        self.maxConcurrentKeypointOps = config.maxConcurrentKeypointOps
        self.outlierMemoryMultiplier = config.outlierMemoryMultiplier
        self.mergeMemoryMultiplier = config.mergeMemoryMultiplier
        self.horizonMemoryMultiplier = config.horizonMemoryMultiplier
        self.horizonReservationFloorMB = config.horizonReservationFloorMB
        self.homographySmoothingEpsilon = config.homographySmoothingEpsilon
        self.allowEarthAlignment = config.allowEarthAlignment
        self.useReferenceHorizonSmoothing = config.useReferenceHorizonSmoothing
        self.referenceHorizonSmoothingMaxDistance = config.referenceHorizonSmoothingMaxDistance
        self.useReferenceHorizonBrightnessRefinement = config.useReferenceHorizonBrightnessRefinement
        self.referenceHorizonBrightnessRefinementSearchRadius = config.referenceHorizonBrightnessRefinementSearchRadius
        self.referenceHorizonBrightnessRefinementHistogramBuckets = config.referenceHorizonBrightnessRefinementHistogramBuckets
        self.referenceHorizonNeighborhoodSize = config.referenceHorizonNeighborhoodSize
        self.horizonSpikeRemovalEnabled = config.horizonSpikeRemovalEnabled
        self.horizonSpikeMaxWidth = config.horizonSpikeMaxWidth
        self.horizonSpikeMaxDeviationFraction = config.horizonSpikeMaxDeviationFraction
        self.horizonSpikeWindowHalf = config.horizonSpikeWindowHalf

        self.alignmentMaxKeypoints = config.alignmentMaxKeypoints
        self.alignmentGroundHorizonExtension = config.alignmentGroundHorizonExtension
        self.alignmentSkyHorizonExtension = config.alignmentSkyHorizonExtension
        self.alignmentBaseImageDilateSize = config.alignmentBaseImageDilateSize
        self.alignmentBaseImageThresholdValue = config.alignmentBaseImageThresholdValue
        //
        self.alignmentWriteDebugImages = config.alignmentWriteDebugImages
        self.alignmentKeypointDetectionDivisor = config.alignmentKeypointDetectionDivisor
        //
        
        self.config = configManager

        let ignoreLowerPixels = config.ignoreLowerPixels 
        self.ignoreLowerPixels = CGFloat(ignoreLowerPixels) // XXX need to sync back the other dir
                    
        Log.d("loaded config \(config.imageSequenceDirname)")

        // Drop the previous sequence's keypoint sets. They are keyed by file path, so a
        // new sequence never hits them, and holding them would pin one entry per frame
        // per alignment type from every sequence opened this session.
        await keypointCache.clear()

        let imageSequence = try ImageSequence(dirname: "\(config.imageSequencePath)/\(config.imageSequenceDirname)",
                                              supportedImageFileTypes: config.supportedImageFileTypes)

        Log.d("loaded image sequence")
        let imageInfo = try await imageSequence.getImageInfo()

        // still needed by the decision trees :(
        IMAGE_WIDTH = Double(imageInfo.imageWidth)
        IMAGE_HEIGHT = Double(imageInfo.imageHeight)

        // most everything else uses the config for image sizes now
        var updatedConfig = self.config.config()
        updatedConfig.set(imageInfo: imageInfo)
        self.config.update(updatedConfig)
        
        let callbacks = self.makeCallbacks()

        self.imageSequenceSize = await imageSequence.filenames.count
        Log.d("loaded \(imageSequenceSize) images")
        self.set(numberOfFrames: imageSequenceSize)

        // Tell the run marker what is being worked on, so if the app is killed the next
        // launch can name the sequence and offer to resume it.  Done after the config has
        // had `set(imageInfo:)` applied above, so the dimensions are real.
        // Write failures are per-sequence, and the gui keeps one process across many. Without
        // this the "could not write output" warning fires once ever, so a failure on the
        // second sequence a user opens would be recorded silently.
        await OutputWriteFailures.shared.reset()

        let markerConfig = self.config.config()
        await RunMarkerStore.shared.describe(
          sequenceName: markerConfig.imageSequenceDirname,
          sequencePath: markerConfig.imageSequencePath
        )
        await RunMarkerStore.shared.update(
          frameCount: imageSequenceSize,
          resumeConfigPath: markerConfig.jsonPath(named: "config.json"),
          imageWidth: markerConfig.imageWidth,
          imageHeight: markerConfig.imageHeight,
          imageBytesPerPixel: markerConfig.imageBytesPerPixel
        )
        
        Log.d("loaded imageInfo \(imageInfo)")

        self.appNapDisabler.begin()
        
        self.matInstancesTask = Task { [weak self] in 
            while(self != nil) { 
                let instances = MatWrapper.totalInstances
                let bytes = MatWrapper.totalBytes
                Task { @MainActor in
                    if instances < Int.max {
                        self?.totalMatInstances = Int(instances)
                    }
                    if bytes < Int.max {
                        self?.totalMatBytes = Int(bytes)
                    }
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }

        // finish setup off the main thread
        await Task {
            do {
                try await self.setup(
                  with: imageSequence,
                  and: callbacks,
                  configManager: configManager,
                  config: config,
                  closure: closure
                )
            } catch {
                Log.e("startup error: \(error)")
            }
        }.value
    }

    nonisolated private func setup(
      with imageSequence: ImageSequence,
      and callbacks: Callbacks,
      configManager: ConfigManager,
      config: Config,
      closure: @Sendable @escaping (Int, Double) -> Void
    ) async throws {
        Log.d("setup")

        var frameIndexToBaseNameMap: [Int: String] = [:]

        let filenames = await imageSequence.filenames
        
        for (frameIndex, filename) in filenames.enumerated() {
            frameIndexToBaseNameMap[frameIndex] = removePath(fromString: filename)
        }

        
        let imageAccessor = ImageAccessor(
          config: config,
          imageSequence: imageSequence,
          frameIndexToBaseNameMap: frameIndexToBaseNameMap
        ) { [weak self] image, frameIndex, type, size in
            Task { @MainActor in
                Log.d("frame \(frameIndex) saved image of type \(type) at size \(size)")
                self?.frames[frameIndex].saved(image: image, ofType: type, atSize: size)
            }
        }


        let imageInfo = try await imageSequence.getImageInfo()


        
        await frameGraphBuilder.set(configManager: configManager)

        // Every setting's `didSet` ends in `config.update`, which runs this.  It is what
        // keeps `stagesChangedInSettings` — and so the settings sheet's warning and the
        // Update button — in step with a config nothing observes directly.
        await MainActor.run {
            configManager.onUpdate { [weak self] _ in
                Task { @MainActor in self?.recomputeStagesChangedInSettings() }
            }
        }

        let distributor = IndexDistributor(max: filenames.count)

        func nextIndex() async -> Int? {
            await distributor.nextIndex()
        }

        
        let maxParallelism = min(ProcessInfo.processInfo.activeProcessorCount, 8)

        let accumulator = FrameAccumulator()

        try await withThrowingTaskGroup(of: Void.self) { group in
            // Create fixed number of workers
            for _ in 0..<maxParallelism {
                group.addTask {
                    while true {
                        // Atomically fetch next index
                        let frameIndex: Int? = await nextIndex()
                        guard let frameIndex else { break }

                        let filename = filenames[frameIndex]
                        let basename = removePath(fromString: filename)

                        let frame = try await FrameAirplaneRemover(
                              with: configManager,
                              initialConfig: config,
                              width: imageInfo.imageWidth,
                              height: imageInfo.imageHeight,
                              componentsPerPixel: imageInfo.componentsPerPixel,
                              callbacks: callbacks,
                              imageSequence: imageSequence,
                              atIndex: frameIndex,
                              outputFilename: "\(config.outputPath)/\(config.basename)",
                              baseName: basename,
                              writeOutputFiles: true,
                              imageAccessor: imageAccessor
                            )

                        if let callback = callbacks.frameCheckClosure {
                            Task { @MainActor in
                                callback(frame)
                            }
                        }

                        let loadedCount = await accumulator.append(frame)

                        let update = Double(loadedCount) / Double(await self.imageSequenceSize)

                        Task { @MainActor in
                            self.frames[frameIndex].frame = frame
                            closure(loadedCount, update)
                        }

                    }
                }
            }

            try await group.waitForAll()
        }

        let frames = await accumulator.allFrames()

        // doubly link them here
        await doublyLink(frames: frames)

        Log.d("done loading image sequence")

        // What a previous run left on disk, surveyed here rather than by whoever puts the
        // panel up, because this is the one place that certainly holds every frame: the
        // per-frame assignments above reach `self.frames` through a `Task { @MainActor }`
        // hop each, so a reader on the main actor cannot know they have all landed.
        //
        // Done for every sequence, including one being set up for the first time, where
        // nothing reads it — the whole survey is a few stats per frame, and a flag threaded
        // down here to skip it would cost more to keep honest than the work it saves.
        let (surveyConfig, homographyDatabase) = await MainActor.run {
            (configManager.config(), configManager.homographyDatabase)
        }
        let surveyed = await SequenceProgressSurvey.survey(
          frames: frames,
          config: surveyConfig,
          homographyDatabase: homographyDatabase
        )
        Log.i("opened with \(surveyed.framesComplete)/\(surveyed.frameCount) frames already written")
        // Assigned before this returns, rather than through a queued hop, so that whoever
        // decides to show the panel cannot get there first and find nothing to draw.
        await MainActor.run { self.progressWhenOpened = surveyed }

        Task { @MainActor in
            self.initialLoadInProgress = false
        }

        let separateFrames = await MainActor.run { self.frames }

        Task { @MainActor in
            for frame in frames {
                if frame.frameIndex == currentIndex {
                    switch await frame.cleanMethod {
                    case .automatic(let useOutliers): 
                        currentFrameHighLevelCleanMethod = .automatic
                        currentFrameAutoPreservationMode = useOutliers ? .yes : .no

                    case .selective:
                        currentFrameHighLevelCleanMethod = .selective
                        currentFrameAutoPreservationMode = .no
                    }
                }
            }
        }

        Task.detached(priority: .utility) { [separateFrames] in
            // make sure we have all previews for all existing original images
            for frameView in separateFrames {
                Log.d("frame \(frameView.frameIndex) checking for missing images")
                var updateFrame = false
                if let frame = await frameView.frame {
                    // Preview ops load a full-resolution image to downscale it, so they
                    // need a reservation like anything else. Without this the unit is 0
                    // and the .preview multiplier has nothing to multiply — three of them
                    // run concurrently on the preview queue, entirely ungated.
                    let previewUnit = await frame.configManager.config().workingFrameBytes
                    for mode in FrameViewMode.allCases {
                        if imageAccessor.urlForImage(
                             frameIndex: frame.frameIndex,
                             ofType: mode,
                             atSize: .original
                           ) != nil,
                           frame.imageAccessor.urlForImage(
                             frameIndex: frame.frameIndex,
                             ofType: mode,
                             atSize: .preview
                           ) == nil
                        {
                            let op = PreviewOp(
                              frameView: frameView,
                              imageAccessor: frame.imageAccessor,
                              frameIndex: frame.frameIndex,
                              type: mode,
                              size: .preview,
                              rawImageBytes: previewUnit
                            ) { errorString in
                                Log.e("frame \(frame.frameIndex) unable to create preview: \(errorString)")
                            }
                            op.queuePriority = .veryLow
                            await frameGraphBuilder.add(operation: op)
                        }
                    }
                    if frame.imageAccessor.urlForImage(
                         frameIndex: frame.frameIndex,
                         ofType: .original,
                         atSize: .thumbnail
                       ) == nil
                    {
                        let op = PreviewOp(
                          frameView: frameView,
                          imageAccessor: frame.imageAccessor,
                          frameIndex: frame.frameIndex,
                          type: .original,
                          size: .thumbnail,
                          rawImageBytes: previewUnit
                        ) { errorString in
                            Log.e("frame \(frame.frameIndex) unable to create thumbnail: \(errorString)")
                        }
                        op.queuePriority = .veryLow
                        await frameGraphBuilder.add(operation: op)
                    }
                }
            }
            Log.d("done checking for missing images")
        }
    }


    // nonisolated so it doesn't run on the main thread
    nonisolated func makePreviews(imageAccessor: ImageAccessor) async throws {
        Log.d("writing missing images")

        try await imageAccessor.writeMissingImages() { _ in }
    }
    
    func makeCallbacks() -> Callbacks {
        var callbacks = Callbacks()

        callbacks.frameOutliersLoadedCallback = { [weak self] frameIndex, outliersLoaded in
            guard let self else { return }            
            Task { @MainActor [weak self] in
                self?.frames[frameIndex].outliersLoaded = outliersLoaded
            }
        }
        
        callbacks.frameStateChangeCallback = { [weak self] frame, newState in
            guard let self else { return }
            // Progress into the run marker, so a crash report can say how far the run got.
            // Outside the MainActor hop below because it does not touch view state.
            Task {
                await RunMarkerStore.shared.note(
                  phase: "\(newState)",
                  frameCompleted: newState == .complete ? frame.frameIndex : nil
                )
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previousState = self.frames[frame.frameIndex].frameState
                self.frames[frame.frameIndex].frameState = newState

                switch newState {
                case .horizonDetected:
                    self.frames[frame.frameIndex].refreshHorizonOverlay()
                    self.frames[frame.frameIndex].refreshFrameHorizonOverlay()
                default:
                    if previousState == .mergingHorizon {
                        self.frames[frame.frameIndex].refreshHorizonOverlay()
                        self.frames[frame.frameIndex].refreshFrameHorizonOverlay()
                    }
                }

                for state in FrameProcessingState.allCases {
                    if state == newState { continue }
                    if var stateItems = self.frameStateMap[state] {
                        stateItems.remove(frame)
                        self.frameStateMap[state] = stateItems
                    }
                }
                if var set = self.frameStateMap[newState] {
                    set.insert(frame)
                    self.frameStateMap[newState] = set
                } else {
                    self.frameStateMap[newState] = [frame]
                }
            }
        }

        // called when we should check a frame
        callbacks.frameCheckClosure = { [weak self] newFrame in
            guard let self else { return }            
            //Log.d("frameCheckClosure for frame \(newFrame.frameIndex)")
            Task { @MainActor [weak self] in
                await self?.addToViewModel(frame: newFrame)
            }
        }
        
        callbacks.frameSavingStateChangeCallback = { [weak self] frame, oldState, newState in
            guard let self else { return }            
            Task { @MainActor [weak self] in
                self?.frameSaveQueue.frameSavingStateChanged(for: frame,
                                                             from: oldState,
                                                             to: newState)
            }
        }
        
        return callbacks
    }

    var numberOfFramesProcessingNow: Int {
        frameGraphViewModel.numberOfFramesProcessingNow
    }

    var windowTitle: String {
        let sequenceDirname = self.config.config().imageSequenceDirname
        return localized("ui.window_title", sequenceDirname)
    }
    
    var selectionColor: Color {
        switch self.selectionMode {
        case .remove:
            .red
        case .keep:
            .green
        case .shovel:
            .gray
        case .razor:
            .yellow
        case .trash:
            .pink
        case .removeFromTrash:
            .mint
        case .information:
            .blue
        case .multi:
            .purple      // XXX ???
        case .none:
            .black
        }
    }

    // enum for how we show each frame
    var frameViewMode = FrameViewMode.original {
        didSet {
            previousFrameViewMode = oldValue
        }
    }


    fileprivate var videoPlaybackTask: Task<Void,Never>?

    private let videoPrefetchLookahead = 30
    var videoPrefetchCache: [Int: NSImage] = [:]
    
    var outlierLoadingProgress: Double {
        if imageSequenceSize == 0 { return 0 }
        return Double(numberOfFramesWithOutliersLoaded)/Double(imageSequenceSize)
    }
    
    var frameLoadingProgress: Double {
        if imageSequenceSize == 0 { return 0 }
        return Double(numberOfFramesLoaded)/Double(imageSequenceSize)
    }
    
    // currently selected index in the sequence
    var currentFrameView: FrameViewModel {
        if currentIndex < 0 { currentIndex = 0 }
        if currentIndex >= frames.count { currentIndex = frames.count - 1 }
        return frames[currentIndex]
    }

    var starAlignmentInfo: [[AlignmentWarpInfoCodable]] {
        var ret: [[AlignmentWarpInfoCodable]] = []

        for frame in frames {
            if let results = frame.frameObserver.starAlignmentResults {
                ret.append(results.neighborHomography)
            } else {
                ret.append([])
            }
        }
        return ret
    }

    var earthAlignmentInfo: [[AlignmentWarpInfoCodable]] {
        var ret: [[AlignmentWarpInfoCodable]] = []

        for frame in frames {
            if let results = frame.frameObserver.earthAlignmentResults {
                ret.append(results.neighborHomography)
            } else {
                ret.append([])
            }
        }
        return ret
    }
    
    var skyKeypointCounts: [Int] {
        var ret: [Int] = []
        for frame in frames {
            if let keypointCount = frame.frameObserver.numberOfSkyKeyPoints {
                ret.append(keypointCount)
            } else {
                ret.append(0)
            }
        }
        return ret
    }
    
    var earthKeypointCounts: [Int] {
        var ret: [Int] = []
        for frame in frames {
            if let keypointCount = frame.frameObserver.numberOfEarthKeyPoints {
                ret.append(keypointCount)
            } else {
                ret.append(0)
            }
        }
        return ret
    }
    
    var currentFrame: FrameAirplaneRemover? {
        if currentIndex >= 0,
           currentIndex < frames.count
        {
            return frames[currentIndex].frame
        }
        return nil
    }

    var loadingOutlierGroups: Bool {
        for frame in frames { if frame.loadingOutlierViews { return true } }
        return false
    }
    
    func set(numberOfFrames: Int) {
        self.frames = [FrameViewModel](count: numberOfFrames) {
            i in FrameViewModel(config, i)
        }
    }

    func cancelProcessing() {
        processingGeneration += 1
        isProcessingFrames = false
        sequenceProcessingState = .unprocessed
        processingModalShowing = false
        processingStatusText = nil
    }

    /// Stop the run: forget the frames still to come, and cancel the operations already on
    /// the queue.  What the Stop button under the frame does, and what the processing
    /// modal's Stop button does.
    func stopProcessing() {
        cancelProcessing()
        Task { await frameGraphBuilder.cancelAllOperations() }
    }

    /// Put the processing modal up for a run that is starting, unless the user has turned
    /// that off in Preferences.
    ///
    /// The baseline is taken whether or not the modal is shown, so that turning it off does
    /// not leave stale numbers behind for the next run that does show it.
    ///
    /// `steps` overrides the step list for a run that does not build a frame graph, which
    /// today means the horizon refinement re-run.  Rows are only filtered down to the ones
    /// with work once a graph build completes (`ProcessingSteps.visible`), and that run
    /// completes none — so it passes exactly the steps it is about to enqueue rather than
    /// the whole pipeline, which would otherwise sit at zero and read as stuck.
    private func startProcessingModal(steps: [OperationType]? = nil, status: String? = nil) {
        processingStepBaseline = frameGraphViewModel.operations
        processingBuildCount = frameGraphViewModel.graphBuildsCompleted
        processingStepTypes = steps ?? ProcessingSteps.types(for: config.config())
        processingStatusText = status
        if userPreferences.showProcessingWindow ?? true {
            processingModalShowing = true
        }
    }

    func processAll() {
        Log.d("processAll")
        // If the user has opted out of render prompts, start immediately.
        // Otherwise show the pre-processing "render after?" sheet, which
        // will call beginProcessing() once the user chooses.
        if userPreferences.skipRenderPromptAfterProcessing == true {
            autoRenderAfterProcessing = false
            beginProcessing()
        } else {
            preProcessingRenderPromptShowing = true
        }
    }

    /// The re-open panel's "Finish Processing" button — and its "Start Processing", which
    /// is the same button over a sequence nothing has been done to yet.
    ///
    /// `processAll` rather than a range starting at the first unwritten frame: the frames
    /// that are not finished are not necessarily a contiguous tail — a user can reprocess
    /// any frame, and a stopped run leaves holes wherever its workers happened to be — and
    /// `FrameGraphBuilder` already builds no merge op for a frame whose output is written.
    /// Running the whole sequence *is* finishing it, by the same route the startup
    /// questionnaire takes, render prompt preference and all.
    func finishProcessingOpenedSequence() {
        sequenceProgressModalShowing = false
        enterEditMode()
        processAll()
    }

    /// Pick up a run that stopped, from the "Restart Now" button on the alert that reported
    /// it (`ViewModel.restartAbandonedRun`).
    ///
    /// `beginProcessing()` rather than `processAll()`, which is what the panel's button
    /// takes: `processAll` stops to ask whether to render the video afterwards, and a button
    /// that says it restarts the run now must not answer with another question.  Nothing is
    /// lost by skipping it — `handleProcessingDone()` asks the same thing at the end of the
    /// run, when there is a video to render.
    ///
    /// Like `finishProcessingOpenedSequence`, this runs the whole sequence: the frames left
    /// undone by a killed run are not a contiguous tail, and `FrameGraphBuilder` builds no
    /// work for a frame whose output is already written.
    func restartProcessing() {
        guard frames.first?.frame != nil else {
            // Reachable only if the sequence failed to load, since the caller awaits the
            // open before getting here.  Silence would look like a button that does nothing.
            Log.w("cannot restart processing: no frames loaded")
            return
        }
        sequenceProgressModalShowing = false
        enterEditMode()
        autoRenderAfterProcessing = false
        beginProcessing()
    }

    /// The re-open panel's "Render Video" button.
    func renderVideoForOpenedSequence() {
        sequenceProgressModalShowing = false
        enterEditMode()
        renderVideoSheetShowing = true
    }

    /// Move to the mode the panel's actions need, on the way out of it.
    ///
    /// A sequence re-opened from a config file starts in `.scrub`, and both of the sheets
    /// those actions raise — the render sheet and the pre-processing render prompt — are
    /// attached inside `BottomRightView`'s edit-mode branch.  Setting their flag from
    /// `.scrub` would show nothing at all, and in the processing case would leave a run
    /// that never starts.  Edit mode is also where the frames, the outlier tools and the
    /// progress panels are, which is where someone who just asked for either of these
    /// wants to be next.
    private func enterEditMode() {
        interactionMode = .edit
    }

    // Called by PreProcessingRenderPromptView once the user has chosen.
    // - autoRender: render video automatically after processing succeeds
    // - dontAskAgain: persist the don't-ask preference (suppresses both prompts going forward)
    func confirmStartProcessing(autoRender: Bool, dontAskAgain: Bool) {
        if dontAskAgain {
            userPreferences.skipRenderPromptAfterProcessing = true
        }
        autoRenderAfterProcessing = autoRender
        preProcessingRenderPromptShowing = false
        beginProcessing()
    }

    private func beginProcessing() {
        Log.d("beginProcessing")
        // The run adopts whatever the settings now are, so this is the baseline the next
        // settings session compares against.  Until a run starts, a change the user made
        // and dismissed is still a change the frames on disk have not had.
        self.settingsSnapshot = config.config()
        self.isProcessingFrames = true
        self.startProcessingModal()
        processingGeneration += 1
        let capturedGen = processingGeneration
        if let frame = frames[0].frame {
            Task {
                Log.d("beginProcessing")
                await self.process(
                  frame: frame
                ) { processingState in
                    Log.d("beginProcessing")
                    Task { @MainActor in
                        guard self.processingGeneration == capturedGen else { return }
                        self.isProcessingFrames = false
                        switch processingState {
                        case .done:
                            self.handleProcessingDone()
                        case .error(let errorString):
                            Log.e("Error: \(errorString)")
                            self.topViewModel?.report(error: errorString)
                        default:
                            break
                        }
                        self.sequenceProcessingState = processingState
                    }
                }
            }
        }
    }

    private func handleProcessingDone() {
        if autoRenderAfterProcessing {
            // user already said yes in the pre-prompt — render directly
            autoRenderAfterProcessing = false
            renderVideoAutoStart = true
            renderVideoSheetShowing = true
        } else if userPreferences.skipRenderPromptAfterProcessing != true {
            // user hasn't suppressed prompts — ask whether to render now
            postProcessingRenderPromptShowing = true
        }
        // otherwise: user has opted out of all render prompts; do nothing
    }

    // Called by PostProcessingRenderPromptView when the user picks an option.
    // - autoStart: when true, the render begins immediately on the render sheet;
    //              when false, the render sheet shows its settings/preview view.
    func confirmRenderAfterProcessing(autoStart: Bool) {
        postProcessingRenderPromptShowing = false
        renderVideoAutoStart = autoStart
        renderVideoSheetShowing = true
    }

    func playFinalFrames() {
        postProcessingRenderPromptShowing = false
        frameViewMode = .final
        currentIndex = 0
        videoPlayMode = .forward
        if !videoPlaying {
            togglePlay()
        }
    }

    private nonisolated func process(
      frame: FrameAirplaneRemover,
      startIndex: Int = 0,
      endIndex: Int? = nil,      // will be last index of frames
      closure: @Sendable @escaping (SequenceProcessingState) -> Void
    ) async {
        Log.d("processAll")
        await frame.process(
          startIndex: startIndex,
          endIndex: endIndex,
          progressClosure: closure
        )
    }
    
    func refresh(frame: FrameAirplaneRemover) async {
        //        Log.d("refreshing frame \(frame.frameIndex)")
        
        // load the view frames from the main image
        
        // look for saved versions of these

        // let outlierTask: Task<Void,Never>?

        let acc = frame.imageAccessor

        var existingImages: Set<FrameViewMode> = []
        for type in FrameViewMode.allCases {
            if acc.imageExists(frameIndex: frame.frameIndex,
                               ofType: type,
                               atSize: .original)
            {
                existingImages.insert(type)
            }
        }
        
        self.frames[frame.frameIndex].existingImages = existingImages

        //Log.d("done refreshing frame \(frame.frameIndex)")
    }

    func append(frame: FrameAirplaneRemover) async {
      //Log.d("appending frame \(frame.frameIndex)")

        guard frame.frameIndex >= 0,
              frame.frameIndex < self.frames.count
        else {
            Log.w("cannot add frame with index \(frame.frameIndex) to array with \(self.frames.count) elements")
            return 
        }
        
        self.frames[frame.frameIndex].frame = frame

        numberOfFramesLoaded += 1
        if self.initialLoadInProgress {
            var haveAll = true
            for frame in self.frames {
                if frame.frame == nil {
                    haveAll = false
                    break
                }
            }
            if haveAll {
                Log.d("WE HAVE THEM ALL")
//                await MainActor.run {
                    self.initialLoadInProgress = false
//                }
            }
        }
        //Log.d("set self.frames[\(frame.frameIndex)].frame")

        await refresh(frame: frame)
    }

    
    func frame(atIndex index: Int) -> FrameAirplaneRemover? {
        if index < 0 { return nil }
        if index >= frames.count { return nil }
        return frames[index].frame
    }
    
    func nextFrame() -> FrameViewModel {
        if isMultiSelecting {
            let sorted = sortedSelectedIndices
            if let pos = sorted.firstIndex(of: currentIndex) {
                currentIndex = sorted[(pos + 1) % sorted.count]
            }
        } else {
            if currentIndex < frames.count - 1 {
                currentIndex += 1
            }
        }
        Log.d("next frame returning frame from index \(currentIndex)")
        if let frame = frames[currentIndex].frame {
            Log.d("frame has index \(frame.frameIndex)")
        } else {
            Log.d("NO FRAME")
        }
        return frames[currentIndex]
    }

    func previousFrame() -> FrameViewModel {
        if isMultiSelecting {
            let sorted = sortedSelectedIndices
            if let pos = sorted.firstIndex(of: currentIndex) {
                let count = sorted.count
                currentIndex = sorted[(pos - 1 + count) % count]
            }
        } else {
            if currentIndex > 0 {
                currentIndex -= 1
            } else {
                currentIndex = 0
            }
        }
        return frames[currentIndex]
    }

    func shouldShowOutlierGroupTableWindow() -> Bool {
        let windows = NSApp.windows
        var show = true
        for window in windows {
            Log.d("window.title \(window.title) window.subtitle \(window.subtitle) ")
            if window.title.hasPrefix(OUTLIER_WINDOW_PREFIX) {
                window.makeKey()
                window.orderFrontRegardless()
                //window.objectWillChange.send()
                show = false
            }
        }
        return show
    }


    func addToViewModel(frame newFrame: FrameAirplaneRemover) async {
        //Log.d("addToViewModel(frame: \(newFrame.frameIndex))")

        if self.config == nil {
            Log.e("FUCK, config is nil")
        }
        if self.frameWidth != CGFloat(newFrame.width) ||
             self.frameHeight != CGFloat(newFrame.height)
        {
            // grab frame size from first frame
            self.frameWidth = CGFloat(newFrame.width)
            self.frameHeight = CGFloat(newFrame.height)
        }
        await self.append(frame: newFrame)
        
        // Log.d("addToViewModel self.frame \(self.frame)")
    }
//}

// methods used in image sequence view
//public extension ImageSequenceViewModel {
    func setAllCurrentFrameOutliers(to shouldRemove: Bool,
                                    renderImmediately: Bool = true)
    {
        let currentFrameView = self.currentFrameView
        setAllFrameOutliers(in: currentFrameView,
                            to: shouldRemove,
                            renderImmediately: renderImmediately)
    }


    func setUndecidedFrameOutliers(to shouldRemove: Bool,
                                   renderImmediately: Bool = true)
    {
        let currentFrameView = self.currentFrameView
        setUndecidedFrameOutliers(in: currentFrameView,
                                  to: shouldRemove,
                                  renderImmediately: renderImmediately)
    }
    
    func setUndecidedFrameOutliers(in frameView: FrameViewModel,
                                   to shouldRemove: Bool,
                                   renderImmediately: Bool = true)
    {
    //    let reason = RemoveReason.userSelected(shouldRemove)
        
        if let frame = frameView.frame {
            // update the real actor in the background
            Task.detached(priority: .userInitiated) {
                await frame.userSelectUndecidedOutliers(toShouldRemove: shouldRemove,
                                                        includingTrash: self.shouldShowTrash)

                if renderImmediately {
                    // XXX make render here an option in settings
                    try await self.render(frame: frame) {
                    }
                }
            }
        } else {
            Log.w("frame \(frameView.frameIndex) has no frame")
        }
    }
    
    func setAllFrameOutliers(in frameView: FrameViewModel,
                             to shouldRemove: Bool,
                             renderImmediately: Bool = true)
    {
        Log.d("setAllFrameOutliers in frame \(frameView.frameIndex) to should remove \(shouldRemove)")
        
        if let frame = frameView.frame {
            // update the real actor in the background
            Task.detached {
                await frame.userSelectAllOutliers(toShouldRemove: shouldRemove,
                                                  includingTrash: self.shouldShowTrash)

                if renderImmediately {
                    // XXX make render here an option in settings
                    try await self.render(frame: frame) {
                    }
                }
            }
        } else {
            Log.w("frame \(frameView.frameIndex) has no frame")
        }
    }

    func processSelectedFrames(with type: FrameReprocessingType) {
        let indices = isMultiSelecting ? sortedSelectedIndices : [currentIndex]
        guard let minIndex = indices.min(), let maxIndex = indices.max() else { return }
        processFrames(from: minIndex, to: maxIndex,
                      performClean: type != .none,
                      overrideReprocessingType: type)
    }

    func processFrames(
      from startIndex: Int,
      to endIndex: Int? = nil,
      performClean: Bool = false,
      overrideReprocessingType: FrameReprocessingType? = nil
    ) {
        Log.d("processing frames from \(startIndex) to \(endIndex)")
        //if isProcessingFrames { return }
        isProcessingFrames = true
        startProcessingModal()

        Log.d("processAllFrames start from \(startIndex) to \(endIndex)")

        Task.detached(priority: .medium) { [self] in
            let reprocessingType: FrameReprocessingType
            if let override = overrideReprocessingType {
                reprocessingType = override
            } else {
                reprocessingType = await self.reprocessingType
            }
            Log.d("processAllFrames 1")

            if performClean {
                var lastIndex = await frames.count - 1
                if let endIndex { lastIndex = endIndex }
                for i in startIndex...lastIndex {
                    if let frame = await frames[i].frame {
                        switch reprocessingType {
                        case .everything:
                            await frame.deleteAllProcessedImages()
                            try? await frame.deleteOutliers()
                            try? await self.clearProcessing(of: frame)
                            
                        case .none:
                            break
                        case .allHorizons:
                            break
                        case .horizons:
                            await frame.deleteHorizonImages()
                        case .alignment:
                            try await self.clearProcessing(of: frame)
                        case .outliers:
                            try await self.clearProcessing(of: frame)
                            try await frame.deleteOutliers()
                        }
                    }
                }
            }
            
            if let frame = await frames[0].frame {
                await self.process(
                  frame: frame,
                  startIndex: startIndex,
                  endIndex: endIndex
                ) { processingState in
                    Task { @MainActor in
                        self.isProcessingFrames = false
                    }
                }
            } else {
                Log.e("no frames")
            }
        }
    }

    func clearProcessing(from startIndex: Int, to endIndex: Int) async throws {
        Log.d("clearing processing from \(startIndex) to \(endIndex)")
        for index in startIndex...endIndex {
            if index < frames.count,
               let frame = frames[index].frame
            {
                try await clearProcessing(of: frame)
            }
        }
        Log.d("done clearing processing from \(startIndex) to \(endIndex)")
    }    

    func clearProcessing(of frame: FrameAirplaneRemover) async throws {
        try await Task.detached(priority: .userInitiated) { // do we need this detached task?
            let frameToClear = frame

            await frameToClear.set(state: .unprocessed)
            //await frameToClear.updateCombineSubjects()

            // this now does delete the alignment and subtraction images too
            await frameToClear.imageAccessor.deleteAllImages(
              frameIndex: frameToClear.frameIndex,
              reprocessingType: self.reprocessingType
            )

            await frameToClear.setNumberOfAlignedFrames()
            await frameToClear.setNumberOfStaticNeighborFrames()

            try await frameToClear.removeNumberOfAlignedImagesForThisFrameFile()
            
            Task { @MainActor in
                self.frameViewMode = .original
            }

            var existingImages: Set<FrameViewMode> = []
            for type in FrameViewMode.allCases {
                if frame.imageAccessor.imageExists(
                     frameIndex: frame.frameIndex,
                     ofType: type,
                     atSize: .original
                   )
                {
                    existingImages.insert(type)
                }
            }

            Task { @MainActor in
                self.frames[frame.frameIndex].existingImages = existingImages
            }
            
            let binaryBlobFilename = await frameToClear.blobBinaryFilename
            // get rid of the outlier files
            do {
                Log.d("trying to remove \(binaryBlobFilename)")
                try FileManager.default.removeItem(atPath: binaryBlobFilename)
            } catch {
                Log.e("error removing \(binaryBlobFilename): \(error)")
            }

            let trashBinaryFilename = await frameToClear.trashBinaryFilename
            do {
                Log.d("trying to remove \(trashBinaryFilename)")
                try FileManager.default.removeItem(atPath: trashBinaryFilename)
            } catch {
                Log.e("error removing \(trashBinaryFilename): \(error)")
            }

            Task { @MainActor in
                let frameView = self.frames[frameToClear.frameIndex]
                frameView.trashImage = nil
                frameView.positiveOutlierImage = nil
                frameView.negativeOutlierImage = nil
                frameView.outlierViews = nil
            }
        }.value
    }
    
    // used to re-process a particular frame 
    func findOutliersAndRender(frame: FrameAirplaneRemover) {
        // XXX
        let frameView = self.frames[frame.frameIndex]
        frameView.outlierViews = nil
            //frameView.loadingOutliersViews = true
        Task.detached(priority: .userInitiated) { [self] in
            do {
                await frame.initializeEmptyOutlierGroups()
                try await frame.findOutliers()

                // XXX set state
                await frame.set(state: .secondClassification)
                
                await frame.applyDecisionTreeToAllOutliers()
                
                try await self.render(frame: frame, now: true) {
                    Task {
                        await frameView.setOutlierGroups()
                    }
                }
            } catch {
                Log.e("error finding outliers for frame \(frame.frameIndex): \(error)")
                await self.report(error: localized("ui.error_processing_frame", frame.frameIndex, error))
            }
        }
    }
    
    func render(frame: FrameAirplaneRemover,
                now saveNow: Bool = false,
                ever saveEver: Bool = true,
                closure: (@Sendable () async -> Void)? = nil) async throws
    {
        if saveNow {
            try await self.frameSaveQueue.saveNow(frame: frame) {
                await closure?()
            }
        } else if saveEver {
            await self.frameSaveQueue.readyToSave(frame: frame) {
                await closure?()
            }
        }
    }

    // next frame entry point
    func transition(numberOfFrames: Int) {
        if isMultiSelecting {
            let sorted = sortedSelectedIndices
            guard let pos = sorted.firstIndex(of: currentIndex) else { return }
            let count = sorted.count
            let newPos = ((pos + numberOfFrames) % count + count) % count
            self.currentIndex = sorted[newPos]
        } else {
            var newIndex = self.currentIndex + numberOfFrames
            if newIndex < 0 { newIndex = 0 }
            if newIndex >= self.frames.count {
                newIndex = self.frames.count-1
            }
            self.currentIndex = newIndex
        }
    }

    func transition(until fastAdvancementType: FastAdvancementType,
                    from frame: FrameViewModel,
                    forwards: Bool,
                    currentIndex: Int? = nil)
    {
        var frameIndex: Int = 0
        if let currentIndex = currentIndex {
            frameIndex = currentIndex
        } else {
            frameIndex = frame.frameIndex
        }
        
        if (!forwards && frameIndex == 0) ||  
           (forwards && frameIndex >= self.frames.count - 1)
        {
            if frameIndex != frame.frameIndex {
                self.currentIndex = frameIndex
            }
            return
        }
        
        var nextFrameIndex = 0
        if forwards {
            nextFrameIndex = frameIndex + 1
        } else {
            nextFrameIndex = frameIndex - 1
        }
        let nextFrameView = self.frames[nextFrameIndex]

        var skip = false

        switch fastAdvancementType {
        case .normal:
            skip = false 

        case .skipEmpties:
            if let outlierViews = nextFrameView.outlierViews {
                skip = outlierViews.count == 0
            }

        case .toNextPositive:
          if let num = nextFrameView.frameObserver.numberOfPositiveOutliers {
                skip = num == 0
            }

        case .toNextNegative:
          if let num = nextFrameView.frameObserver.numberOfNegativeOutliers {
                skip = num == 0
            }

        case .toNextUnknown:
          if let num = nextFrameView.frameObserver.numberOfUndecidedOutliers {
                skip = num == 0
            }
        }
        
        // skip this one
        if skip {
            self.transition(until: fastAdvancementType,
                            from: frame,
                            forwards: forwards,
                            currentIndex: nextFrameIndex)
        } else {
            self.currentIndex = nextFrameView.frameIndex
        }
    }

    // used when advancing between frames
    func saveToFile(frame frameToSave: FrameAirplaneRemover,
                    completionClosure: @Sendable @escaping () async -> Void)
    {
        Log.d("saveToFile frame \(frameToSave.frameIndex)")
        let frameSaveQueue = self.frameSaveQueue 
        Task.detached(priority: .userInitiated) {
            await frameSaveQueue.readyToSave(frame: frameToSave,
                                             completionClosure: completionClosure)
        }
    }

    // starts or stops video from playing
    func togglePlay() {
        self.videoPlaying = !self.videoPlaying
        if self.videoPlaying {

            self.previousInteractionMode = self.interactionMode
            // cannot edit while playing video
            self.interactionMode = .scrub

            Log.d("playing @ \(self.videoPlaybackFramerate) fps")

            let interval = 1/Double(self.videoPlaybackFramerate)

            self.backgroundColor = .black

            // seed the prefetch cache with the first lookahead frames before the loop starts
            switch self.videoPlayMode {
            case .forward:
                let seedEnd = min(currentIndex + videoPrefetchLookahead + 1, frames.count)
                for i in currentIndex..<seedEnd { prefetchVideoFrame(i) }
            case .reverse:
                let seedStart = max(currentIndex - videoPrefetchLookahead, 0)
                for i in stride(from: currentIndex, through: seedStart, by: -1) { prefetchVideoFrame(i) }
            }

            videoPlaybackTask = Task {
                while(!Task.isCancelled) {

                    let startTime = NSDate().timeIntervalSince1970

                    var nextVideoFrame: Int = 0

                    switch self.videoPlayMode {
                    case .forward:
                        nextVideoFrame = self.currentIndex + 1

                    case .reverse:
                        nextVideoFrame = self.currentIndex - 1
                    }

                    if nextVideoFrame >= self.frames.count {
                        self.stopVideo()
                        self.currentIndex = self.frames.count - 1
                    } else if nextVideoFrame < 0 {
                        self.stopVideo()
                        self.currentIndex = 0
                    } else {
                        self.currentIndex = nextVideoFrame
                        switch self.videoPlayMode {
                        case .forward:
                            self.prefetchVideoFrame(self.currentIndex + self.videoPrefetchLookahead)
                        case .reverse:
                            self.prefetchVideoFrame(self.currentIndex - self.videoPrefetchLookahead)
                        }
                        self.evictVideoPrefetchCache(currentIndex: self.currentIndex)
                    }

                    let secondsLeft = interval - (NSDate().timeIntervalSince1970 - startTime)
                    if(secondsLeft > 0) {
                        try? await Task.sleep(nanoseconds: UInt64(secondsLeft*1_000_000_000))
                    }
                }
            }
        } else {
            stopVideo()
        }
    }

    func stopVideo() {
        videoPlaybackTask?.cancel()
        videoPrefetchCache.removeAll()

        self.interactionMode = self.previousInteractionMode

        self.videoPlaying = false
        self.backgroundColor = ViewModel.defaultBackgroundColor
    }

    private func prefetchVideoFrame(_ index: Int) {
        guard index >= 0 && index < frames.count else { return }
        guard videoPrefetchCache[index] == nil else { return }
        let frameVM = frames[index]
        let mode = self.frameViewMode
        guard let frame = frameVM.frame,
              let url = frame.imageAccessor.urlForImage(
                frameIndex: frame.frameIndex,
                ofType: mode,
                atSize: .preview
              )
        else { return }
        Task.detached(priority: .utility) {
            guard let data = try? Data(contentsOf: url) else { return }
            await MainActor.run { [weak self] in
                guard let self else { return }
                guard let image = NSImage(data: data) else { return }
                self.videoPrefetchCache[index] = image
            }
        }
    }

    private func evictVideoPrefetchCache(currentIndex: Int) {
        switch videoPlayMode {
        case .forward:
            for key in videoPrefetchCache.keys where key < currentIndex - 2 {
                videoPrefetchCache.removeValue(forKey: key)
            }
        case .reverse:
            for key in videoPrefetchCache.keys where key > currentIndex + 2 {
                videoPrefetchCache.removeValue(forKey: key)
            }
        }
    }

    func goToFirstFrameButtonAction() {
        self.currentIndex = 0
    }

    func goToLastFrameButtonAction() {
        self.currentIndex = self.frames.count-1
    }

    func fastPreviousButtonAction() {
        if self.fastAdvancementType == .normal {
            self.transition(numberOfFrames: -self.fastSkipAmount)
        } else {
            self.transition(until: self.fastAdvancementType,
                            from: self.currentFrameView,
                            forwards: false)
        }
    }

    func fastForwardButtonAction() {
        if self.fastAdvancementType == .normal {
            self.transition(numberOfFrames: self.fastSkipAmount)
        } else {
            self.transition(until: self.fastAdvancementType,
                            from: self.currentFrameView,
                            forwards: true)
        }
    }

    var currentFrameUsesOutliers: Bool {
        switch currentFrameHighLevelCleanMethod {
        case .automatic:
            switch currentFrameAutoPreservationMode {
            case .yes:
                true
            case .no:
                false
            }
        case .selective:
            true
        }
    }

    var currentFrameHighLevelCleanMethod: HighLevelCleanMethod = .automatic {
        didSet {
            self.updateCleanMethod()
        }
    }
    
    var currentFrameAutoPreservationMode: AutoPreservationMode = .no  {
        didSet {
            self.updateCleanMethod()
        }
    }

    // update the CleanMethod for the current frame
    // from the two vars above
    private func updateCleanMethod() {
        let newMethod = CleanMethod(
            highLevelCleanMethod: currentFrameHighLevelCleanMethod,
            autoPreservationMode: currentFrameAutoPreservationMode
        )
        let oldMethod = getCleanMethod(forFrame: currentIndex)
        if oldMethod != newMethod {
            self.set(
              cleanMethod: newMethod,
              forFrame: currentIndex
            )
            // XXX show outliers if necessary
        }
    }
    
    
    //private var videoRenderTask: Task<Void>? = nil
    
    func renderVideo(named filename: String,
                     frameRate: FrameRate,
                     encoder: FFmpegEncoder,
                     pixelFormat: FFmpegPixelFormat,
                     muxer: FFmpegMuxer,
                     progress: @escaping ProgressCallback,
                     completion: @escaping @Sendable () -> Void,
                     errorCallback: @escaping @Sendable (Error) -> Void)
    {
        let totalNumberOfFrames = self.frames.count
        let rawFrameRate = frameRate.rawString

        let realConfig = config.config()
        let outputPath = realConfig.outputPath
        let basename = realConfig.basename

        /*
         # this is what the timelapse render daemon uses:
         
         my $ffmpeg_cmd = "ffmpeg -y -r $frame_rate -i $image_sequence_full_dirname/$config->{image_name_prefix}%05d$image_type -aspect $aspect_ratio $filter_str -c:v $output_codec -pix_fmt $pix_fmt_str -threads 0 -profile:v 1 -movflags +write_colr -an -color_range $color_range -color_primaries bt709 -colorspace bt709 -color_trc bt709 -timecode 00:00:00:00 ";
 */
        
        let hasAudio = realConfig.hasAudio
        let audioPath = "\(realConfig.imageSequencePath)/\(realConfig.imageSequenceDirname)/audio.aac"

        /*videoRenderTask = */Task.detached {
            do {
                var arguments: [String] = [
                    "-y",                                                              // overwrite
                    "-framerate", rawFrameRate,                                        // frame rate
                    "-pattern_type", "glob", "-i",                                    // input image glob
                    "\(outputPath)/\(basename)/*.\(realConfig.fileExtension)",        // input images
                ]
                if hasAudio {
                    arguments += ["-i", audioPath]
                }
                arguments += [
                    "-c:v", encoder.rawValue,         // encoder
                    "-pix_fmt", pixelFormat.rawValue, // pixel format
                ]
                if hasAudio {
                    arguments += ["-c:a", "copy"]
                }
                arguments += [
                    "-f", muxer.rawValue,             // muxer
                    "\(outputPath)/\(filename)"       // output filename
                ]
                try runFFmpegWithProgress(
                  arguments: arguments,
                  totalFrames: totalNumberOfFrames,
                  outputFolder: outputPath,
                  progress: progress)
                completion()
            } catch {
                Log.e("video encoding error: \(error)")
                errorCallback(error)
            }
        }
    }
/*
    func processHorizonForAllFrames(redo: Bool = false) async throws {

        if let frame = await self.frames[0].frame {
            try await frame.processHorizonForAllFrames(redo: redo)
        }

        Log.d("done with all horizons")
        
    }*/
}

final class AppNapDisabler {
    private var activity: NSObjectProtocol?

    func begin() {
        activity = ProcessInfo.processInfo.beginActivity(
            options: [
                .userInitiated,
                .idleSystemSleepDisabled,
                .suddenTerminationDisabled
            ],
            reason: "Long-running video processing"
        )
    }

    func end() {
        if let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }
}

// Shared state protected by actor
actor FrameAccumulator {
    var frames: [FrameAirplaneRemover] = []
    var numberLoaded = 0

    func append(_ frame: FrameAirplaneRemover) -> Int {
        let insertAt = frames.firstIndex { $0.frameIndex > frame.frameIndex } ?? frames.count
        frames.insert(frame, at: insertAt)
        numberLoaded += 1
        return numberLoaded
    }

    func allFrames() -> [FrameAirplaneRemover] {
        frames
    }
}

actor IndexDistributor {
    private var next = 0
    private let max: Int

    init(max: Int) { self.max = max }

    func nextIndex() -> Int? {
        guard next < max else { return nil }
        defer { next += 1 }
        return next
    }
}
