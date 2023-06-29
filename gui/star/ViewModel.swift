import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable

public enum VideoPlayMode: String, Equatable, CaseIterable {
    case forward
    case reverse
}

public enum FrameViewMode: String, Equatable, CaseIterable {
    case original
    case processed

    var localizedName: LocalizedStringKey {
        LocalizedStringKey(rawValue)
    }
}

public enum SelectionMode: String, Equatable, CaseIterable {
    case paint
    case clear
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
@MainActor
public final class ViewModel: ObservableObject {
    var config: Config?
    var eraser: NighttimeAirplaneRemover?
    var no_image_explaination_text: String = "Loading..."

    @Environment(\.openWindow) private var openWindow

    @Published var frameSaveQueue: FrameSaveQueue?

    @Published var videoPlayMode: VideoPlayMode = .forward
    
    @Published var video_playing = false

    @Published var fastAdvancementType: FastAdvancementType = .normal

    // if fastAdvancementType == .normal, fast forward and reverse do a set number of frames
    @Published var fast_skip_amount = 20
    
    @Published var sequenceLoaded = false
    
    @Published var frame_width: CGFloat = 600 // placeholders until first frame is read
    @Published var frame_height: CGFloat = 450

    // how long the arrows are
    @Published var outlier_arrow_length: CGFloat = 70 // relative to the frame width above

    // how high they are (if pointing sideways)
    @Published var outlier_arrow_height: CGFloat = 180
    
    @Published var showErrorAlert = false
    @Published var errorMessage: String = ""
    
    var label_text: String = "Started"

    // view class for each frame in the sequence in order
    @Published var frames: [FrameViewModel] = [FrameViewModel(0)]

    // the image we're showing to the user right now
    @Published var current_frame_image: Image?

    // the frame index of the image that produced the current_frame_image
    var current_frame_image_index: Int = 0

    // the frame index of the image that produced the current_frame_image
    var current_frame_image_was_preview = false

    // the view mode that we set this image with
    var current_frame_image_view_mode: FrameViewMode = .original // XXX really orig?

    @Published var initial_load_in_progress = false
    @Published var loading_all_outliers = false
    @Published var loading_outliers = false
    
    @Published var number_of_frames_with_outliers_loaded = 0

    @Published var number_of_frames_loaded = 0

    @Published var outlierGroupTableRows: [OutlierGroupTableRow] = []
    @Published var outlierGroupWindowFrame: FrameAirplaneRemover?

    @Published var selectedOutliers = Set<OutlierGroupTableRow.ID>()

    @Published var selectionMode = SelectionMode.paint
    @Published var rendering_current_frame = false

    var selectionColor: Color {
        switch self.selectionMode {
        case .paint:
            return .red
        case .clear:
            return .green
        case .details:
            return .blue
        }
    }

    @Published var outlierOpacitySliderValue = 1.0

    @Published var savedOutlierOpacitySliderValue = 1.0

    @Published var sliderValue = 0.0

    @Published var interactionMode: InteractionMode = .scrub

    @Published var previousInteractionMode: InteractionMode = .scrub

    // enum for how we show each frame
    @Published var frameViewMode = FrameViewMode.processed

    // should we show full resolution images on the main frame?
    // faster low res previews otherwise
    @Published var showFullResolution = false

    @Published var showFilmstrip = true

    @Published var background_color: Color = .gray

    @Published var rendering_all_frames = false
    @Published var updating_frame_batch = false

    @Published var video_playback_framerate = 30

    @Published var settings_sheet_showing = false
    @Published var paint_sheet_showing = false
    
    // the frame number of the frame we're currently showing
    var current_index = 0

    // number of frames in the sequence we're processing
    var image_sequence_size: Int = 0

    var outlierLoadingProgress: Double {
        if image_sequence_size == 0 { return 0 }
        return Double(number_of_frames_with_outliers_loaded)/Double(image_sequence_size)
    }
    
    var frameLoadingProgress: Double {
        if image_sequence_size == 0 { return 0 }
        return Double(number_of_frames_loaded)/Double(image_sequence_size)
    }
    
    // currently selected index in the sequence
    var currentFrameView: FrameViewModel {
        if current_index < 0 { current_index = 0 }
        if current_index >= frames.count { current_index = frames.count - 1 }
        return frames[current_index]
    }
    
    var currentFrame: FrameAirplaneRemover? {
        if current_index >= 0,
           current_index < frames.count
        {
            return frames[current_index].frame
        }
        return nil
    }

    var numberOfFramesChanged: Int {
        var ret = frameSaveQueue?.purgatory.count ?? 0
        if let current_frame = self.currentFrame,
           current_frame.hasChanges(),
           !(frameSaveQueue?.frameIsInPurgatory(current_frame.frame_index) ?? false)
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
    
    @MainActor func update() {
        self.currentFrameView.update()
        self.objectWillChange.send()
    }

    func refresh(frame: FrameAirplaneRemover) async {
        Log.d("refreshing frame \(frame.frame_index)")
        let thumbnail_width = config?.thumbnail_width ?? Config.default_thumbnail_width
        let thumbnail_height = config?.thumbnail_height ?? Config.default_thumbnail_height
        let thumbnail_size = NSSize(width: thumbnail_width, height: thumbnail_height)
        
        Task {
            var pixImage: PixelatedImage?
            var baseImage: NSImage?
            // load the view frames from the main image
            
            // look for saved versions of these

            if let processed_preview_filename = frame.processedPreviewFilename,
               let processed_preview_image = NSImage(contentsOf: URL(fileURLWithPath: processed_preview_filename))
            {
                Log.d("loaded processed preview for self.frames[\(frame.frame_index)] from jpeg")
                let view_image = Image(nsImage: processed_preview_image).resizable()
                self.frames[frame.frame_index].processed_preview_image = view_image
            }
            
            if let preview_filename = frame.previewFilename,
               let preview_image = NSImage(contentsOf: URL(fileURLWithPath: preview_filename))
            {
                Log.d("loaded preview for self.frames[\(frame.frame_index)] from jpeg")
                let view_image = Image(nsImage: preview_image).resizable()
                self.frames[frame.frame_index].preview_image = view_image
            } 
            
            if let thumbnail_filename = frame.thumbnailFilename,
               let thumbnail_image = NSImage(contentsOf: URL(fileURLWithPath: thumbnail_filename))
            {
                Log.d("loaded thumbnail for self.frames[\(frame.frame_index)] from jpeg")
                self.frames[frame.frame_index].thumbnail_image =
                  Image(nsImage: thumbnail_image)
            } else {
                if pixImage == nil { pixImage = try await frame.pixelatedImage() }
                if baseImage == nil { baseImage = pixImage!.baseImage }
                if let baseImage = baseImage,
                   let thumbnail_base = baseImage.resized(to: thumbnail_size)
                {
                    self.frames[frame.frame_index].thumbnail_image =
                      Image(nsImage: thumbnail_base)
                } else {
                    Log.w("set unable to load thumbnail image for self.frames[\(frame.frame_index)].frame")
                }
            }

            if self.frames[frame.frame_index].outlierViews == nil {
                await self.setOutlierGroups(forFrame: frame)

                // refresh ui 
                await MainActor.run {
                    self.objectWillChange.send()
                }
            }
        }
    }

    func append(frame: FrameAirplaneRemover) async {
        Log.d("appending frame \(frame.frame_index)")

        guard frame.frame_index >= 0,
              frame.frame_index < self.frames.count
        else {
            Log.w("cannot add frame with index \(frame.frame_index) to array with \(self.frames.count) elements")
            return 
        }
        
        self.frames[frame.frame_index].frame = frame

        number_of_frames_loaded += 1
        if self.initial_load_in_progress {
            var have_all = true
            for frame in self.frames {
                if frame.frame == nil {
                    have_all = false
                    break
                }
            }
            if have_all {
                Log.d("WE HAVE THEM ALL")
                await MainActor.run {
                    self.initial_load_in_progress = false
                }
            }
        }
        Log.d("set self.frames[\(frame.frame_index)].frame")

        await refresh(frame: frame)
    }

    func setOutlierGroups(forFrame frame: FrameAirplaneRemover) async {
        Task.detached(priority: .userInitiated) {
            let outlierGroups = frame.outlierGroups()
            if let outlierGroups = outlierGroups {
                Log.d("got \(outlierGroups.count) groups for frame \(frame.frame_index)")
                var new_outlier_groups: [OutlierGroupViewModel] = []
                for group in outlierGroups {
                    if let cgImage = group.testImage() { // XXX heap corruption here :(
                        var size = CGSize()
                        size.width = CGFloat(cgImage.width)
                        size.height = CGFloat(cgImage.height)
                        let outlierImage = NSImage(cgImage: cgImage, size: size)
                        
                        let groupView = await OutlierGroupViewModel(group: group,
                                                                    name: group.name,
                                                                    bounds: group.bounds,
                                                                    image: outlierImage)
                        new_outlier_groups.append(groupView)
                    } else {
                        Log.e("frame \(frame.frame_index) outlier group no image")
                    }
                }
                await self.frames[frame.frame_index].outlierViews = new_outlier_groups

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
        if current_index < frames.count - 1 {
            current_index += 1
        }
        Log.d("next frame returning frame from index \(current_index)")
        if let frame = frames[current_index].frame {
            Log.d("frame has index \(frame.frame_index)")
        } else {
            Log.d("NO FRAME")
        }
        return frames[current_index]
    }

    func previousFrame() -> FrameViewModel {
        if current_index > 0 {
            current_index -= 1
        } else {
            current_index = 0
        }
        return frames[current_index]
    }

    // prepare for another sequence
    func unloadSequence() {
        if let eraserTask = eraserTask {
            eraserTask.cancel()
            self.eraserTask = nil
        }
        self.sequenceLoaded = false
        self.frames = [FrameViewModel(0)]
        self.current_frame_image = nil
        self.current_frame_image_index = 0
        self.initial_load_in_progress = false
        self.loading_all_outliers = false
        self.number_of_frames_with_outliers_loaded = 0
        self.number_of_frames_loaded = 0
        self.outlierGroupTableRows = []
        self.outlierGroupWindowFrame = nil
        self.selectedOutliers = Set<OutlierGroupTableRow.ID>()
        self.current_index = 0
        self.image_sequence_size = 0
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

    func startup(withConfig json_config_filename: String) async throws {
        Log.d("outlier_json_startup with \(json_config_filename)")
        // first read config from json

        UserPreferences.shared.justOpened(filename: json_config_filename)
        
        let config = try await Config.read(fromJsonFilename: json_config_filename)
        
        let callbacks = make_callbacks()
        
        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                        callbacks: callbacks,
                                                        processExistingFiles: true,/*,
                                                                                     maxResidentImages: 32*/
                                                        fullyProcess: false,
                                                        isGUI: true)
        
        await MainActor.run {
            self.eraser = eraser // XXX rename this crap
            self.config = config
            self.frameSaveQueue = FrameSaveQueue()
        }
    }
    
    @MainActor func startup(withNewImageSequence image_sequence_dirname: String) async throws {

        let numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount
        let should_write_outlier_group_files = true // XXX see what happens
        
        // XXX copied from star.swift
        var input_image_sequence_dirname = image_sequence_dirname 

        while input_image_sequence_dirname.hasSuffix("/") {
            // remove any trailing '/' chars,
            // otherwise our created output dir(s) will end up inside this dir,
            // not alongside it
            _ = input_image_sequence_dirname.removeLast()
        }

        if !input_image_sequence_dirname.hasPrefix("/") {
            let full_path =
              file_manager.currentDirectoryPath + "/" + 
              input_image_sequence_dirname
            input_image_sequence_dirname = full_path
        }
        
        var filename_paths = input_image_sequence_dirname.components(separatedBy: "/")
        var input_image_sequence_path: String = ""
        var input_image_sequence_name: String = ""
        if let last_element = filename_paths.last {
            filename_paths.removeLast()
            input_image_sequence_path = filename_paths.joined(separator: "/")
            if input_image_sequence_path.count == 0 { input_image_sequence_path = "/" }
            input_image_sequence_name = last_element
        } else {
            input_image_sequence_path = "/"
            input_image_sequence_name = input_image_sequence_dirname
        }

        let config = Config(outputPath: input_image_sequence_path,
                            outlierMaxThreshold: Defaults.outlierMaxThreshold,
                            outlierMinThreshold: Defaults.outlierMinThreshold,
                            minGroupSize: Defaults.minGroupSize,
                            numConcurrentRenders: numConcurrentRenders,
                            imageSequenceName: input_image_sequence_name,
                            imageSequencePath: input_image_sequence_path,
                            writeOutlierGroupFiles: should_write_outlier_group_files,
                            writeFramePreviewFiles: should_write_outlier_group_files,
                            writeFrameProcessedPreviewFiles: should_write_outlier_group_files,
                            writeFrameThumbnailFiles: should_write_outlier_group_files)

        
        
        let callbacks = self.make_callbacks()
        Log.i("have config")

        let eraser = try await NighttimeAirplaneRemover(with: config,
                                                        callbacks: callbacks,
                                                        processExistingFiles: true,
                                                        isGUI: true)

        self.eraser = eraser // XXX rename this crap
        self.config = config
        self.frameSaveQueue = FrameSaveQueue()
    }
    
    @MainActor func make_callbacks() -> Callbacks {
        let callbacks = Callbacks()


        // get the full number of images in the sequcne
        callbacks.imageSequenceSizeClosure = { image_sequence_size in
            self.image_sequence_size = image_sequence_size
            Log.i("read image_sequence_size \(image_sequence_size)")
            self.set(numberOfFrames: image_sequence_size)
        }
        
        // count numbers here for max running
        // XXX this method is obsolete
        callbacks.countOfFramesToCheck = {
//            let count = await self.framesToCheck.count()
            //Log.i("XXX count \(count)")
            return 1//count
        }

        
        callbacks.frameStateChangeCallback = { frame, state in
            // XXX do something here
            Log.d("frame \(frame.frame_index) changed to state \(state)")
            Task {
                await MainActor.run {
                    //self.frame_states[frame.frame_index] = state
                    self.objectWillChange.send()
                }
            }
        }

        // called when we should check a frame
        callbacks.frameCheckClosure = { new_frame in
            Log.d("frameCheckClosure for frame \(new_frame.frame_index)")

            // XXX we may need to introduce some kind of queue here to avoid hitting
            // too many open files on larger sequences :(
            Task {
                await self.addToViewModel(frame: new_frame)
            }
        }
        
        return callbacks
    }

    @MainActor func addToViewModel(frame new_frame: FrameAirplaneRemover) async {
        Log.d("addToViewModel(frame: \(new_frame.frame_index))")

        if self.config == nil {
            // XXX why this doesn't work initially befounds me,
            // but without doing this here there is no config present...
            //self.config = self.config
            Log.e("FUCK, config is nil")
        }
        if self.frame_width != CGFloat(new_frame.width) ||
           self.frame_height != CGFloat(new_frame.height)
        {
            // grab frame size from first frame
            self.frame_width = CGFloat(new_frame.width)
            self.frame_height = CGFloat(new_frame.height)
        }
        await self.append(frame: new_frame)

       // Log.d("addToViewModel self.frame \(self.frame)")

        // is this the currently selected frame?
        if self.current_index == new_frame.frame_index {
            self.label_text = "frame \(new_frame.frame_index)"

            Log.i("got frame index \(new_frame.frame_index)")

            // XXX not getting preview here

            do {
                if let baseImage = try await new_frame.baseImage() {
                    if self.current_index == new_frame.frame_index {
                        await MainActor.run {
                            Task {
                                self.current_frame_image = Image(nsImage: baseImage)
                                self.update()
                            }
                        }
                    }
                }
            } catch {
                Log.e("error")
            }

            // Perform UI updates
            self.update()
        } else {
            await MainActor.run {
                self.objectWillChange.send()
            }
        }
    }
}

// methods used in image sequence view
public extension ViewModel {
    func setAllCurrentFrameOutliers(to shouldPaint: Bool,
                                renderImmediately: Bool = true)
    {
        let current_frame_view = self.currentFrameView
        setAllFrameOutliers(in: current_frame_view,
                            to: shouldPaint,
                            renderImmediately: renderImmediately)
    }
    
    func setAllFrameOutliers(in frame_view: FrameViewModel,
                          to shouldPaint: Bool,
                          renderImmediately: Bool = true)
    {
        Log.d("setAllFrameOutliers in frame \(frame_view.frame_index) to should paint \(shouldPaint)")
        let reason = PaintReason.userSelected(shouldPaint)
        
        // update the view model first
        if let outlierViews = frame_view.outlierViews {
            outlierViews.forEach { outlierView in
                outlierView.group.shouldPaint = reason
            }
        }

        if let frame = frame_view.frame {
            // update the real actor in the background
            Task {
                await frame.userSelectAllOutliers(toShouldPaint: shouldPaint)

                if renderImmediately {
                    // XXX make render here an option in settings
                    await render(frame: frame) {
                        Task {
                            await self.refresh(frame: frame)
                            if frame.frame_index == self.current_index {
                                self.refreshCurrentFrame() // XXX not always current
                            }
                            self.update()
                        }
                    }
                } else {
                    if frame.frame_index == self.current_index {
                        self.refreshCurrentFrame() // XXX not always current
                    }
                    self.update()
                }
            }
        } else {
            Log.w("frame \(frame_view.frame_index) has no frame")
        }
    }

    func render(frame: FrameAirplaneRemover, closure: (() -> Void)? = nil) async {
        if let frameSaveQueue = self.frameSaveQueue
        {
            self.rendering_current_frame = true // XXX might not be right anymore
            frameSaveQueue.saveNow(frame: frame) {
                await self.refresh(frame: frame)
                self.refreshCurrentFrame()
                self.rendering_current_frame = false
                closure?()
            }
        }
    }

    func transition(toFrame new_frame_view: FrameViewModel,
                    from old_frame: FrameAirplaneRemover?,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        Log.d("transition from \(String(describing: self.currentFrame))")
        let start_time = Date().timeIntervalSinceReferenceDate

        if self.current_index >= 0,
           self.current_index < self.frames.count
        {
            self.frames[self.current_index].isCurrentFrame = false
        }
        self.frames[new_frame_view.frame_index].isCurrentFrame = true
        self.current_index = new_frame_view.frame_index
        self.sliderValue = Double(self.current_index)
        
        if interactionMode == .edit,
           let scroller = scroller
        {
            scroller.scrollTo(self.current_index, anchor: .center)

            //self.label_text = "frame \(new_frame_view.frame_index)"

            // only save frame when we are also scrolling (i.e. not scrubbing)
            if let frame_to_save = old_frame {

                Task {
                    let frame_changed = frame_to_save.hasChanges()

                    // only save changes to frames that have been changed
                    if frame_changed {
                        self.saveToFile(frame: frame_to_save) {
                            Log.d("completion closure called for frame \(frame_to_save.frame_index)")
                            Task {
                                await self.refresh(frame: frame_to_save)
                                self.update()
                            }
                        }
                    }
                }
            } else {
                Log.w("no old frame to save")
            }
        } else {
            Log.d("no scroller")
        }
        
        refreshCurrentFrame()

        let end_time = Date().timeIntervalSinceReferenceDate
        Log.d("transition to frame \(new_frame_view.frame_index) took \(end_time - start_time) seconds")
    }

    func refreshCurrentFrame() {
        // XXX maybe don't wait for frame?
        Log.d("refreshCurrentFrame \(self.current_index)")
        let new_frame_view = self.frames[self.current_index]
        if let next_frame = new_frame_view.frame {

            // usually stick the preview image in there first if we have it
            var show_preview = true

            /*
            Log.d("showFullResolution \(showFullResolution)")
            Log.d("self.current_frame_image_index \(self.current_frame_image_index)")
            Log.d("new_frame_view.frame_index \(new_frame_view.frame_index)")
            Log.d("self.current_frame_image_view_mode \(self.current_frame_image_view_mode)")
            Log.d("self.frameViewMode \(self.frameViewMode)")
            Log.d("self.current_frame_image_was_preview \(self.current_frame_image_was_preview)")
             */

            if showFullResolution &&
               self.current_frame_image_index == new_frame_view.frame_index &&
               self.current_frame_image_view_mode == self.frameViewMode &&
               !self.current_frame_image_was_preview
            {
                // showing the preview in this case causes flickering
                show_preview = false
            }
                 
            if show_preview {
                self.current_frame_image_index = new_frame_view.frame_index
                self.current_frame_image_was_preview = true
                self.current_frame_image_view_mode = self.frameViewMode

                switch self.frameViewMode {
                case .original:
                    self.current_frame_image = new_frame_view.preview_image//.resizable()
                case .processed:
                    self.current_frame_image = new_frame_view.processed_preview_image//.resizable()
                }
            }
            if showFullResolution {
                if next_frame.frame_index == self.current_index {
                    Task {
                        do {
                            self.current_frame_image_index = new_frame_view.frame_index
                            self.current_frame_image_was_preview = false
                            self.current_frame_image_view_mode = self.frameViewMode
                            
                            switch self.frameViewMode {
                            case .original:
                                if let baseImage = try await next_frame.baseImage() {
                                    if next_frame.frame_index == self.current_index {
                                        self.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                                
                            case .processed:
                                if let baseImage = try await next_frame.baseOutputImage() {
                                    if next_frame.frame_index == self.current_index {
                                        self.current_frame_image = Image(nsImage: baseImage)
                                    }
                                }
                            }
                        } catch {
                            Log.e("error")
                        }
                    }
                }
            }

            if interactionMode == .edit {
                // try loading outliers if there aren't any present
                let frameView = self.frames[next_frame.frame_index]
                if frameView.outlierViews == nil,
                   !frameView.loadingOutlierViews
                {
                    frameView.loadingOutlierViews = true
                    self.loading_outliers = true
                    Task.detached(priority: .userInitiated) {
                        let _ = try await next_frame.loadOutliers()
                        await MainActor.run {
                            Task {
                                await self.setOutlierGroups(forFrame: next_frame)
                                frameView.loadingOutlierViews = false
                                self.loading_outliers = self.loadingOutlierGroups
                                self.update()
                            }
                        }
                    }
                }
            }
        } else {
            Log.d("WTF for frame \(self.current_index)")
            self.update()
        }
    }


    func transition(numberOfFrames: Int,
                    withScroll scroller: ScrollViewProxy? = nil)
    {
        let current_frame = self.currentFrame

        var new_index = self.current_index + numberOfFrames
        if new_index < 0 { new_index = 0 }
        if new_index >= self.frames.count {
            new_index = self.frames.count-1
        }
        let new_frame_view = self.frames[new_index]
        
        self.transition(toFrame: new_frame_view,
                        from: current_frame,
                        withScroll: scroller)
    }

    func transition(until fastAdvancementType: FastAdvancementType,
                  from frame: FrameAirplaneRemover,
                  forwards: Bool,
                  currentIndex: Int? = nil,
                  withScroll scroller: ScrollViewProxy? = nil)
    {
        var frame_index: Int = 0
        if let currentIndex = currentIndex {
            frame_index = currentIndex
        } else {
            frame_index = frame.frame_index
        }
        
        if (!forwards && frame_index == 0) ||  
           (forwards && frame_index >= self.frames.count - 1)
        {
            if frame_index != frame.frame_index {
                self.transition(toFrame: self.frames[frame_index],
                                from: frame,
                                withScroll: scroller)
            }
            return
        }
        
        var next_frame_index = 0
        if forwards {
            next_frame_index = frame_index + 1
        } else {
            next_frame_index = frame_index - 1
        }
        let next_frame_view = self.frames[next_frame_index]

        var skip = false

        switch fastAdvancementType {
        case .normal:
            skip = false 

        case .skipEmpties:
            if let outlierViews = next_frame_view.outlierViews {
                skip = outlierViews.count == 0
            }

        case .toNextPositive:
            if let num = next_frame_view.numberOfPositiveOutliers {
                skip = num == 0
            }

        case .toNextNegative:
            if let num = next_frame_view.numberOfNegativeOutliers {
                skip = num == 0
            }

        case .toNextUnknown:
            if let num = next_frame_view.numberOfUndecidedOutliers {
                skip = num == 0
            }
        }
        
        // skip this one
        if skip {
            self.transition(until: fastAdvancementType,
                            from: frame,
                            forwards: forwards,
                            currentIndex: next_frame_index,
                            withScroll: scroller)
        } else {
            self.transition(toFrame: next_frame_view,
                            from: frame,
                            withScroll: scroller)
        }
    }

    // used when advancing between frames
    func saveToFile(frame frame_to_save: FrameAirplaneRemover, completionClosure: @escaping () -> Void) {
        Log.d("saveToFile frame \(frame_to_save.frame_index)")
        if let frameSaveQueue = self.frameSaveQueue {
            frameSaveQueue.readyToSave(frame: frame_to_save, completionClosure: completionClosure)
        } else {
            Log.e("FUCK")
            fatalError("SETUP WRONG")
        }
    }

    func togglePlay(_ scroller: ScrollViewProxy? = nil) {
        self.video_playing = !self.video_playing
        if self.video_playing {

            self.previousInteractionMode = self.interactionMode
            self.interactionMode = .scrub

            Log.d("playing @ \(self.video_playback_framerate) fps")
            current_video_frame = self.current_index

            switch self.frameViewMode {
            case .original:
                video_play_timer = Timer.scheduledTimer(withTimeInterval: 1/Double(self.video_playback_framerate),
                                                        repeats: true) { timer in
                    let current_idx = current_video_frame
                    // play each frame of the video in sequence
                    if current_idx >= self.frames.count ||
                         current_idx < 0
                    {
                        self.stopVideo(scroller)
                    } else {

                        // play each frame of the video in sequence
                        self.current_frame_image =
                          self.frames[current_idx].preview_image

                        switch self.videoPlayMode {
                        case .forward:
                            current_video_frame = current_idx + 1

                        case .reverse:
                            current_video_frame = current_idx - 1
                        }
                        
                        if current_video_frame >= self.frames.count {
                            self.stopVideo(scroller)
                        } else {
                            self.sliderValue = Double(current_idx)
                        }
                    }
                }
            case .processed:
                video_play_timer = Timer.scheduledTimer(withTimeInterval: 1/Double(self.video_playback_framerate),
                                                        repeats: true) { timer in

                    let current_idx = current_video_frame
                    // play each frame of the video in sequence
                    if current_idx >= self.frames.count ||
                       current_idx < 0
                    {
                        self.stopVideo(scroller)
                    } else {
                        self.current_frame_image =
                          self.frames[current_idx].processed_preview_image

                        switch self.videoPlayMode {
                        case .forward:
                            current_video_frame = current_idx + 1

                        case .reverse:
                            current_video_frame = current_idx - 1
                        }
                        
                        if current_video_frame >= self.frames.count {
                            self.stopVideo(scroller)
                        } else {
                            self.sliderValue = Double(current_idx)
                        }
                    }
                }
            }
        } else {
            stopVideo(scroller)
        }
    }

    func stopVideo(_ scroller: ScrollViewProxy? = nil) {
        video_play_timer?.invalidate()

        self.interactionMode = self.previousInteractionMode
        
        if current_video_frame >= 0,
           current_video_frame < self.frames.count
        {
            self.current_index = current_video_frame
            self.sliderValue = Double(self.current_index)
        } else {
            self.current_index = 0
            self.sliderValue = Double(self.current_index)
        }
        
        self.video_playing = false
        self.background_color = .gray
        
        if let scroller = scroller {
            // delay the scroller a little bit to allow the view to adjust
            // otherwise the call to scrollTo() happens when it's not visible
            // and is ignored, leaving the scroll view unmoved.
            Task {
                await MainActor.run {
                    scroller.scrollTo(self.current_index, anchor: .center)
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
            self.transition(numberOfFrames: -self.fast_skip_amount,
                            withScroll: scroller)
        } else if let current_frame = self.currentFrame {
            self.transition(until: self.fastAdvancementType,
                            from: current_frame,
                            forwards: false,
                            withScroll: scroller)
        }
    }

    func fastForwardButtonAction(withScroll scroller: ScrollViewProxy? = nil) {

        if self.fastAdvancementType == .normal {
            self.transition(numberOfFrames: self.fast_skip_amount,
                            withScroll: scroller)
        } else if let current_frame = self.currentFrame {
            self.transition(until: self.fastAdvancementType,
                            from: current_frame,
                            forwards: true,
                            withScroll: scroller)
        }
    }

}

// XXX Fing global :(
fileprivate var video_play_timer: Timer?

fileprivate var current_video_frame = 0


fileprivate let file_manager = FileManager.default

