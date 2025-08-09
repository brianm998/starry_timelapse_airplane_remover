import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable
import Semaphore
import logging

public enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
}

// XXX rename this to ToolType
public enum SelectionMode: String, Equatable, CaseIterable {
    case remove
    case keep
    case razor
    case shovel
    case trash
    case removeFromTrash
    case multi
    case information
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
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
    var config: ConfigManager?

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
            if let pixelFormat = userPreferences.pixelFormat {
                self.pixelFormat = pixelFormat
            }
            if let muxer = userPreferences.muxer {
                self.muxer = muxer
            }

        }
    }

    // use these if nothing is in the config
    var frameRate: FrameRate = .fps_24
    var codec: FFmpegCodec = .prores
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

    var selectionMode = SelectionMode.remove {
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
    
    var showIgnoreLowerBar = false
    
    var ignoreLowerPixels: CGFloat = 0

    var outlierOpacity = 1.0

    var trashOpacity = 0.7

    var interactionMode: InteractionMode = .scrub

    var previousInteractionMode: InteractionMode = .scrub

    var previousFrameViewMode = FrameViewMode.processed

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

    var showProcessingOptionsSheet = false

    var showAllFrameViewModes = false

    var showAllFrameProcessingStates = false

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
    var currentIndex = 0

    var numberOfFramesToProcessConcurrently: Int

    var numberOfNeighborFrames: Int
    var numberOfAlignedNeighborFrames: Int

    // the threshold used by used in goodPixels(thresholdFactor: )
    var pixelThreshold: Double = 1.2
    
    // number of frames in the sequence we're processing
    var imageSequenceSize: Int = 0

    var finalProcessor: FinalGUIProcessor?

    var shouldShowInitialInstructions: Bool = false

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

    var reprocessFrames = false
    
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

        var config = Config(outputPath: inputImageSequencePath,
                            imageSequenceName: inputImageSequenceName,
                            imageSequencePath: inputImageSequencePath,
                            writeOutlierGroupFiles: shouldWriteOutlierGroupFiles,
                            writeFramePreviewFiles: shouldWriteOutlierGroupFiles,
                            writeFrameProcessedPreviewFiles: shouldWriteOutlierGroupFiles,
                            writeFrameThumbnailFiles: shouldWriteOutlierGroupFiles)

        if let videoInfo {
            config.set(videoInfo: videoInfo)
        }
        
        config.ignoreLowerPixels = 200
        
        let configFilename = "\(config.basename)-config.json"
        
        let configManager = ConfigManager(configFilename: configFilename, config: config)

        try await self.init(with: configManager, closure: closure)

        if config.writeOutlierGroupFiles {
            mkdir(config.outlierOutputDirname)
        }
        self.interactionMode = .edit
        self.shouldShowInitialInstructions = true
        self.showIgnoreLowerBar = true
        self.frameViewMode = .original
        if let videoInfo {
            self.frameRate = videoInfo.frameRate
            self.codec = videoInfo.codec
            self.pixelFormat = videoInfo.pixelFormat
            self.muxer = videoInfo.muxer
            self.hasAudio = videoInfo.hasAudio
        }
        
    }

    init(with configManager: ConfigManager, closure: @Sendable @escaping (Int, Double, Int, Double) -> Void) async throws {

        self.trashLevel = await constants.getTrashLevel()
        self.smallTrashMax = await constants.getSmallTrashMax()

        let config = configManager.config()

        self.config = configManager
        
        self.numberOfAlignedNeighborFrames = config.numberAlignedNeighborFrames

        self.numberOfNeighborFrames = config.numberFinalProcessingNeighborsNeeded
        
        self.numberOfFramesToProcessConcurrently = await Task { await maxFramesProcessing.getValue() }.value
        
        if let ignoreLowerPixels = config.ignoreLowerPixels {
            self.ignoreLowerPixels = CGFloat(ignoreLowerPixels) // XXX need to sync back the other dir
        }
            
        Log.d("loaded config \(config.imageSequenceDirname)")
        
        let imageSequence = try ImageSequence(dirname: "\(config.imageSequencePath)/\(config.imageSequenceDirname)",
                                              supportedImageFileTypes: config.supportedImageFileTypes)

        self.frameSaveQueue.viewModel = self
        
        Log.d("loaded image sequence")
        let callbacks = self.makeCallbacks()
        
        let imageSequenceSize = await imageSequence.filenames.count
        
        if let imageSequenceSizeClosure = callbacks.imageSequenceSizeClosure {
            imageSequenceSizeClosure(imageSequenceSize)
        }
        
        let imageInfo = try await imageSequence.getImageInfo()

        IMAGE_WIDTH = Double(imageInfo.imageWidth)
        IMAGE_HEIGHT = Double(imageInfo.imageHeight)
        
        Log.d("loaded imageInfo \(imageInfo)")

        let filenames = await imageSequence.filenames

        var frameIndexToBaseNameMap: [Int: String] = [:]
        
        for (frameIndex, filename) in filenames.enumerated() {
            frameIndexToBaseNameMap[frameIndex] = removePath(fromString: filename)
        }

        // make image accessor here now
        // the image accessor always has the orignal config
        let imageAccessor = ImageAccessor(config: configManager.config(),
                                          imageSequence: imageSequence,
                                          frameIndexToBaseNameMap: frameIndexToBaseNameMap) { [weak self] frameIndex, image, type, size in
            Task { @MainActor in 
                self?.frames[frameIndex].savedImage(image, ofType: type, atSize: size)
            }
        }

        Log.d("make missing previews")

        self.finalProcessor = FinalGUIProcessor(self)
        
        var numberPreviewsSaved = 0
        try await imageAccessor.writeMissingImages() { numberSaved in
            Task { @MainActor in
                numberPreviewsSaved += 1
                let amountPreviewsSaved = Double(numberPreviewsSaved)/Double(imageSequenceSize)
                closure(numberPreviewsSaved, amountPreviewsSaved, 0, 0)
            }
                
        }
        Log.d("done with make missing previews")
//        Log.d("make missing thumbnails")
//        try await imageAccessor.writeMissingImages(atSize: .thumbnail)
//        Log.d("done make missing thumbnails")

        try await withThrowingTaskGroup(of: FrameAirplaneRemover.self) { taskGroup in
            
            for (frameIndex, filename) in filenames.enumerated() {

                Log.d("add task at frameIndex \(frameIndex)")

                taskGroup.addTask() {
                    let basename = removePath(fromString: filename)
                    let frame = try await frameLoadMonitor.load() {
                        try await FrameAirplaneRemover(with: configManager,
                                                       width: imageInfo.imageWidth,
                                                       height: imageInfo.imageHeight,
                                                       bytesPerPixel: imageInfo.imageBytesPerPixel,
                                                       callbacks: callbacks,
                                                       imageSequence: imageSequence,
                                                       atIndex: frameIndex,
                                                       outputFilename: "\(config.outputPath)/\(config.basename)",
                                                       baseName: basename,
                                                       fullyProcess: false,
                                                       writeOutputFiles: true,
                                                       imageAccessor: imageAccessor)
                    }
                    if let callback = callbacks.frameCheckClosure { 
                        await MainActor.run {
                            callback(frame)
                        }
                    }
                    return frame
                }
            }

            var incomingFrames = await [FrameAirplaneRemover?](repeating: nil, count: imageSequence.filenames.count)

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
    }

    func makeCallbacks() -> Callbacks {
        var callbacks = Callbacks()

        // get the full number of images in the sequcne
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
        if let sequenceDirname = self.config?.config().imageSequenceDirname {
            return "Star - \(sequenceDirname)"
        } else {
            return "Star"
        }
    }
    
    var selectionColor: Color {
        switch self.selectionMode {
        case .remove:
            return .red
        case .keep:
            return .green
        case .shovel:
            return .gray
        case .razor:
            return .yellow
        case .trash:
            return .pink
        case .removeFromTrash:
            return .mint
        case .information:
            return .blue
        case .multi:
            return .purple      // XXX ???
        }
    }

    // enum for how we show each frame
    var frameViewMode = FrameViewMode.processed {
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
            i in FrameViewModel(i)
        }
    }
    
    func refresh(frame: FrameAirplaneRemover) async {
        Log.d("refreshing frame \(frame.frameIndex)")
        
        // load the view frames from the main image
        
        // look for saved versions of these

        // let outlierTask: Task<Void,Never>?

        let acc = frame.imageAccessor

        let prTask = Task.detached {
            await acc.loadImage(frameIndex: frame.frameIndex,
                                type: .processed,
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

        if self.frames[frame.frameIndex].existingImages.count == 0 {
            var existingImages: Set<FrameViewMode> = []
            for type in FrameViewMode.allCases {
                if acc.imageExists(frameIndex: frame.frameIndex,
                                   ofType: type,
                                   atSize: .preview)
                {
                    existingImages.insert(type)
                }
            }

            self.frames[frame.frameIndex].existingImages = existingImages
        }

        if let image = await prTask.value {
            self.frames[frame.frameIndex].processedPreviewImage = image
        }
        if let image = await opTask.value {
            self.frames[frame.frameIndex].previewImage = image
        }
        if let image = await otTask.value {
            self.frames[frame.frameIndex].thumbnailImage = image
        }

        Log.d("done refreshing frame \(frame.frameIndex)")
        //if let outlierTask { await outlierTask.value }
    }

  func append(frame: FrameAirplaneRemover) async {
        Log.d("appending frame \(frame.frameIndex)")

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

            await finalProcessor?.processFrames(from: startIndex, to: endIndex)

            await MainActor.run {
                self.isProcessingFrames = false
            }
        }
    }

    func clearProcessing(from startIndex: Int, to endIndex: Int) async throws {
        Log.d("clearing processing from \(startIndex) to \(endIndex)")
        for index in startIndex...endIndex {
            if let frame = frames[index].frame {
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

            // this doesn't delete the alignment and subtraction images
            frameToClear.imageAccessor.deleteAllImages(frameIndex: frameToClear.frameIndex)

            let numberOfAlignedImages = await self.numberOfNeighborFrames
            
            await frameToClear.setNumberOfAlignmentImages(numberOfAlignedImages)

            let numPrevAlignedImages = await frameToClear.readNumberOfAlignedImagesForThisFrame()
            if numberOfAlignedImages != numPrevAlignedImages {
                // this does delete the alignment and subtraction images, because the next
                // run should use a different number of alignment images
                await frameToClear.removeStarAlignedImages()
                try await frameToClear.removeNumberOfAlignedImagesForThisFrameFile()
            }
            
            Task { @MainActor in
                self.frameViewMode = .original
            }

            var existingImages: Set<FrameViewMode> = [.original]
            
            if frameToClear.imageAccessor.imageExists(frameIndex: frameToClear.frameIndex,
                                                      ofType: .aligned,
                                                      atSize: .original)
            {
                existingImages.insert(.aligned)
            }

            if frameToClear.imageAccessor.imageExists(frameIndex: frameToClear.frameIndex,
                                                      ofType: .subtraction,
                                                      atSize: .original)
            {
                existingImages.insert(.subtraction)
            }

            Task { @MainActor in
                self.currentFrameView.existingImages = existingImages
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
                closure: (@Sendable () async -> Void)? = nil) async throws
    {
        if saveNow {
            try await self.frameSaveQueue.saveNow(frame: frame) {
                await closure?()
            }
        } else {
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

    func renderAllFrames() {
        //  let foobar = viewModel
        self.renderingAllFrames = true
        let frameSaveQueue = self.frameSaveQueue
        Task {
            try await withThrowingTaskGroup(of: Void.self) { taskGroup in
                //                await withLimitedTaskGroup(of: Void.self) { taskGroup in
                /// does this break things when saving thousands of frames at once?

                let counter = CountActor()
                for frameView in self.frames {
                    if let frame = frameView.frame {
                        if await frame.processingState() == .userModified {
                            taskGroup.addTask() {
                                await counter.increase()
                                try await frameSaveQueue.saveNow(frame: frame) {
                                    await self.refresh(frame: frame)
                                    /*
                                     if frame.frameIndex == self.currentIndex {
                                     refreshCurrentFrame()
                                     }
                                     */
                                    await counter.decrease()
                                    if !(await counter.isMoreThanZero()) {
                                        await MainActor.run {
                                            self.renderingAllFrames = false
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                
                try await taskGroup.waitForAll()
            }
        }
    }
    
    //private var videoRenderTask: Task<Void>? = nil
    
    func renderVideo(named filename: String,
                     frameRate: FrameRate,
                     codec: FFmpegCodec,
                     pixelFormat: FFmpegPixelFormat,
                     muxer: FFmpegMuxer,
                     progress: @escaping ProgressCallback,
                     completion: @escaping @Sendable () -> Void,
                     errorCallback: @escaping @Sendable (Error) -> Void)
    {
        let totalNumberOfFrames = self.frames.count
        let rawFrameRate = frameRate.rawString
        guard let config else {
            errorCallback("No Config!")
            return
        }
        let outputPath = config.config().outputPath
        let basename = config.config().basename

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
                    "\(outputPath)/\(basename)/*.tiff", // input images
                    "-c:v", codec.rawValue,           // codec
                    "-pix_fmt", pixelFormat.rawValue, // pixel format
                    "-f", muxer.rawValue,             // muxer
                    "\(outputPath)/\(filename)"       // output filename
                  ],
                  totalFrames: totalNumberOfFrames,
                  progress: progress)
                completion()
            } catch {
                Log.e("video encoding error: \(error)")
                errorCallback(error)
            }
        }
    }
}

public actor CountActor {
    private var value: Int = 0

    public func increase() { value += 1 }
    public func decrease() { value -= 1 }
    
    public func isMore(than: Int) -> Bool { value > than }
    public func isMoreThanZero() -> Bool { value > 0 }
}


