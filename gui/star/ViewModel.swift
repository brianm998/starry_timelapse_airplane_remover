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

public enum FrameViewMode: String, Equatable, CaseIterable {
    case original
    case subtraction
    case blobs
//    case khtBlobs
    case absorbedBlobs
    case rectifiedBlobs
    case validation
    case paintMask
    case processed

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }

    var shortName: String {
        switch self {
        case .original:
            return "orig"
        case .subtraction:
            return "subt"
        case .blobs:
            return "blob"
        case .absorbedBlobs:
            return "asb"
        case .rectifiedBlobs:
            return "rect"
        case .paintMask:
            return "pmask"
        case .validation:
            return "valid"
        case .processed:
            return "proc"
        }
    }

    var longName: String {
        switch self {
        case .original:
            return "original frame"
        case .subtraction:
            return "subtracted frame"
        case .blobs:
            return "initially detected blobs"
        case .absorbedBlobs:
            return "blobs after the absorber"
        case .rectifiedBlobs:
            return "rectified blobs"
        case .paintMask:
            return "computed paint mask"
        case .validation:
            return "validation data"
        case .processed:
            return "processed frame"
        }
    }
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
    case play

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

// the overall view model
@MainActor
public final class ViewModel: ObservableObject {
    var config: Config?
    var eraser: NighttimeAirplaneRemover?
    var noImageExplainationText: String = "Loading..."

    @Environment(\.openWindow) private var openWindow

    @Published var frameSaveQueue: FrameSaveQueue?

    @Published var videoPlayMode: VideoPlayMode = .forward
    
    @Published var videoPlaying = false

    @Published var fastAdvancementType: FastAdvancementType = .normal

    // if fastAdvancementType == .normal, fast forward and reverse do a set number of frames
    @Published var fastSkipAmount = 20
    
    @Published var sequenceLoaded = false
    
    @Published var frameWidth: CGFloat = 600 // placeholders until first frame is read
    @Published var frameHeight: CGFloat = 450

    // how long the arrows are
    @Published var outlierArrowLength: CGFloat = 70 // relative to the frame width above

    // how high they are (if pointing sideways)
    @Published var outlierArrowHeight: CGFloat = 180
    
    @Published var showErrorAlert = false
    @Published var errorMessage: String = ""
    
    var labelText: String = "Started"

    // view class for each frame in the sequence in order
    @Published var frames: [FrameViewModel] = [FrameViewModel(0)]

    // the image we're showing to the user right now
    @Published var currentFrameImage: Image?

    // the frame index of the image that produced the currentFrameImage
    @Published var currentFrameImageIndex: Int = 0

    // the frame index of the image that produced the currentFrameImage
    var currentFrameImageWasPreview = false

    // the view mode that we set this image with
    var currentFrameImageViewMode: FrameViewMode = .original // XXX really orig?

    @Published var initialLoadInProgress = false
    @Published var loadingAllOutliers = false
    @Published var loadingOutliers = false
    
    @Published var numberOfFramesWithOutliersLoaded = 0

    @Published var numberOfFramesLoaded = 0

    @Published var outlierGroupTableRows: [OutlierGroupTableRow] = []
    @Published var outlierGroupWindowFrame: FrameAirplaneRemover?

    @Published var selectedOutliers = Set<OutlierGroupTableRow.ID>()

    @Published var selectionMode = SelectionMode.paint
    @Published var renderingCurrentFrame = false

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

    @Published var outlierOpacity = 1.0

    @Published var sliderValue = 0.0

    @Published var interactionMode: InteractionMode = .play

    @Published var previousInteractionMode: InteractionMode = .play

    // enum for how we show each frame
    @Published var frameViewMode = FrameViewMode.processed

    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    @Published var showFullResolution = false

    @Published var showFilmstrip = true

    @Published var backgroundColor: Color = .gray

    @Published var renderingAllFrames = false
    @Published var updatingFrameBatch = false

    @Published var videoPlaybackFramerate = 30

    @Published var settingsSheetShowing = false
    @Published var paintSheetShowing = false

    @Published var multiSelectSheetShowing = false {
        didSet(oldValue) {
            if !multiSelectSheetShowing {
                drag_start = nil
                drag_end = nil
            }
        }
    }
    @Published var multiSelectionType: MultiSelectionType = .all
    @Published var multiSelectionPaintType: MultiSelectionPaintType = .clear
    
    @Published var drag_start: CGPoint?
    @Published var drag_end: CGPoint?
    @Published var number_of_frames: Int = 50
    
    // the frame number of the frame we're currently showing
    @Published var currentIndex = 0

    // number of frames in the sequence we're processing
    var imageSequenceSize: Int = 0

    @Published var inTransition = false
    
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

    var numberOfFramesChanged: Int {
        var ret = frameSaveQueue?.purgatory.count ?? 0
        if let currentFrame = self.currentFrame,
           currentFrame.hasChanges(),
           !(frameSaveQueue?.frameIsInPurgatory(currentFrame.frameIndex) ?? false)
        {
            ret += 1            // XXX make sure the current frame isn't in purgatory
        }
        return ret
    }
    
    var loadingOutlierGroups: Bool {
        for frame in frames { if frame.loadingOutlierViews { return true } }
        return false
    }
    
    var eraserTask: Task<(),Never>?
    
    func set(numberOfFrames: Int) {
        Task {
            await MainActor.run {
                frames = [FrameViewModel](count: numberOfFrames) { i in FrameViewModel(i) }
            }
        }
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

            let vpTask = Task { acc.loadImage(type: .validated,  atSize: .preview)?.resizable() }
            let spTask = Task { acc.loadImage(type: .subtracted, atSize: .preview)?.resizable() }
            let bpTask = Task { acc.loadImage(type: .blobs,      atSize: .preview)?.resizable() }
            let apTask = Task { acc.loadImage(type: .absorbed,   atSize: .preview)?.resizable() }
            let rpTask = Task { acc.loadImage(type: .rectified,  atSize: .preview)?.resizable() }
            let ppTask = Task { acc.loadImage(type: .paintMask,  atSize: .preview)?.resizable() }
            let prTask = Task { acc.loadImage(type: .processed,  atSize: .preview)?.resizable() }
            let opTask = Task { acc.loadImage(type: .original,   atSize: .preview)?.resizable() }
            let otTask = Task { acc.loadImage(type: .original,   atSize: .thumbnail) }

            if let image = await vpTask.value {
                self.frames[frame.frameIndex].validationPreviewImage = image
            }
            if let image = await spTask.value  {
                self.frames[frame.frameIndex].subtractionPreviewImage = image
            }
            if let image = await bpTask.value {
                self.frames[frame.frameIndex].blobsPreviewImage = image
            }
            if let image = await apTask.value {
                self.frames[frame.frameIndex].absorbedPreviewImage = image
            }
            if let image = await rpTask.value {
                self.frames[frame.frameIndex].rectifiedPreviewImage = image
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

            if self.currentIndex == frame.frameIndex {

                // refresh ui 
                await MainActor.run { self.refreshCurrentFrame() }
            }
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
            let outlierGroups = frame.outlierGroupList()
            if let outlierGroups = outlierGroups {
                Log.d("got \(outlierGroups.count) groups for frame \(frame.frameIndex)")
                var newOutlierGroups: [OutlierGroupViewModel] = []
                for group in outlierGroups {
                    if let cgImage = group.testImage() { // XXX heap corruption here :(
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
                await self.frames[frame.frameIndex].outlierViews = newOutlierGroups

                await MainActor.run { self.objectWillChange.send() }
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
        self.currentFrameImage = nil
        self.currentFrameImageIndex = 0
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

        UserPreferences.shared.justOpened(filename: jsonConfigFilename)
        
        let config = try await Config.read(fromJsonFilename: jsonConfigFilename)
        constants.detectionType = config.detectionType
        
        let callbacks = makeCallbacks()
        
        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                        callbacks: callbacks,
                                                        processExistingFiles: true,
                                                        fullyProcess: false,
                                                        isGUI: true)
        
        await MainActor.run {
            self.eraser = eraser // XXX rename this crap
            self.config = config
            self.frameSaveQueue = FrameSaveQueue()
        }
    }
    
    @MainActor func startup(withNewImageSequence imageSequenceDirname: String) async throws {

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

        // XXX always using default here, not set above in config constructor
        constants.detectionType = config.detectionType
        
        let callbacks = self.makeCallbacks()
        Log.i("have config")

        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                        callbacks: callbacks,
                                                        processExistingFiles: true,
                                                        isGUI: true)

        self.eraser = eraser // XXX rename this crap
        self.config = config
        self.frameSaveQueue = FrameSaveQueue()
    }
    
    @MainActor func makeCallbacks() -> Callbacks {
        let callbacks = Callbacks()


        // get the full number of images in the sequcne
        callbacks.imageSequenceSizeClosure = { imageSequenceSize in
            self.imageSequenceSize = imageSequenceSize
            Log.i("read imageSequenceSize \(imageSequenceSize)")
            self.set(numberOfFrames: imageSequenceSize)
        }
        
        callbacks.frameStateChangeCallback = { frame, state in
            // XXX do something here
            Log.d("frame \(frame.frameIndex) changed to state \(state)")
            Task {
                await MainActor.run {
                    //self.frame_states[frame.frameIndex] = state
                    self.objectWillChange.send()
                }
            }
        }

        // called when we should check a frame
        callbacks.frameCheckClosure = { newFrame in
            Log.d("frameCheckClosure for frame \(newFrame.frameIndex)")

            self.addToViewModel(frame: newFrame)
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

        //refresh(frame: newFrame)
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
    
    func setAllFrameOutliers(in frameView: FrameViewModel,
                             to shouldPaint: Bool,
                             renderImmediately: Bool = true)
    {
        Log.d("setAllFrameOutliers in frame \(frameView.frameIndex) to should paint \(shouldPaint)")
        let reason = PaintReason.userSelected(shouldPaint)
        
        // update the view model first
        if let outlierViews = frameView.outlierViews {
            outlierViews.forEach { outlierView in
                outlierView.group.shouldPaint = reason
            }
        }

        if frameView.frameIndex == self.currentIndex {
            self.refreshCurrentFrame() 
            frameView.updateAllOutlierViews()
        }

        if let frame = frameView.frame {
            // update the real actor in the background
            Task {
                await frame.userSelectAllOutliers(toShouldPaint: shouldPaint)

                if renderImmediately {
                    // XXX make render here an option in settings
                    await render(frame: frame) {
                        self.refresh(frame: frame)
                    }
                }
            }
        } else {
            Log.w("frame \(frameView.frameIndex) has no frame")
        }
    }

    func render(frame: FrameAirplaneRemover, closure: (() -> Void)? = nil) async {
        if let frameSaveQueue = self.frameSaveQueue
        {
            self.renderingCurrentFrame = true // XXX might not be right anymore
            frameSaveQueue.saveNow(frame: frame) {
                self.refresh(frame: frame)
                self.refreshCurrentFrame()
                self.renderingCurrentFrame = false
                closure?()
            }
        }
    }

    // next frame point
    func transition(toFrame newFrameView: FrameViewModel,
                    from oldFrame: FrameAirplaneRemover?,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        if inTransition { return }
//        inTransition = true
        Log.d("transition from \(String(describing: self.currentFrame))")
        let startTime = Date().timeIntervalSinceReferenceDate

        if self.currentIndex >= 0,
           self.currentIndex < self.frames.count
        {
            self.frames[self.currentIndex].isCurrentFrame = false
        }
        self.frames[newFrameView.frameIndex].isCurrentFrame = true
        self.currentIndex = newFrameView.frameIndex
        self.sliderValue = Double(self.currentIndex)
        
        if interactionMode == .edit {
            if let scroller {
                scroller.scrollTo(self.currentIndex, anchor: .center)
            }

            //self.labelText = "frame \(newFrameView.frameIndex)"

            // only save frame when we are also scrolling (i.e. not scrubbing)
            if let frameToSave = oldFrame {
                let frameChanged = frameToSave.hasChanges()

                // only save changes to frames that have been changed
                if frameChanged {
                    Task {
                        self.saveToFile(frame: frameToSave) {
                            Log.d("completion closure called for frame \(frameToSave.frameIndex)")
                            self.refresh(frame: frameToSave)
                        }
                    }
                }
            } else {
                Log.w("no old frame with changes to save")
            }
        }
        
        refreshCurrentFrame()

        let endTime = Date().timeIntervalSinceReferenceDate
        Log.d("transition to frame \(newFrameView.frameIndex) took \(endTime - startTime) seconds")
    }

    func refreshCurrentFrame() {
        // XXX maybe don't wait for frame?
        Log.d("refreshCurrentFrame \(self.currentIndex)")
        let newFrameView = self.frames[self.currentIndex]
        if let nextFrame = newFrameView.frame {

            // usually stick the preview image in there first if we have it
            var showPreview = true

            if showFullResolution &&
               self.currentFrameImageIndex == newFrameView.frameIndex &&
               !self.currentFrameImageWasPreview
            {
                // showing the preview in this case causes flickering
                showPreview = false
            }
                 
            if showPreview {
                self.currentFrameImageIndex = newFrameView.frameIndex
                self.currentFrameImageWasPreview = true
                self.currentFrameImageViewMode = self.frameViewMode

                switch self.frameViewMode {
                case .original:
                    self.currentFrameImage = newFrameView.previewImage
                case .subtraction:
                    self.currentFrameImage = newFrameView.subtractionPreviewImage
                case .blobs:
                    self.currentFrameImage = newFrameView.blobsPreviewImage
                case .absorbedBlobs:
                    self.currentFrameImage = newFrameView.absorbedPreviewImage
                case .rectifiedBlobs:
                    self.currentFrameImage = newFrameView.rectifiedPreviewImage
                case .paintMask:
                    self.currentFrameImage = newFrameView.paintMaskPreviewImage
                case .validation:
                    self.currentFrameImage = newFrameView.validationPreviewImage
                case .processed:
                    self.currentFrameImage = newFrameView.processedPreviewImage
                }
            }
            if showFullResolution {
                if nextFrame.frameIndex == self.currentIndex {
                    Task {

                        self.currentFrameImageIndex = newFrameView.frameIndex
                        self.currentFrameImageWasPreview = false
                        self.currentFrameImageViewMode = self.frameViewMode
                        
                        switch self.frameViewMode {
                        case .original:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .original, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }
                        case .subtraction:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .subtracted, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }
                        case .blobs:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .blobs, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }
                        case .absorbedBlobs:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .absorbed, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }
                        case .rectifiedBlobs:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .rectified, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }
                        case .paintMask:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .paintMask, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }

                        case .validation:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .validated, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }
                            
                        case .processed:
                            if let baseImage = await nextFrame.imageAccessor.loadImage(type: .processed, atSize: .original) {
                                if nextFrame.frameIndex == self.currentIndex {
                                    await MainActor.run {
                                        self.currentFrameImage = baseImage
                                    }
                                }
                            }
                        }
                    }
                }
            }

            if interactionMode == .edit {
                // try loading outliers if there aren't any present
                let frameView = self.frames[nextFrame.frameIndex]
                if frameView.outlierViews == nil,
                   !frameView.loadingOutlierViews
                {
                    frameView.loadingOutlierViews = true
                    self.loadingOutliers = true
                    Task.detached(priority: .userInitiated) {
                        let _ = try await nextFrame.loadOutliers()
                        await self.setOutlierGroups(forFrame: nextFrame)
                        Task { @MainActor in
                            frameView.loadingOutlierViews = false
                            self.loadingOutliers = self.loadingOutlierGroups
                            self.inTransition = false
                        }
                    }
                } else {
                    Task { @MainActor in
                        self.inTransition = false
                    }
                }
            } else {
                Task { @MainActor in
                    self.inTransition = false
                }
            }
        } else {
            Log.d("WTF for frame \(self.currentIndex)")
           
        }
    }

    // next frame entry point
    func transition(numberOfFrames: Int,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        let currentFrame = self.currentFrame

        var newIndex = self.currentIndex + numberOfFrames
        if newIndex < 0 { newIndex = 0 }
        if newIndex >= self.frames.count {
            newIndex = self.frames.count-1
        }
        let newFrameView = self.frames[newIndex]
        
        self.transition(toFrame: newFrameView,
                        from: currentFrame,
                        withScroll: scroller)
    }

    func transition(until fastAdvancementType: FastAdvancementType,
                  from frame: FrameAirplaneRemover,
                  forwards: Bool,
                  currentIndex: Int? = nil,
                  withScroll scroller: ScrollViewProxy? = nil)
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
                self.transition(toFrame: self.frames[frameIndex],
                                from: frame,
                                withScroll: scroller)
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
            if let num = nextFrameView.numberOfPositiveOutliers {
                skip = num == 0
            }

        case .toNextNegative:
            if let num = nextFrameView.numberOfNegativeOutliers {
                skip = num == 0
            }

        case .toNextUnknown:
            if let num = nextFrameView.numberOfUndecidedOutliers {
                skip = num == 0
            }
        }
        
        // skip this one
        if skip {
            self.transition(until: fastAdvancementType,
                            from: frame,
                            forwards: forwards,
                            currentIndex: nextFrameIndex,
                            withScroll: scroller)
        } else {
            self.transition(toFrame: nextFrameView,
                            from: frame,
                            withScroll: scroller)
        }
    }

    // used when advancing between frames
    func saveToFile(frame frameToSave: FrameAirplaneRemover, completionClosure: @escaping () -> Void) {
        Log.d("saveToFile frame \(frameToSave.frameIndex)")
        if let frameSaveQueue = self.frameSaveQueue {
            frameSaveQueue.readyToSave(frame: frameToSave, completionClosure: completionClosure)
        } else {
            Log.e("FUCK")
            fatalError("SETUP WRONG")
        }
    }

    // starts or stops video from playing
    func togglePlay(_ scroller: ScrollViewProxy? = nil) {
        self.videoPlaying = !self.videoPlaying
        if self.videoPlaying {

            self.previousInteractionMode = self.interactionMode
            self.interactionMode = .play

            Log.d("playing @ \(self.videoPlaybackFramerate) fps")
            currentVideoFrame = self.currentIndex

            videoPlayTimer = Timer.scheduledTimer(withTimeInterval: 1/Double(self.videoPlaybackFramerate),
                                                  repeats: true) { timer in
                let currentIdx = currentVideoFrame
                // play each frame of the video in sequence
                if currentIdx >= self.frames.count ||
                     currentIdx < 0
                {
                    self.stopVideo(scroller)
                } else {
                    // play each frame of the video in sequence
                    switch self.frameViewMode {
                    case .original:
                        self.currentFrameImage =
                          self.frames[currentIdx].previewImage
                        
                    case .subtraction:
                        self.currentFrameImage =
                          self.frames[currentIdx].subtractionPreviewImage

                    case .blobs: 
                        self.currentFrameImage =
                          self.frames[currentIdx].blobsPreviewImage

                    case .absorbedBlobs: 
                        self.currentFrameImage =
                          self.frames[currentIdx].absorbedPreviewImage

                    case .rectifiedBlobs: 
                        self.currentFrameImage =
                          self.frames[currentIdx].rectifiedPreviewImage

                    case .paintMask: 
                        self.currentFrameImage =
                          self.frames[currentIdx].paintMaskPreviewImage

                    case .validation:
                        self.currentFrameImage =
                          self.frames[currentIdx].validationPreviewImage
                        
                    case .processed:
                        self.currentFrameImage =
                          self.frames[currentIdx].processedPreviewImage
                    }
                    
                    switch self.videoPlayMode {
                    case .forward:
                        currentVideoFrame = currentIdx + 1
                        
                    case .reverse:
                        currentVideoFrame = currentIdx - 1
                    }
                    
                    if currentVideoFrame >= self.frames.count {
                        self.stopVideo(scroller)
                    } else {
                        self.sliderValue = Double(currentIdx)
                    }
                }
            }
        } else {
            stopVideo(scroller)
        }
    }

    func stopVideo(_ scroller: ScrollViewProxy? = nil) {
        videoPlayTimer?.invalidate()

        self.interactionMode = self.previousInteractionMode
        
        if currentVideoFrame >= 0,
           currentVideoFrame < self.frames.count
        {
            self.currentIndex = currentVideoFrame
            self.sliderValue = Double(self.currentIndex)
        } else {
            self.currentIndex = 0
            self.sliderValue = Double(self.currentIndex)
        }
        
        self.videoPlaying = false
        self.backgroundColor = .gray
        
        if let scroller = scroller {
            // delay the scroller a little bit to allow the view to adjust
            // otherwise the call to scrollTo() happens when it's not visible
            // and is ignored, leaving the scroll view unmoved.
            Task {
                await MainActor.run {
                    scroller.scrollTo(self.currentIndex, anchor: .center)
                }
            }
        }
    }

    func goToFirstFrameButtonAction(withScroll scroller: ScrollViewProxy? = nil) {
        self.transition(toFrame: self.frames[0],
                        from: self.currentFrame,
                        withScroll: scroller)

    }

    func goToLastFrameButtonAction(withScroll scroller: ScrollViewProxy? = nil) {
        self.transition(toFrame: self.frames[self.frames.count-1],
                        from: self.currentFrame,
                        withScroll: scroller)

    }

    func fastPreviousButtonAction(withScroll scroller: ScrollViewProxy? = nil) {
        if self.fastAdvancementType == .normal {
            self.transition(numberOfFrames: -self.fastSkipAmount,
                            withScroll: scroller)
        } else if let currentFrame = self.currentFrame {
            self.transition(until: self.fastAdvancementType,
                            from: currentFrame,
                            forwards: false,
                            withScroll: scroller)
        }
    }

    func fastForwardButtonAction(withScroll scroller: ScrollViewProxy? = nil) {

        if self.fastAdvancementType == .normal {
            self.transition(numberOfFrames: self.fastSkipAmount,
                            withScroll: scroller)
        } else if let currentFrame = self.currentFrame {
            self.transition(until: self.fastAdvancementType,
                            from: currentFrame,
                            forwards: true,
                            withScroll: scroller)
        }
    }

}

// XXX Fing global :(
fileprivate var videoPlayTimer: Timer?

fileprivate var currentVideoFrame = 0

