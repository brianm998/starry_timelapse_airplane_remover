import Foundation
import SwiftUI
import Cocoa
import StarCore
import Semaphore
import logging
import kht_bridge

public enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
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
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
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
            return "Remove"
        case .keep:
            return "Keep"
        case .razor:
            return "Razor"
        case .shovel:
            return "Shovel"
        case .trash:
            return "Trash"
        case .removeFromTrash:
            return "Get from Trash"
        case .multi:
            return "Multi"
        case .information:
            return "Information"
        case .none:
            return "None"
        }
    }
}

public enum InteractionMode: String, Equatable, CaseIterable {
    case edit
    case scrub

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

// used to limit processing of frames to this max concurrent number
public let frameProcessingMonitor = FileSystemMonitor(max: 32) // XXX make this configurable

// used for loading frames, loading 20 at a time is faster than 1000
fileprivate let frameLoadMonitor = FileSystemMonitor(max: 28) // XXX make this configurable


// view model for a sequence of images
@MainActor @Observable
public final class ImageSequenceViewModel {
    let config: ConfigManager

    var userPreferences: UserPreferences = UserPreferences() {
        didSet {
            if let detectionType = userPreferences.processingType {
                self.detectionType = detectionType
            }
            if let concurrentFrames = userPreferences.concurrentFrames {
                self.numberOfFramesToProcessConcurrently = concurrentFrames
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
    
    var eraser: NighttimeAirplaneRemover?

    var noImageExplainationText: String = "Loading..."

    var backgroundColor = ViewModel.defaultBackgroundColor

    var frameStateMap: [FrameProcessingState: Set<FrameAirplaneRemover>] = [:]

    var frameSaveQueue = FrameSaveQueue()

    var frameOpacity: Double = 1.0
    
    var videoPlayMode: VideoPlayMode = .forward
    
    var videoPlaying = false

    var leftPanelShowing = true
    var rightPanelShowing = true
    
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

    // the view mode that we set this image with

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
    var isFindingAllHorizons = false
    var numberOfFramesProcessed = 0

    var isRenderingVideo = false
    
    var showHorizonBar = false
    
    var ignoreLowerPixels: CGFloat = 0

    var outlierOpacity = 1.0

    var trashOpacity = 0.7

    var interactionMode: InteractionMode = .scrub

    var previousInteractionMode: InteractionMode = .scrub

    var previousFrameViewMode = FrameViewMode.final

    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    var showFullResolution = false

    var showFilmstrip = true

    // causes tapping an outlier to open a dialog with multiple choices
    var multiChoice = false
    
    var renderingAllFrames = false
    var updatingFrameBatch = false

    var videoPlaybackFramerate = 30

    var multiSelectSheetShowing = false

    var renderVideoSheetShowing = false

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

    // instead of finding keypoints and matching them to product homography,
    // use the best existing homography for this sequence instead
    var useExistingHomography = false
    
    // the frame number of the frame we're currently showing
    var currentIndex = 0 {
        didSet {
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

    var numberOfFramesToProcessConcurrently: Int

    // for final processing of outliers
    var numberOfNeighborFrames: Int {
        didSet {
            var realConfig = config.config()
            realConfig.numberFinalProcessingNeighborsNeeded = numberOfNeighborFrames
            config.update(realConfig)
        }
    }

    // used when camera is not moving for merging horizons
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

    var horizonStripWidth: Int {
        didSet {
            var realConfig = config.config()
            realConfig.horizonStripWidth = horizonStripWidth
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
    
    var earthAlignedImageCropAmount: Int {
        didSet {
            var realConfig = config.config()
            realConfig.earthAlignedImageCropAmount = earthAlignedImageCropAmount
            config.update(realConfig)
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

    var cameraMotion: CameraMotion {
        didSet {
            var realConfig = config.config()
            realConfig.tripodHeadWasMoving = cameraMotion != .fixed
            config.update(realConfig)
        }
    }

    var horizonVerticalShiftAmount: Int {
        didSet {
            var realConfig = config.config()
            realConfig.horizonVerticalShiftAmount = horizonVerticalShiftAmount
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

    var runSecondAlignmentPass: Bool {
        didSet {
            var realConfig = config.config()
            realConfig.runSecondAlignmentPass = runSecondAlignmentPass
            config.update(realConfig)
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
    
    public var alignmentNeighborDilateSize: Int {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentNeighborDilateSize = alignmentNeighborDilateSize
            config.update(realConfig)
        }
    }
    
    public var alignmentNeighborThresholdValue: Int {
        didSet {
            var realConfig = config.config()
            realConfig.alignmentNeighborThresholdValue = alignmentNeighborThresholdValue
            config.update(realConfig)
        }
    }
    
    var maxConcurrentHorizonCalculations: Int {
        didSet {
            var realConfig = config.config()
            realConfig.maxConcurrentHorizonCalculations = maxConcurrentHorizonCalculations
            config.update(realConfig)
        }
    }
    
    // the threshold used in goodPixels(thresholdFactor: )
    var pixelThreshold: Double = 1.2
    
    // number of frames in the sequence we're processing
    var imageSequenceSize: Int = 0

    var finalProcessor: FinalGUIProcessor?

    var shouldShowInitialInstructions: Bool = false

    var shouldShowProcessingSettings: Bool = false

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
    
    convenience init(withConfig jsonConfigFilename: String,
                     closure: @escaping @Sendable (Int, Double, Int, Double) -> Void) async throws
    {
        Log.d("outlier_json_startup with \(jsonConfigFilename)")
        // first read config from json

        let config = try ConfigManager(configFilename: jsonConfigFilename)

        try await self.init(with: config, closure: closure)
    }
    
    convenience init(withNewImageSequence imageSequenceDirname: String,
                     and videoInfo: VideoInfo? = nil,
                     closure: @Sendable @escaping (Int, Double, Int, Double) -> Void) async throws
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
        
        let configFilename = "\(config.basename)-config.json"
        
        let configManager = ConfigManager(configFilename: configFilename, config: config)

        try await self.init(with: configManager, closure: closure)

        if config.writeOutlierGroupFiles {
            mkdir(config.outlierOutputDirname)
        }
        self.interactionMode = .edit
        self.shouldShowInitialInstructions = true
        self.showHorizonBar = true
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
      with configManager: ConfigManager,
      closure: @Sendable @escaping (Int, Double, Int, Double) -> Void
    ) async throws {
        self.trashLevel = await constants.getTrashLevel()
        self.smallTrashMax = await constants.getSmallTrashMax()

        self.appNapDisabler = AppNapDisabler()
        
        let config = configManager.config()

        if !config.cleanMethod.usesOutliers {
            self.selectionMode = .none
        } 

        self.numberOfAlignedNeighborFrames = config.numberAlignedNeighborFrames
        self.numberStaticNeighborFrames = config.numberStaticNeighborFrames
        self.horizonDetectionEnabled = config.horizonDetectionEnabled
        self.useCannyForHorizonDetection = config.useCannyForHorizonDetection ? .yes : .no
        self.horizonStripWidth = config.horizonStripWidth
        self.cannyMinThreshold = config.cannyMinThreshold
        self.cannyMaxThreshold = config.cannyMaxThreshold
        self.cannyUseL2Gradient = config.cannyUseL2Gradient ? .L2norm : .L1norm
        self.numberOfNeighborFrames = config.numberFinalProcessingNeighborsNeeded
        self.cleanMethod = config.cleanMethod
        self.pixelReplacementOverrides = config.pixelReplacementOverrides
        self.cameraMotion = config.tripodHeadWasMoving ? .moving : .fixed
        self.maxConcurrentHorizonCalculations = config.maxConcurrentHorizonCalculations
        self.horizonVerticalShiftAmount = config.horizonVerticalShiftAmount
        self.allowEarthAlignment = config.allowEarthAlignment
        self.runSecondAlignmentPass = config.runSecondAlignmentPass

        self.alignmentMaxKeypoints = config.alignmentMaxKeypoints
        self.alignmentGroundHorizonExtension = config.alignmentGroundHorizonExtension
        self.alignmentSkyHorizonExtension = config.alignmentSkyHorizonExtension
        self.alignmentBaseImageDilateSize = config.alignmentBaseImageDilateSize
        self.alignmentBaseImageThresholdValue = config.alignmentBaseImageThresholdValue
        //
        self.alignmentNeighborDilateSize = config.alignmentNeighborDilateSize
        self.alignmentNeighborThresholdValue = config.alignmentNeighborThresholdValue
        self.alignmentWriteDebugImages = config.alignmentWriteDebugImages
        //
        
        self.config = configManager

//        self.earthAlignedImageCropAmount = config.earthAlignedImageCropAmount ?? 0
        
        self.numberOfFramesToProcessConcurrently = await Task { await maxFramesProcessing.getValue() }.value
        
        let ignoreLowerPixels = config.ignoreLowerPixels 
        self.ignoreLowerPixels = CGFloat(ignoreLowerPixels) // XXX need to sync back the other dir
                    
        Log.d("loaded config \(config.imageSequenceDirname)")
        
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
        
        self.earthAlignedImageCropAmount = config.earthAlignedImageCropAmount ?? Int(imageInfo.imageHeight)/2
        
        self.frameSaveQueue.viewModel = self
        
        let callbacks = self.makeCallbacks()

        if let imageSequenceSizeClosure = callbacks.imageSequenceSizeClosure {
            let imageSequenceSize = await imageSequence.filenames.count
            imageSequenceSizeClosure(imageSequenceSize)
        }
        
        Log.d("loaded imageInfo \(imageInfo)")

        let filenames = await imageSequence.filenames

        var frameIndexToBaseNameMap: [Int: String] = [:]
        
        for (frameIndex, filename) in filenames.enumerated() {
            frameIndexToBaseNameMap[frameIndex] = removePath(fromString: filename)
        }

        // make image accessor here now
        // the image accessor always has the original config
        let imageAccessor = ImageAccessor(
          config: configManager.config(),
          imageSequence: imageSequence,
          frameIndexToBaseNameMap: frameIndexToBaseNameMap
        ) { [weak self] image, frameIndex, type, size in
            Task { @MainActor in
                Log.d("frame \(frameIndex) saved image of type \(type) at size \(size)")
                self?.frames[frameIndex].saved(image: image, ofType: type, atSize: size)
            }
        }

        self.appNapDisabler.begin()
        
        Log.d("make missing previews")

        self.finalProcessor = FinalGUIProcessor(self)

        self.matInstancesTask = Task { [weak self] in 
            while(self != nil) { 
                let instances = MatWrapper.totalInstances
                let bytes = MatWrapper.totalBytes
                Task { @MainActor in
                    self?.totalMatInstances = Int(instances)
                    self?.totalMatBytes = Int(bytes)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
        
        
        var numberPreviewsSaved = 0

        Task(priority: .utility) { [imageAccessor] in
          Log.d("writing missing images")
          try await imageAccessor.writeMissingImages() { numberSaved in
              Task { @MainActor in 
                  numberPreviewsSaved += 1
                  //Log.d("numberSaved \(numberSaved) numberPreviewsSaved \(numberPreviewsSaved)")
                  let amountPreviewsSaved = Double(numberPreviewsSaved)/Double(self.imageSequenceSize)
                  closure(numberPreviewsSaved, amountPreviewsSaved, 0, 0)
              }
            }
        }
        
        Log.d("done with make missing previews")
//        Log.d("make missing thumbnails")
//        try await imageAccessor.writeMissingImages(atSize: .thumbnail)
//        Log.d("done make missing thumbnails")

        try await withThrowingTaskGroup(of: FrameAirplaneRemover.self) { taskGroup in
            
            for (frameIndex, filename) in filenames.enumerated() {

                //Log.d("add task at frameIndex \(frameIndex)")

                taskGroup.addTask() {
                    let basename = removePath(fromString: filename)
                    let frame = try await frameLoadMonitor.load() {
                        try await FrameAirplaneRemover(
                          with: configManager,
                          width: imageInfo.imageWidth,
                          height: imageInfo.imageHeight,
                          componentsPerPixel: imageInfo.componentsPerPixel,
                          callbacks: callbacks,
                          imageSequence: imageSequence,
                          atIndex: frameIndex,
                          outputFilename: "\(config.outputPath)/\(config.basename)",
                          baseName: basename,
                          fullyProcess: false,
                          writeOutputFiles: true,
                          imageAccessor: imageAccessor
                        )
                    }
                    if let callback = callbacks.frameCheckClosure { 
                        await MainActor.run {
                            callback(frame)
                        }
                    }
                    return frame
                }
            }

            var incomingFrames = await [FrameAirplaneRemover?](
              repeating: nil,
              count: imageSequence.filenames.count
            )

            var numberOfLoadedFrames = 0
            
            for try await frame in taskGroup {
                numberOfLoadedFrames += 1
                // call the callback here on the main thread
                let update = Double(numberOfLoadedFrames)/Double(imageSequenceSize)
                closure(numberPreviewsSaved, 1, numberOfLoadedFrames, update)
                incomingFrames[frame.frameIndex] = frame
            }

            var frames: [FrameAirplaneRemover] = []

            for frame in incomingFrames {
                if let frame {
                    frames.append(frame)
                } else {
                    fatalError("FUCK")
                }
            }
            
            // doubly link them here
            await doublyLink(frames: frames)

            self.initialLoadInProgress = false
        }

        // Update All Frame View Models
        for frame in frames {
            if frame.frameIndex == currentIndex {
                switch frame.cleanMethod {
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

    func makeCallbacks() -> Callbacks {
        var callbacks = Callbacks()

        // get the full number of images in the sequence
        callbacks.imageSequenceSizeClosure = { [weak self] imageSequenceSize in
            guard let self else { return }            
            Task { @MainActor [weak self] in
                self?.imageSequenceSize = imageSequenceSize
                Log.i("read imageSequenceSize \(imageSequenceSize)")
                self?.set(numberOfFrames: imageSequenceSize)
            }
        }

        callbacks.frameOutliersLoadedCallback = { [weak self] frameIndex, outliersLoaded in
            guard let self else { return }            
            Task { @MainActor [weak self] in
                self?.frames[frameIndex].outliersLoaded = outliersLoaded
            }
        }
        
        callbacks.frameStateChangeCallback = { [weak self] frame, newState in
            guard let self else { return }            
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.frames[frame.frameIndex].frameState = newState

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
        var total = 0
        for (state, frameSet) in frameStateMap {
            switch state {
            case .unprocessed:
                break
            case .complete:
                break
            default:
                total += frameSet.count
            }
        }
        return total
    }

    var windowTitle: String {
        let sequenceDirname = self.config.config().imageSequenceDirname
        return "Star - \(sequenceDirname)"
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
    var frameViewMode = FrameViewMode.final {
        didSet {
            previousFrameViewMode = oldValue
        }
    }


    fileprivate var videoPlaybackTask: Task<Void,Never>?
    
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

    var goodStarAlignmentInfo: [[AlignmentWarpInfoCodable]] {
        var ret: [[AlignmentWarpInfoCodable]] = []

        for frame in frames {
            if let results = frame.frameObserver.starAlignmentResults {
                ret.append(results.numberAligned)
            } else {
                ret.append([])
            }
        }
        return ret
    }

    var badStarAlignmentInfo: [[AlignmentWarpInfoCodable]] {
        var ret: [[AlignmentWarpInfoCodable]] = []

        for frame in frames {
            if let results = frame.frameObserver.starAlignmentResults {
                ret.append(results.numberFailed)
            } else {
                ret.append([])
            }
        }
        return ret
    }

    var goodEarthAlignmentInfo: [[AlignmentWarpInfoCodable]] {
        var ret: [[AlignmentWarpInfoCodable]] = []

        for frame in frames {
            if let results = frame.frameObserver.earthAlignmentResults {
                ret.append(results.numberAligned)
            } else {
                ret.append([])
            }
        }
        return ret
    }
    
    var badEarthAlignmentInfo: [[AlignmentWarpInfoCodable]] {
        var ret: [[AlignmentWarpInfoCodable]] = []

        for frame in frames {
            if let results = frame.frameObserver.earthAlignmentResults {
                ret.append(results.numberFailed)
            } else {
                ret.append([])
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

    func processAll() {
        Task {
            Log.d("processAll")
            if self.horizonDetectionEnabled {
                Log.d("processAll horizonDetectionEnabled")
                do {
                    try await self.processHorizonForAllFrames()
                    Log.d("processAll got horizons")
                    // after we get horizons for all frames, render frames
                    self.renderAllFrames()
                    if self.runSecondAlignmentPass {
                        // get expected deviations
                        // re-run render all fames with it
                        // XXX Set some flag for UI
                        Log.i("running second alignment pass")
                        if let firstFrame = frames[0].frame {
                            self.renderAllFrames(
                              reRenderWith: await firstFrame.medianDeviationsForEntireSequence
                            )
                        } else {
                            Log.w("no first frame :(")
                        }
                    }
                    Log.d("processAll rendered all frames")
                } catch {
                    Log.e("ERROR: \(error)")
                }
            } else {
                Log.d("processAll NO horizonDetection")
                self.ignoreLowerPixels = 0
                self.renderAllFrames()
                if self.runSecondAlignmentPass {
                    // get expected deviation
                    // re-run render all fames with it
                    Log.i("running second alignment pass")
                    if let firstFrame = frames[0].frame {
                        self.renderAllFrames(
                          reRenderWith: await firstFrame.medianDeviationsForEntireSequence
                        )
                    }
                }
            }
        }
    }
    
    func refresh(frame: FrameAirplaneRemover) async {
        //        Log.d("refreshing frame \(frame.frameIndex)")
        
        // load the view frames from the main image
        
        // look for saved versions of these

        // let outlierTask: Task<Void,Never>?

        let acc = frame.imageAccessor

        let prTask = Task.detached {
            await acc.loadImage(frameIndex: frame.frameIndex,
                                type: .final,
                                atSize: .preview)?.resizable()
        }
        let opTask = Task.detached {
            await acc.loadImage(frameIndex: frame.frameIndex,
                                type: .original,
                                atSize: .preview)?.resizable()
        }

        let otTask = Task.detached {
            await acc.loadImage(frameIndex: frame.frameIndex,
                                type: .original,
                                atSize: .thumbnail)
        }
        // set list of view modes for this frame

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

        if let image = await prTask.value {
            self.frames[frame.frameIndex].processedPreviewImage = image
        }
        if let image = await opTask.value {
            self.frames[frame.frameIndex].originalPreviewImage = image
        }

        if let image = await otTask.value {
            self.frames[frame.frameIndex].thumbnailImage = image
        }
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
        if currentIndex < frames.count - 1 {
            currentIndex += 1
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
        if currentIndex > 0 {
            currentIndex -= 1
        } else {
            currentIndex = 0
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

    func processFrames(from startIndex: Int? = nil, to endIndex: Int? = nil) {
        Log.d("processing frames from \(startIndex) to \(endIndex)")
        //if isProcessingFrames { return }
        isProcessingFrames = true

        Log.d("processAllFrames start from \(startIndex) to \(endIndex)")
        
        Task.detached(priority: .medium) { [self] in
            // XXX a crude version of the FinalProcessor, could be better
            Log.d("processAllFrames 1")

            await finalProcessor?.processFrames(
              from: startIndex,
              to: endIndex,
              usingExistingHomography: self.useExistingHomography
            )

            await MainActor.run {
                self.isProcessingFrames = false
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
                
                await frame.applyDecisionTreeToAllOutliers(includingTrash: self.shouldShowTrash)
                
                try await self.render(frame: frame, now: true) {
                    Task {
                        await frameView.setOutlierGroups()
                    }
                }
            } catch {
                Log.e("error finding outliers for frame \(frame.frameIndex): \(error)")

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
        
        var newIndex = self.currentIndex + numberOfFrames
        if newIndex < 0 { newIndex = 0 }
        if newIndex >= self.frames.count {
            newIndex = self.frames.count-1
        }
        self.currentIndex = newIndex
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
                        self.self.currentIndex = nextVideoFrame
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

        self.interactionMode = self.previousInteractionMode
        
        self.videoPlaying = false
        self.backgroundColor = ViewModel.defaultBackgroundColor
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
    
    func renderAllFrames(
      reRenderWith medianDeviations: ([Int: Double])? = nil
    ) {
        Log.d("renderAllFrames")
        self.renderingAllFrames = true
        let frameSaveQueue = self.frameSaveQueue
        Task {
            Log.d("renderAllFrames Task")
            let semaphore = AsyncSemaphore(value: self.numberOfFramesToProcessConcurrently)
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                Log.d("renderAllFrames TaskGroup")

                let counter = CountActor()
                for frameView in self.frames {
                    if let frame = frameView.frame {

                        var shouldRender = await frame.processingState() != .complete
                        var renderWasBad = false
                        
                        if let medianDeviations {
                            /*
                             check to see if we should re-render based upon
                             how bad the homography was for this frame based upon
                             what medianDeviations may have been passed in
                             
                             */

                            // get frame homography
                            if let observer = await frame.getObserver(),
                               let results = observer.starAlignmentResults
                            {
                                // compare homography to median deviations
                                if !results.matches(
                                     deviations: medianDeviations,
                                     by: 1.25,
                                     at: frame.frameIndex
                                   )
                                {
                                    Log.i("frame \(frame.frameIndex) doesn't match median deviation so it will re-render")
                                    shouldRender = true
                                    renderWasBad = true

                                    frame.imageAccessor.deleteImages(
                                      frameIndex: frame.frameIndex,
                                      ofTypes: [.starAligned,
                                                .failedStarAligned,
                                                .earthAligned,
                                                .failedEarthAligned],
                                      atSizes: [.original, .preview]
                                    )
                                } else {
                                    Log.i("frame \(frame.frameIndex) matchs median deviation so keeping alignment")

                                }
                            } else {
                                Log.i("frame \(frame.frameIndex) has no frame homography, will re-render")
                                shouldRender = true
                                renderWasBad = true
                                frame.imageAccessor.deleteImages(
                                  frameIndex: frame.frameIndex,
                                  ofTypes: [.starAligned,
                                            .failedStarAligned,
                                            .earthAligned,
                                            .failedEarthAligned],
                                  atSizes: [.original, .preview]
                                )
                            }
                            Log.i("frame \(frame.frameIndex) WTF shouldRender \(shouldRender)")
                        } else {
                            Log.d("no median deviations")
                        }
                        if shouldRender {
                            Log.d("frame \(frame.frameIndex) rendering")
                            taskGroup.addTask() {
                                Log.d("frame \(frame.frameIndex) rendering pre semaphore")
                                await semaphore.wait()
                                Log.d("frame \(frame.frameIndex) rendering post semaphor")
                                await counter.increase()

                                switch await frame.cleanMethod {
                                case .selective:
                                    try await frameSaveQueue.saveNow(frame: frame) {
                                        await self.refresh(frame: frame)

                                        await counter.decrease()
                                        if !(await counter.isMoreThanZero()) {
                                            await MainActor.run {
                                                self.renderingAllFrames = false
                                            }
                                        }
                                        semaphore.signal()
                                    }

                                case .automatic(let useOutliers):
                                    try await frame.finishAuto(
                                      useOutliers: useOutliers,
                                      usingExistingHomography: self.useExistingHomography || renderWasBad
                                    )

                                    if useOutliers {
                                        if await frame.getOutlierGroups() == nil {
                                            try await frame.loadOutliers()
                                            Task { @MainActor in
                                                let frameView = self.frames[frame.frameIndex]
                                                frameView.outlierViews = nil
                                                await frameView.setOutlierGroups()
                                            }
                                        }
                                    }
                                    
                                    await self.refresh(frame: frame)
                                    await counter.decrease()
                                    if !(await counter.isMoreThanZero()) {
                                        await MainActor.run {
                                            self.renderingAllFrames = false
                                        }
                                    }
                                    semaphore.signal()
                                }
                            }
                        } else {
                            Log.d("frame \(frame.frameIndex) not re-rendering")
                        }
                    } else {
                        Log.d("renderAllFrames FOO")
                    }
                }
                
                try await taskGroup.waitForAll()
            }
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
        
        /*videoRenderTask = */Task.detached {
            do {
                try runFFmpegWithProgress(
                  arguments: [ "-y",                  // overwrite
                    "-framerate", rawFrameRate,       // frame rate
                    "-pattern_type", "glob", "-i",    // input image glob
                    "\(outputPath)/\(basename)/*.\(realConfig.fileExtension)", // input images
                    "-c:v", encoder.rawValue,         // encoder
                    "-pix_fmt", pixelFormat.rawValue, // pixel format
                    "-f", muxer.rawValue,             // muxer
                    "\(outputPath)/\(filename)"       // output filename
                  ],
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

    func processHorizonForAllFrames(redo: Bool = false) async throws {
        if isFindingAllHorizons { return }
        isFindingAllHorizons = true

        let max = self.maxConcurrentHorizonCalculations

        Log.d("finding all horizons with max \(max)")
        
        try await Task.detached(priority: .medium) { [self] in 

            // use a semaphore to not do too many at once

            let semaphore = AsyncSemaphore(value: max)
            
            let allBounds =
              try await withThrowingTaskGroup(of: Optional<HorizonBounds>.self) { taskGroup in

                  for frameViewModel in await self.frames {
                      Log.d("frame \(frameViewModel.frameIndex) about to create task for horizon")
                      taskGroup.addTask {
                          Log.d("frame \(frameViewModel.frameIndex) in task for horizon waiting for semaphore")
                          await semaphore.wait()
                          Log.d("frame \(frameViewModel.frameIndex) in task for horizon got semaphore")
                          if let frame = await frameViewModel.frame {
                              if redo {
                                  // get rid of all the existing horizon images first
                                  await frame.deleteHorizonImages()
                              }
                              let ret = try await frame.loadOrCreateHorizonMask().bounds
                              semaphore.signal()
                              return ret
                          } else {
                              Log.d("frame \(frameViewModel.frameIndex) in task for horizon no frame")
                              semaphore.signal()
                              return nil
                          }
                      }
                  }

                  var results: [HorizonBounds] = []
                  
                  for try await result in taskGroup {
                      if let result { results.append(result) }
                  }
                  
                  return results
              }

          if let horizonStats = allBounds.calculateStats() {
            Log.i("got horizon stats \(horizonStats)")
            
            
            await MainActor.run {
              // save the height of the portion of the frames that is sky
              // account for 50 extra pixels of sky on top of the highest part
              //self.earthAlignedImageCropAmount = horizonStats.highestTopY - 50
              
              //self.showHorizonBar = false
                //self.ignoreLowerPixels = frameHeight - CGFloat(horizonStats.lowestBottomY)
              Log.i("ignoreLowerPixels \(ignoreLowerPixels) = \(frameHeight) - \(horizonStats.lowestBottomY)")
              //var realConfig = config.config()
              //realConfig.ignoreLowerPixels = Int(ignoreLowerPixels)
              //config.update(realConfig)
            }
          }
            await MainActor.run {
                self.isFindingAllHorizons = false
            }
        }.value

        Log.d("done all horizons with max \(max)")

        
        /*
         * set a boolean saying we are processing horizon for all frames
         * disbable left panel buttons until that is done
         * actually process them all
         * change FrameAirplaneRemover to not load horizon unless it really needs it
         * add number of horizon images to process at once to this view
         * set showHorizonBar = true after getting the right value for it
         * make sure we show that action is happening in the GUI somewhere
         */
    }
}

public actor CountActor {
    private var value: Int = 0

    public func increase() { value += 1 }
    public func decrease() { value -= 1 }
    
    public func isMore(than: Int) -> Bool { value > than }
    public func isMoreThanZero() -> Bool { value > 0 }
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
