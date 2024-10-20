import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable
import logging

public enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
}

public enum SelectionMode: String, Equatable, CaseIterable {
    case paint
    case clear
    case delete
    case multi
    case details
    
    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

public enum InteractionMode: String, Equatable, CaseIterable {
    case edit
    case scrub

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

// the overall view model
@MainActor @Observable
public final class ViewModel {
    var config: Config?
    var eraser: NighttimeAirplaneRemover?
    var noImageExplainationText: String = "Loading..."

    var userPreferences: UserPreferences = UserPreferences()

    init() {
        Task {
            if let newPrefs = await UserPreferences.initialize() {
                await MainActor.run {
                    userPreferences = newPrefs
                }
            }
            frameSaveQueue.sizeUpdated() { newSize in
                await MainActor.run {
                    self.frameSaveQueueSize = newSize
                }
            }
        }
    }
    
//    @Environment(\.openWindow) private var openWindow

    var frameSaveQueueSize: Int = 0
    
    var frameSaveQueue = FrameSaveQueue()

    var videoPlayMode: VideoPlayMode = .forward
    
    var videoPlaying = false

    var fastAdvancementType: FastAdvancementType = .normal

    // if fastAdvancementType == .normal, fast forward and reverse do a set number of frames
    var fastSkipAmount = 20
    
    var sequenceLoaded = false
    
    var frameWidth: CGFloat = 600 // placeholders until first frame is read
    var frameHeight: CGFloat = 450

    // how long the arrows are
    var outlierArrowLength: CGFloat = 70 // relative to the frame width above

    // how high they are (if pointing sideways)
    var outlierArrowHeight: CGFloat = 180
    
    var showErrorAlert = false
    var errorMessage: String = ""
    
    var labelText: String = "Started"

    // view class for each frame in the sequence in order
    var frames: [FrameViewModel] = [FrameViewModel(0)]

    // the view mode that we set this image with

    var initialLoadInProgress = false
    var loadingAllOutliers = false
    var loadingOutliers = false
    
    var numberOfFramesWithOutliersLoaded = 0
    
    var numberOfFramesLoaded = 0

    var outlierGroupTableRows: [OutlierGroupTableRow] = []
    var outlierGroupWindowFrame: FrameAirplaneRemover?

    var selectedOutliers = Set<OutlierGroupTableRow.ID>()

    var selectionMode = SelectionMode.paint
    var renderingCurrentFrame = false

    var selectionColor: Color {
        switch self.selectionMode {
        case .paint:
            return .red
        case .clear:
            return .green
        case .delete:
            return .orange
        case .details:
            return .blue
        case .multi:
            return .purple      // XXX ???
        }
    }

    var outlierOpacity = 1.0

    var interactionMode: InteractionMode = .scrub

    var previousInteractionMode: InteractionMode = .scrub

    // enum for how we show each frame
    var frameViewMode = FrameViewMode.processed

    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    var showFullResolution = false

    var showFilmstrip = true

    // causes tapping an outlier to open a dialog with multiple choices
    var multiChoice = false

    var backgroundColor: Color = .gray

    var renderingAllFrames = false
    var updatingFrameBatch = false

    var videoPlaybackFramerate = 30

    var settingsSheetShowing = false
    var paintSheetShowing = false

    var multiSelectSheetShowing = false

    var multiSelectionType: MultiSelectionType = .all
    var multiSelectionPaintType: MultiSelectionPaintType = .clear

    var multiChoiceSheetShowing = false
    var multiChoicePaintType: MultiChoicePaintType = .clear
    var multiChoiceType: MultiSelectionType = .all

    // the outlier grop we're starting a multi choice from
    var multiChoiceOutlierView: OutlierGroupView?
    
    var selectionStart: CGPoint? 
    var selectionEnd: CGPoint?
    
    var number_of_frames: Int = 50
    
    // the frame number of the frame we're currently showing
    var currentIndex = 0

    // number of frames in the sequence we're processing
    var imageSequenceSize: Int = 0

    var inTransition = false

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

    // XX set this up to use combine
    var numberOfFramesChanged: Int {
        0                       // XXX is this used anymore
    }

    /*
    var OLD_numberOfFramesChanged: Int {
        var ret = frameSaveQueue?.purgatory.count ?? 0
        if let currentFrame = self.currentFrame,
           currentFrame.hasChanges(),
           !(frameSaveQueue?.frameIsInPurgatory(currentFrame.frameIndex) ?? false)
        {
            ret += 1            // XXX make sure the current frame isn't in purgatory
        }
        return ret
    }*/
    
    var loadingOutlierGroups: Bool {
        for frame in frames { if frame.loadingOutlierViews { return true } }
        return false
    }
    
    var eraserTask: Task<(),Never>?
    
    func set(numberOfFrames: Int) {
//        Task.detached {
//            await MainActor.run {
              self.frames = [FrameViewModel](count: numberOfFrames) { i in FrameViewModel(i) }
//            }
//        }
    }
    
    func refresh(frame: FrameAirplaneRemover) {
        Task {
            Log.d("refreshing frame \(frame.frameIndex)")
            
            // load the view frames from the main image
            
            // look for saved versions of these

            var outlierTask: Task<Void,Never>?

            if self.frames[frame.frameIndex].outlierViews == nil {
                outlierTask = Task { await self.setOutlierGroups(forFrame: frame) }
            }
            
            let acc = frame.imageAccessor

            let vpTask = Task.detached { await acc.loadImage(type: .validated,  atSize: .preview)?.resizable() }
            let spTask = Task.detached { await acc.loadImage(type: .subtracted, atSize: .preview)?.resizable() }
            let bpTask = Task.detached { await acc.loadImage(type: .blobs,      atSize: .preview)?.resizable() }
            let f1Task = Task.detached { await acc.loadImage(type: .filter1,    atSize: .preview)?.resizable() }
            let f2Task = Task.detached { await acc.loadImage(type: .filter2,    atSize: .preview)?.resizable() }
            let f3Task = Task.detached { await acc.loadImage(type: .filter3,    atSize: .preview)?.resizable() }
            let f4Task = Task.detached { await acc.loadImage(type: .filter4,    atSize: .preview)?.resizable() }
            let f5Task = Task.detached { await acc.loadImage(type: .filter5,    atSize: .preview)?.resizable() }
            let f6Task = Task.detached { await acc.loadImage(type: .filter6,    atSize: .preview)?.resizable() }
            let ppTask = Task.detached { await acc.loadImage(type: .paintMask,  atSize: .preview)?.resizable() }
            let prTask = Task.detached { await acc.loadImage(type: .processed,  atSize: .preview)?.resizable() }
            let opTask = Task.detached { await acc.loadImage(type: .original,   atSize: .preview)?.resizable() }
            let otTask = Task.detached { await acc.loadImage(type: .original,   atSize: .thumbnail) }

            if let image = await vpTask.value {
                self.frames[frame.frameIndex].validationPreviewImage = image
            }
            if let image = await spTask.value  {
                self.frames[frame.frameIndex].subtractionPreviewImage = image
            }
            if let image = await bpTask.value {
                self.frames[frame.frameIndex].blobsPreviewImage = image
            }
            if let image = await f1Task.value {
                self.frames[frame.frameIndex].filter1PreviewImage = image
            }
            if let image = await f2Task.value {
                self.frames[frame.frameIndex].filter2PreviewImage = image
            }
            if let image = await f3Task.value {
                self.frames[frame.frameIndex].filter3PreviewImage = image
            }
            if let image = await f4Task.value {
                self.frames[frame.frameIndex].filter4PreviewImage = image
            }
            if let image = await f5Task.value {
                self.frames[frame.frameIndex].filter5PreviewImage = image
            }
            if let image = await f6Task.value {
                self.frames[frame.frameIndex].filter6PreviewImage = image
            }
            if let image = await ppTask.value {
                self.frames[frame.frameIndex].paintMaskPreviewImage = image
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

            if let outlierTask { await outlierTask.value }

            // refresh if this is the current index
         //   if frame.frameIndex == self.currentIndex {
         //        self.objectWillChange.send()
         //   }
        }
    }

    func append(frame: FrameAirplaneRemover) {
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
        Log.d("set self.frames[\(frame.frameIndex)].frame")

        refresh(frame: frame)
    }

    func setOutlierGroups(forFrame frame: FrameAirplaneRemover) async {
        Task.detached(priority: .userInitiated) {
          let outlierGroups = await frame.outlierGroupList()
            if let outlierGroups = outlierGroups {
                Log.d("got \(outlierGroups.count) groups for frame \(frame.frameIndex)")
                var newOutlierGroups: [OutlierGroupViewModel] = []
                for group in outlierGroups {
                    if let cgImage = await group.testImage() { // XXX heap corruption here :(
                        var size = CGSize()
                        size.width = CGFloat(cgImage.width)
                        size.height = CGFloat(cgImage.height)
                        let outlierImage = NSImage(cgImage: cgImage, size: size)
                        
                        let groupView = await OutlierGroupViewModel(viewModel: self,
                                                                    group: group,
                                                                    name: group.id,
                                                                    bounds: group.bounds,
                                                                    image: outlierImage)
                        newOutlierGroups.append(groupView)
                    } else {
                        Log.e("frame \(frame.frameIndex) outlier group no image")
                    }
                }
                
                let foo = newOutlierGroups
                await MainActor.run {
                    self.frames[frame.frameIndex].outlierViews = foo
                   // self.objectWillChange.send()
                }
            }
        }
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

    // prepare for another sequence
    func unloadSequence() {
        if let eraserTask = eraserTask {
            eraserTask.cancel()
            self.eraserTask = nil
        }
        self.sequenceLoaded = false
        self.frames = [FrameViewModel(0)]
        self.initialLoadInProgress = false
        self.loadingAllOutliers = false
        self.numberOfFramesWithOutliersLoaded = 0
        self.numberOfFramesLoaded = 0
        self.outlierGroupTableRows = []
        self.outlierGroupWindowFrame = nil
        self.selectedOutliers = Set<OutlierGroupTableRow.ID>()
        self.currentIndex = 0
        self.imageSequenceSize = 0
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

    func startup(withConfig jsonConfigFilename: String) async throws {
        Log.d("outlier_json_startup with \(jsonConfigFilename)")
        // first read config from json

        /*

         re-write this

         ditch the NighttimeAirplaneRemover, it's for the cli, slow as F for the gui

         instead, create the list of FrameAirplaneRemover for each frame without
         loading much at all.

         then call back into the UI with each frame

         can display processing state on the flimstrip

         if no previews are loaded, create them.
         
         allow individual frames to be processed by calling frame.finish()
         
         */

        Task {

            try await withThrowingTaskGroup(of: FrameAirplaneRemover.self) { taskGroup in

                self.userPreferences.justOpened(filename: jsonConfigFilename) // make sure this works
                
                let config = try await Config.read(fromJsonFilename: jsonConfigFilename)
                // overwrite global constants constant :( make this better
                constants = Constants(detectionType: config.detectionType)

                Log.d("loaded config \(config.imageSequenceDirname)")
                
                let imageSequence = try ImageSequence(dirname: "\(config.imageSequencePath)/\(config.imageSequenceDirname)",
                                                      supportedImageFileTypes: config.supportedImageFileTypes)

                
                Log.d("loaded image sequence")
                let callbacks = self.makeCallbacks()

                if let imageSequenceSizeClosure = callbacks.imageSequenceSizeClosure {
                    let imageSequenceSize = await imageSequence.filenames.count
                    imageSequenceSizeClosure(imageSequenceSize)
                }
                
                let imageInfo = try await imageSequence.getImageInfo()

                IMAGE_WIDTH = Double(imageInfo.imageWidth)
                IMAGE_HEIGHT = Double(imageInfo.imageHeight)
                
                Log.d("loaded imageInfo \(imageInfo)")

                await MainActor.run {
                    self.config = config
                }

                for (frameIndex, filename) in await imageSequence.filenames.enumerated() {
                    taskGroup.addTask() {
                        let basename = removePath(fromString: filename)
                        let frame = try await FrameAirplaneRemover(with: config,
                                                                   width: imageInfo.imageWidth,
                                                                   height: imageInfo.imageHeight,
                                                                   bytesPerPixel: imageInfo.imageBytesPerPixel,
                                                                   callbacks: callbacks,
                                                                   imageSequence: imageSequence,
                                                                   atIndex: frameIndex,
                                                                   outputFilename: "\(config.outputPath)/\(config.basename)",
                                                                   baseName: basename,
                                                                   outlierOutputDirname: config.outlierOutputDirname,
                                                                   fullyProcess: false,
                                                                   writeOutputFiles: true)
                        
                        if let callback = callbacks.frameCheckClosure {
                            await MainActor.run {
                                callback(frame)
                            }
                        }
                        return frame
                    }
                }

                var incomingFrames = await [FrameAirplaneRemover?](repeating: nil, count: imageSequence.filenames.count)
                for try await frame in taskGroup {
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
            }
        }
    }
    
    @MainActor func startup(withNewImageSequence imageSequenceDirname: String) async throws {

        /*

         rewrite this path too, starting without a config

         
         
         */
        
        let numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount
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

        let config = Config(outputPath: inputImageSequencePath,
                            imageSequenceName: inputImageSequenceName,
                            imageSequencePath: inputImageSequencePath,
                            writeOutlierGroupFiles: shouldWriteOutlierGroupFiles,
                            writeFramePreviewFiles: shouldWriteOutlierGroupFiles,
                            writeFrameProcessedPreviewFiles: shouldWriteOutlierGroupFiles,
                            writeFrameThumbnailFiles: shouldWriteOutlierGroupFiles)

        // overwrite global constants constant :( make this better
        constants = Constants(detectionType: config.detectionType)
        
        let callbacks = self.makeCallbacks()
        Log.i("have config")

        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                        callbacks: callbacks,
                                                        processExistingFiles: true,
                                                        isGUI: true)

        self.eraser = eraser // XXX rename this crap
        self.config = config
    }
    
    @MainActor func makeCallbacks() -> Callbacks {
        var callbacks = Callbacks()


        // get the full number of images in the sequcne
        callbacks.imageSequenceSizeClosure = { imageSequenceSize in
            Task { @MainActor in
                self.imageSequenceSize = imageSequenceSize
                Log.i("read imageSequenceSize \(imageSequenceSize)")
                self.set(numberOfFrames: imageSequenceSize)
            }
        }
        
        callbacks.frameStateChangeCallback = { frame, state in
            // XXX do something here
//            Log.d("frame \(frame.frameIndex) changed to state \(state)")
//            Task {
//                await MainActor.run {
//                    //self.frame_states[frame.frameIndex] = state
//                    self.objectWillChange.send()
//                }
//            }
        }

        // called when we should check a frame
        callbacks.frameCheckClosure = { newFrame in
            Log.d("frameCheckClosure for frame \(newFrame.frameIndex)")
            Task { @MainActor in
                self.addToViewModel(frame: newFrame)
            }
        }
        
        return callbacks
    }

    @MainActor func addToViewModel(frame newFrame: FrameAirplaneRemover) {
        Log.d("addToViewModel(frame: \(newFrame.frameIndex))")

        if self.config == nil {
            // XXX why this doesn't work initially befounds me,
            // but without doing this here there is no config present...
            //self.config = self.config
            Log.e("FUCK, config is nil")
        }
        if self.frameWidth != CGFloat(newFrame.width) ||
             self.frameHeight != CGFloat(newFrame.height)
        {
            // grab frame size from first frame
            self.frameWidth = CGFloat(newFrame.width)
            self.frameHeight = CGFloat(newFrame.height)
        }
        self.append(frame: newFrame)
        
        // Log.d("addToViewModel self.frame \(self.frame)")
    }
}

// methods used in image sequence view
public extension ViewModel {
    func setAllCurrentFrameOutliers(to shouldPaint: Bool,
                                    renderImmediately: Bool = true)
    {
        let currentFrameView = self.currentFrameView
        setAllFrameOutliers(in: currentFrameView,
                            to: shouldPaint,
                            renderImmediately: renderImmediately)
    }


    func setUndecidedFrameOutliers(to shouldPaint: Bool,
                                   renderImmediately: Bool = true)
    {
        let currentFrameView = self.currentFrameView
        setUndecidedFrameOutliers(in: currentFrameView,
                                  to: shouldPaint,
                                  renderImmediately: renderImmediately)
    }
    
    func setUndecidedFrameOutliers(in frameView: FrameViewModel,
                                   to shouldPaint: Bool,
                                   renderImmediately: Bool = true)
    {
        let reason = PaintReason.userSelected(shouldPaint)
        
        if let frame = frameView.frame {
            // update the real actor in the background
            Task {
                await frame.userSelectUndecidedOutliers(toShouldPaint: shouldPaint)

                if renderImmediately {
                    // XXX make render here an option in settings
                    await render(frame: frame) {
                        await MainActor.run {
                            self.refresh(frame: frame)
                        }
                    }
                }
            }
        } else {
            Log.w("frame \(frameView.frameIndex) has no frame")
        }
    }
    
    func setAllFrameOutliers(in frameView: FrameViewModel,
                             to shouldPaint: Bool,
                             renderImmediately: Bool = true)
    {
        Log.d("setAllFrameOutliers in frame \(frameView.frameIndex) to should paint \(shouldPaint)")
        let reason = PaintReason.userSelected(shouldPaint)

        if let frame = frameView.frame {
            // update the real actor in the background
            Task {
                await frame.userSelectAllOutliers(toShouldPaint: shouldPaint)

                if renderImmediately {
                    // XXX make render here an option in settings
                    await render(frame: frame) {
                        await MainActor.run {
                            self.refresh(frame: frame)
                        }
                    }
                }
            }
        } else {
            Log.w("frame \(frameView.frameIndex) has no frame")
        }
    }

    func render(frame: FrameAirplaneRemover, closure: (@Sendable () async -> Void)? = nil) async {
        self.renderingCurrentFrame = true // XXX might not be right anymore
        await self.frameSaveQueue.saveNow(frame: frame) {
            await MainActor.run {
                self.refresh(frame: frame)
                self.renderingCurrentFrame = false
                //                await MainActor.run {
                //                }
            }
            await closure?()
        }
    }

    // next frame entry point
    func transition(numberOfFrames: Int) {
        let currentFrame = self.currentFrame

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
        Task {
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
        self.backgroundColor = .gray
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

}


