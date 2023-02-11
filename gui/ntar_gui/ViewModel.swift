import Foundation
import SwiftUI
import Cocoa
import NtarCore
import Zoomable

// the overall view model
class ViewModel: ObservableObject {
    var config: Config?
    var eraser: NighttimeAirplaneRemover?
    var frameSaveQueue: FrameSaveQueue?
    var no_image_explaination_text: String = "Loading..."

    var frame_width: CGFloat = 300
    var frame_height: CGFloat = 300
    
    var label_text: String = "Started"

    // view class for each frame in the sequence in order
    @Published var frames: [FrameView] = [FrameView(0)]

    // currently selected index in the sequence
    var current_index = 0      
    
    var currentFrame: FrameAirplaneRemover? {
        return frames[current_index].frame
    }
    
    var currentFrameView: FrameView {
        return frames[current_index]
    }
    
    var currentThumbnailImage: Image? {
        return frames[current_index].thumbnail_image
    }

    func set(numberOfFrames: Int) {
        Task {
            await MainActor.run {
                frames = Array<FrameView>(count: numberOfFrames) { i in FrameView(i) }
            }
        }
    }
    
    var image_sequence_size: Int = 0
    
    init() {
        Log.w("VIEW MODEL INIT")
      
    }
    
    @MainActor func update() {
        Task { self.objectWillChange.send() }
    }


    func append(frame: FrameAirplaneRemover, viewModel: ViewModel) async {
        Log.d("appending frame \(frame.frame_index)")
        self.frames[frame.frame_index].frame = frame
        
        Log.d("set self.frames[\(frame.frame_index)].frame")

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
            
            // XXX cache these scrub previews?
            // look for saved versions of these
            
            if let preview_filename = frame.previewFilename,
               let preview_image = NSImage(contentsOf: URL(fileURLWithPath: preview_filename))
            {
                Log.d("loaded preview for self.frames[\(frame.frame_index)] from jpeg")
                self.frames[frame.frame_index].preview_image =
                  Image(nsImage: preview_image)
            } else {
                if pixImage == nil { pixImage = try await frame.pixelatedImage() }
                if baseImage == nil { baseImage = pixImage!.baseImage }
                if let baseImage = baseImage,
                   let preview_base = baseImage.resized(to: preview_size)
                {
                    Log.d("set preview image for self.frames[\(frame.frame_index)].frame")
                    self.frames[frame.frame_index].preview_image =
                      Image(nsImage: preview_base)
                } else {
                    Log.w("set unable to load preview image for self.frames[\(frame.frame_index)].frame")
                }
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

            await setOutlierGroups(forFrame: frame)
            // refresh ui 
            await MainActor.run {
                viewModel.objectWillChange.send()
            }
        }
    }

    func setOutlierGroups(forFrame frame: FrameAirplaneRemover) async {
        self.frames[frame.frame_index].outlierViews = []
        let outlierGroups = await frame.outlierGroups()
        let (frame_width, frame_height) = (frame.width, frame.height)
        for group in outlierGroups {
            if let cgImage = group.testImage() {
                var size = CGSize()
                size.width = CGFloat(cgImage.width)
                size.height = CGFloat(cgImage.height)
                let outlierImage = NSImage(cgImage: cgImage,
                                           size: size)
                
                let groupView = OutlierGroupView(group: group,
                                                 name: group.name,
                                                 bounds: group.bounds,
                                                 image: outlierImage,
                                                 frame_width: frame_width,
                                                 frame_height: frame_height)
                
                self.frames[frame.frame_index].outlierViews.append(groupView)
            } else {
                Log.e("frame \(frame.frame_index) outlier group no image")
            }
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
