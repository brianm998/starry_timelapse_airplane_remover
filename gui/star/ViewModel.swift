import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable


// the overall view model for a particular sequence
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
    /*    @Published*/
    
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
    
    /*
    var currentThumbnailImage: Image? {
        return frames[current_index].thumbnail_image
    }
*/
    func set(numberOfFrames: Int) {
        Task {
            await MainActor.run {
                frames = Array<FrameViewModel>(count: numberOfFrames) { i in FrameViewModel(i) }
            }
        }
    }
    
    init() {
        Log.w("VIEW MODEL INIT")
      
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

        let preview_width = config?.preview_width ?? Config.default_preview_width
        let preview_height = config?.preview_height ?? Config.default_preview_height
        let preview_size = NSSize(width: preview_width, height: preview_height)
        
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
        Task.detached  {
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
                        
                        let groupView = await OutlierGroupViewModel(viewModel: self,
                                                                    group: group,
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

    func startup(withConfig json_config_filename: String) async {
        Log.d("outlier_json_startup with \(json_config_filename)")
        // first read config from json

        UserPreferences.shared.justOpened(filename: json_config_filename)
        
        
        do {
            let config = try await Config.read(fromJsonFilename: json_config_filename)
            
            let callbacks = make_callbacks()
            
            let eraser = try NighttimeAirplaneRemover(with: config,
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
            
            Log.d("outlier json startup done")
        } catch {
            Log.e("\(error)")
            await MainActor.run {
                self.showErrorAlert = true
                self.errorMessage = "\(error)"
            }
        }
    }
    
    @MainActor func startup(withNewImageSequence image_sequence_dirname: String) {

        let outlierMaxThreshold: Double = 13
        let outlierMinThreshold: Double = 9
        let minGroupSize: Int = 80      // groups smaller than this are completely ignored
        let numConcurrentRenders: Int = ProcessInfo.processInfo.activeProcessorCount
        let should_write_outlier_group_files = true // XXX see what happens
        let process_outlier_group_images = false

        
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
                            outlierMaxThreshold: outlierMaxThreshold,
                            outlierMinThreshold: outlierMinThreshold,
                            minGroupSize: minGroupSize,
                            numConcurrentRenders: numConcurrentRenders,
                            imageSequenceName: input_image_sequence_name,
                            imageSequencePath: input_image_sequence_path,
                            writeOutlierGroupFiles: should_write_outlier_group_files,
                            writeFramePreviewFiles: should_write_outlier_group_files,
                            writeFrameProcessedPreviewFiles: should_write_outlier_group_files,
                            writeFrameThumbnailFiles: should_write_outlier_group_files)

        
        
        let callbacks = self.make_callbacks()
        Log.i("have config")

        do {
            let eraser = try NighttimeAirplaneRemover(with: config,
                                                      callbacks: callbacks,
                                                      processExistingFiles: true,
                                                      isGUI: true)

            self.eraser = eraser // XXX rename this crap
            self.config = config
            self.frameSaveQueue = FrameSaveQueue()
        } catch {
            Log.e("\(error)")
        }

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

fileprivate let file_manager = FileManager.default

