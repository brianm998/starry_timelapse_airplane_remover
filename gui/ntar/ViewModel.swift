import Foundation
import SwiftUI
import Cocoa
import NtarCore
import Zoomable

// the overall view model
@MainActor
public class ViewModel: ObservableObject {
    var app: ntar_app?
    var config: Config?
    var eraser: NighttimeAirplaneRemover?
    var frameSaveQueue: FrameSaveQueue?
    var no_image_explaination_text: String = "Loading..."

    @Published var sequenceLoaded = false
    
    @Published var frame_width: CGFloat = 600
    @Published var frame_height: CGFloat = 450
    
    var label_text: String = "Started"

    // view class for each frame in the sequence in order
    @Published var frames: [FrameView] = [FrameView(0)]

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

    @Published var number_of_frames_with_outliers_loaded = 0

    @Published var number_of_frames_loaded = 0

    @Published var outlierGroupTableRows: [OutlierGroupTableRow] = []
    @Published var outlierGroupWindowFrame: FrameAirplaneRemover?

    @Published var selectedOutliers = Set<OutlierGroupTableRow.ID>()
    
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
    var currentFrameView: FrameView {
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
                frames = Array<FrameView>(count: numberOfFrames) { i in FrameView(i) }
            }
        }
    }
    
    init() {
        Log.w("VIEW MODEL INIT")
      
    }
    
    @MainActor func update() {
        Task { self.objectWillChange.send() }
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
        self.frames[frame.frame_index].outlierViews = []

        
        let outlierGroups = await frame.outlierGroups()
        let (frame_width, frame_height) = (frame.width, frame.height)
        if let outlierGroups = outlierGroups {
            Log.d("got \(outlierGroups.count) groups for frame \(frame.frame_index)")
            var new_outlier_groups: [OutlierGroupView] = []
            for group in outlierGroups {
                if let cgImage = group.testImage() { // XXX heap corruption here :(
                    var size = CGSize()
                    size.width = CGFloat(cgImage.width)
                    size.height = CGFloat(cgImage.height)
                    let outlierImage = NSImage(cgImage: cgImage, size: size)
                    
                    let groupView = OutlierGroupView(group: group,
                                                           name: group.name,
                                                           bounds: group.bounds,
                                                           image: outlierImage,
                                                           frame_width: frame_width,
                                                           frame_height: frame_height)
                    new_outlier_groups.append(groupView)
                } else {
                    Log.e("frame \(frame.frame_index) outlier group no image")
                }
            }
            self.frames[frame.frame_index].outlierViews = new_outlier_groups
        }
    }
    
    func frame(atIndex index: Int) -> FrameAirplaneRemover? {
        if index < 0 { return nil }
        if index >= frames.count { return nil }
        return frames[index].frame
    }
    
    func nextFrame() -> FrameView {
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

    func previousFrame() -> FrameView {
        if current_index > 0 {
            current_index -= 1
        } else {
            current_index = 0
        }
        return frames[current_index]
    }
}
