import Foundation
import logging
import SwiftUI

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

 */

/*

 We need a config manager class

 an main actor which holds a config

 and knows how to save it again

 use this same config manager for all config accesses

 use this to allow changes in config at runtime in the gui to be used by StarCore

 The config manager can give the latest config, which is then used within a method

 save and load config in background
 
 */

@MainActor 
public class ConfigManager {
    private var _jsonFilename: String

    private var _config: Config

    public init() {
        _jsonFilename = ""
        _config = Config()
    }
    
    public init(configFilename: String, config: Config) {
        self._jsonFilename = configFilename
        self._config = config
    }
    
    public init(configFilename: String) throws {
        self._jsonFilename = configFilename
        if FileManager.default.fileExists(atPath: _jsonFilename) {
            self._config = try Config.read(fromJsonFilename: _jsonFilename)
        } else {
            self._config = Config()
        }
    }

    public func save() {
        _config.writeJson(named: _jsonFilename, overwrite: true) 
    }

    public func jsonFilename() -> String { _jsonFilename }
    
    public func config() -> Config { _config }

    public func update(_ config: Config) {
        self._config = config
        save()
    }
}

public struct Config: Codable, Sendable, Transferable {
 
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }

    public init() {
        self.outputPath = "."
        self.pixelReplacementMethod = .automatic(false)
        self.detectionType = .strong
        //self.numConcurrentRenders = 0
        self.imageSequenceDirname = ""
        self.imageSequencePath = ""
        self.writeOutlierGroupFiles = false
        self.writeFramePreviewFiles = false
        self.writeFrameProcessedPreviewFiles = false
        self.writeFrameThumbnailFiles = false
    }

    // returns a stored json config file
    static func read(fromJsonFilename filename: String) throws -> Config {
        let config_url = NSURL(fileURLWithPath: filename, isDirectory: false) as URL

        let config_data = try Data(contentsOf: config_url)
        //let (config_data, _) = try await URLSession.shared.data(for: URLRequest(url: config_url))
        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: config_data)

        return config
    }

    public init(outputPath: String?,
                pixelReplacementMethod: PixelReplacementMethod = .automatic(false),
                detectionType: DetectionType = .strong,
                imageSequenceName: String,
                imageSequencePath: String,
                writeOutlierGroupFiles: Bool,
                writeFramePreviewFiles: Bool,
                writeFrameProcessedPreviewFiles: Bool,
                writeFrameThumbnailFiles: Bool)
    {
        if let outputPath {
            self.outputPath = outputPath
        } else {
            self.outputPath = "."
        }
        self.pixelReplacementMethod = pixelReplacementMethod
        self.detectionType = detectionType
        self.imageSequenceDirname = imageSequenceName
        self.imageSequencePath = imageSequencePath
        self.writeOutlierGroupFiles = writeOutlierGroupFiles
        self.writeFramePreviewFiles = writeFramePreviewFiles
        self.writeFrameProcessedPreviewFiles = writeFrameProcessedPreviewFiles
        self.writeFrameThumbnailFiles = writeFrameThumbnailFiles
    }

    // the base dir under which to create dir(s) for output sequence(s)
    public var outputPath: String

    public var pixelReplacementMethod: PixelReplacementMethod

    // used with PixelReplacementMethod.selective
    public var detectionType: DetectionType

    // was the tripod head static, or moving?  Static assumed when not set.
    public var tripodHeadWasMoving: Bool = false
    
    // the name of the directory containing the input sequence
    public var imageSequenceDirname: String

    // where the input image sequence dir lives
    public var imageSequencePath: String
    
    // write out individual outlier group images
    public var writeOutlierGroupFiles: Bool

    public var writeOutlierClassificationValues: Bool = false
    
    // write out a preview file for each frame
    public var writeFramePreviewFiles: Bool

    // write out a processed preview file for each frame
    public var writeFrameProcessedPreviewFiles: Bool

    // write out a small thumbnail preview file for each frame
    public var writeFrameThumbnailFiles: Bool

    // how far in each direction do we go when doing final processing?
    // used for OutlierGroupFeature data
    public var numberFinalProcessingNeighborsNeeded = 2 // in each direction

    // align this many total neighbor frames for both
    // creating the subtraction image and calculating pixel values during removal
    public var numberAlignedNeighborFrames = 8 // total

    // when camera is not moving, use this value instead of
    // numberAlignedNeighborFrames for calculating the merged horizon for each frame
    public var numberStaticNeighborFrames = 16 // total
    
    // this can stay this way more easily now that star supports video import to .tiff directly
    public var supportedImageFileTypes = [".tif", ".tiff"] // XXX move this out

    // XXX use this to try to avoid running out of memory somehow
    // maybe determine megapixels of images, and guestimate usage and
    // avoid spawaning too many threads?
//    public var memorySizeBytes = ProcessInfo.processInfo.physicalMemory
//    public var memorySizeGigs = ProcessInfo.processInfo.physicalMemory/(1024*1024*1024)

    // used by updatable log
    public var progressBarLength = 35

    public var previewWidth: Int = defaultPreviewWidth
    public var previewHeight: Int = defaultPreviewHeight

    // if set outlier groups that are not further than this from the bottom
    // of the image will be ingored
    public var ignoreLowerPixels: Int = 0

    // XXX try making these larger now that video plays better
    public static let defaultPreviewWidth: Int = 1617 // 1080p in 4/3 aspect ratio
    public static let defaultPreviewHeight: Int = 1080
    
    public var thumbnailWidth: Int = defaultThumbnailWidth
    public var thumbnailHeight: Int = defaultThumbnailHeight

    nonisolated(unsafe) public static var defaultThumbnailWidth: Int = 80
    nonisolated(unsafe) public static var defaultThumbnailHeight: Int = 60

    // how far away from an outlier group pixel do we keep painting?
    public static let defaultOutlierGroupPaintBorderPixels: Double = 8

    // how far away from an outlier group pixel do we paint fully?
    // the distance between here and defaultOutlierGroupPaintBorderPixels is blended
    public static let defaultOutlierGroupPaintBorderInnerWallPixels: Double = 2

    // how many pixels out from the edge of an outlier group to paint further
    // pixels less than distance will be painted over with a fade until
    // outlierGroupPaintBorderInnerWallPixels reached.
    public var outlierGroupPaintBorderPixels: Double = defaultOutlierGroupPaintBorderPixels

    // where the fade of the alpha on the border begins.
    // pixels closer than this are fully painted over
    public var outlierGroupPaintBorderInnerWallPixels: Double = defaultOutlierGroupPaintBorderInnerWallPixels

    // the frame rate of the incoming and outgoing video
    public var frameRate: FrameRate = .fps_30

    // the codec of the incoming and outgoing video
    public var codec: FFmpegCodec = .prores

    // the encoder to use to encode the resulting video
    public var encoder: FFmpegEncoder = .prores

    // the pixelformat of the incoming and outgoing video
    public var pixelFormat: FFmpegPixelFormat = .yuv422p14le

    // the muxer (container) of the incoming and outgoing video
    public var muxer: FFmpegMuxer = .mov

    // did the incoming video have an audio track?
    public var hasAudio: Bool = false

    // do horizon processing or not.
    // if not set, defaults to true
    public var horizonDetectionEnabled: Bool = true

    // the max size of each strip used to calculate the horizon image.
    // smaller strips can help reduce noise especially around the edges of the frame
    // too small and the horizon can get calculated wrong
    public var horizonStripWidth: Int = 200

    // should we use canny edge detection along with otsu for horizon detection?
    // or just otsu?  Defaults to true (use both)
    public var useCannyForHorizonDetection: Bool = true

    // min threshold for canny edge detection for finding horizons
    public var cannyMinThreshold: Double = 50

    // max threshold for canny edge detection for finding horizons
    public var cannyMaxThreshold: Double = 120

    // should canny edge detection use the L2 Gradient or edge gradient?
    // true is for the L2Gradient, which is the default
    public var cannyUseL2Gradient: Bool = true
    
    // the vertical bounds of the horizon over the entire image sequence, if known
    public var horizonMinY: Int?
    public var horizonMaxY: Int?

    // max number of frames to concurrently horizon calculations on
    public var maxConcurrentHorizonCalculations: Int = 20

    // how many pixels do we crop off the top of the image when making
    // earth aligned images
    public var earthAlignedImageCropAmount: Int?
    
    mutating public func set(videoInfo: VideoInfo) {
        self.frameRate = videoInfo.frameRate
        self.codec = videoInfo.codec
        self.encoder = videoInfo.encoder ?? .prores
        self.pixelFormat = videoInfo.pixelFormat
        self.muxer = videoInfo.muxer
        self.hasAudio = videoInfo.hasAudio
    }

    public init(from decoder: Decoder) throws {
        // start with all your initializer defaults
        self = Config()

        let c = try decoder.container(keyedBy: CodingKeys.self)

        self.outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath) ?? self.outputPath
        self.pixelReplacementMethod = try c.decodeIfPresent(PixelReplacementMethod.self, forKey: .pixelReplacementMethod) ?? self.pixelReplacementMethod
        self.detectionType = try c.decodeIfPresent(DetectionType.self, forKey: .detectionType) ?? self.detectionType
        self.tripodHeadWasMoving = try c.decodeIfPresent(Bool.self, forKey: .tripodHeadWasMoving) ?? self.tripodHeadWasMoving

        self.imageSequenceDirname = try c.decodeIfPresent(String.self, forKey: .imageSequenceDirname) ?? self.imageSequenceDirname
        self.imageSequencePath = try c.decodeIfPresent(String.self, forKey: .imageSequencePath) ?? self.imageSequencePath

        self.writeOutlierGroupFiles = try c.decodeIfPresent(Bool.self, forKey: .writeOutlierGroupFiles) ?? self.writeOutlierGroupFiles
        self.writeFramePreviewFiles = try c.decodeIfPresent(Bool.self, forKey: .writeFramePreviewFiles) ?? self.writeFramePreviewFiles
        self.writeFrameProcessedPreviewFiles = try c.decodeIfPresent(Bool.self, forKey: .writeFrameProcessedPreviewFiles) ?? self.writeFrameProcessedPreviewFiles
        self.writeFrameThumbnailFiles = try c.decodeIfPresent(Bool.self, forKey: .writeFrameThumbnailFiles) ?? self.writeFrameThumbnailFiles

        self.ignoreLowerPixels = try c.decodeIfPresent(Int.self, forKey: .ignoreLowerPixels) ?? self.ignoreLowerPixels

        self.frameRate = try c.decodeIfPresent(FrameRate.self, forKey: .frameRate) ?? self.frameRate
        self.codec = try c.decodeIfPresent(FFmpegCodec.self, forKey: .codec) ?? self.codec
        self.encoder = try c.decodeIfPresent(FFmpegEncoder.self, forKey: .encoder) ?? self.encoder
        self.pixelFormat = try c.decodeIfPresent(FFmpegPixelFormat.self, forKey: .pixelFormat) ?? self.pixelFormat
        self.muxer = try c.decodeIfPresent(FFmpegMuxer.self, forKey: .muxer) ?? self.muxer
        self.hasAudio = try c.decodeIfPresent(Bool.self, forKey: .hasAudio) ?? self.hasAudio

        self.horizonDetectionEnabled = try c.decodeIfPresent(Bool.self, forKey: .horizonDetectionEnabled) ?? self.horizonDetectionEnabled
        self.horizonStripWidth = try c.decodeIfPresent(Int.self, forKey: .horizonStripWidth) ?? self.horizonStripWidth 
        self.useCannyForHorizonDetection = try c.decodeIfPresent(Bool.self, forKey: .useCannyForHorizonDetection) ?? self.useCannyForHorizonDetection
        self.cannyMinThreshold = try c.decodeIfPresent(Double.self, forKey: .cannyMinThreshold) ?? self.cannyMinThreshold
        self.cannyMaxThreshold = try c.decodeIfPresent(Double.self, forKey: .cannyMaxThreshold) ?? self.cannyMaxThreshold
        self.cannyUseL2Gradient = try c.decodeIfPresent(Bool.self, forKey: .cannyUseL2Gradient) ?? self.cannyUseL2Gradient

        self.horizonMinY = try c.decodeIfPresent(Int.self, forKey: .horizonMinY)
        self.horizonMaxY = try c.decodeIfPresent(Int.self, forKey: .horizonMaxY)
        self.maxConcurrentHorizonCalculations = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentHorizonCalculations) ?? self.maxConcurrentHorizonCalculations

        self.earthAlignedImageCropAmount = try c.decodeIfPresent(Int.self, forKey: .earthAlignedImageCropAmount)

        self.starVersion = try c.decodeIfPresent(String.self, forKey: .starVersion) ?? self.starVersion
    }

    
    // 0.0.2 added more detail group hough transormation analysis, based upon a data set
    // 0.0.3 included the data set analysis to include group size and fill, and to use histograms
    // 0.0.4 included .inStreak final processing
    // 0.0.5 added pixel overlap between outlier groups
    // 0.0.6 fixed streak processing and added another layer afterwards
    // 0.0.7 really fixed streak processing and lots of refactoring
    // 0.0.8 got rid of more false positives with weighted scoring and final streak tweaks
    // 0.0.9 softer outlier boundries, more streak tweaks, outlier overlap adjustments
    // 0.0.10 add alpha on soft outlier boundries, speed up final process some, fix memory problem
    // 0.0.11 fix soft outlier boundries, better constants, initial group filter
    // 0.0.12 fix a streak bug, other small fixes
    // 0.1.0 added height based size constraints, runs faster, gets 95% or more airplanes
    // 0.1.1 updatable logging, try to improve speed
    // 0.1.2 lots of speed/memory usage improvements, better updatable log
    // 0.1.3 started to add the gui
    // 0.2.0 added first gui, outlier groups can be saved, and reloaded with config
    // 0.3.0 added machine learning group classification, better threading, and more
    // 0.3.1 added release scripts for distribution, plus bug fixes
    // 0.3.2 fixed bugs, speed up tree forest, removes small outlier group dismissal
    // 0.3.3 speed up outlier saving, bug fixes, code improvements, renamed to star
    // 0.3.4 lots of UI improvements
    // 0.4.0 star alignment
    // 0.4.1 fixes after star alignment, better constants
    // 0.4.2 clean up memory usage during outlier detection, save outlier pixels as 16 bit, not 32
    // 0.4.3 subtraction images saved and re-used when available
    // 0.4.4 border painting enabled with config options
    // 0.5.0 blobber
    // 0.5.1 write validation images and use them for new outliers if present
    // 0.6.0 kernel hough transform and new blob to outlier group logic
    // 0.6.1 rewrote outlier detection logic to find smaller groups better
    // 0.6.2 added IsolatedBolbRemover, and BlobSmasher, tweaked lots of other blob stuff as well
    // 0.6.3 more cleanup, removed outlierMaxThreshold, changed how this is represented (/4 gone)
    // 0.6.4 attempted speed up, more blob filtering
    // 0.6.5 re-worked blob detection again, added separate DetectionType
    // 0.6.6 re-wrote outlier saving, using one image per frame for outlier data now
    // 0.6.7 y-axis outlier images, two new classfication features
    // 0.7.0 swift 6, blob updates, gui a lot better, KHT works, display lines, etc
    // 0.7.1 completely reworked excessive processing mode, memory fixes, blob processing window,
    //       custom blob processing, more user prefs
    //       dustbin filled by adding another .isolated decision tree before inter-frame processing
    // 0.7.3 small blobs as image / lots of other gui updates / fixes
    //       32bit BlobID
    //       fix HoughLineMatrix processor
    //       add shovel to gui
    //       cursors and icons in gui
    //       lots of renaming
    //       debug logging view
    //       lines better connected, fixed LinearBlobConnector
    //       use multiple aligned images to clean up really noisy frame sequences
    // 0.8.0 embed ffmpeg, ffprobe and align_image_stack in the app properly
    //       allow starting directly with a video and having the image sequence extracted
    //       ability to render to video from gui
    // 0.8.1 fix bug with non-standard incoming filenames
    // 0.9.0 add horizon detection
    //       add ground alignment images
    //       adjust pixel removal to use ground image when appropriate
    //       replace align_image_stack with custom opencv2 SIFT code for speed and accuracy
    //       move image subtraction logic to opencv2 for speed
    //       add MatWrapper for better cv::Mat memory handling
    //       fix shovel bug
    //       better hovering logic
    // 0.9.1 every PixelatedImage is a cv::Mat
    //       better image caching, uses less ram
    //       upgrade sheet on startup if there is a new version
    //       fix bug where outliers got way to large
    //       add memory stats on left panel
    //       add re-processing mode to right panel for easier re-processing
    
    public var starVersion = Config.latestVersion

    public static let latestVersion = "0.9.1"
    
    public var basename: String {
        let _basename = "\(self.imageSequenceDirname)-star-v-\(self.starVersion)"
          .sanitized
        return _basename.replacingOccurrences(of: ".", with: "_")
    }

    public var outlierOutputDirname: String {
        "\(self.outputPath)/\(self.basename)-outliers"
    }
    
    public func writeJson(named filename: String, overwrite: Bool = false) {
        
        // write to config json

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        do {
            let jsonData = try encoder.encode(self)

            var fullPath = ""
            if filename.hasPrefix(self.outputPath) {
                fullPath = filename
            } else {
                fullPath = "\(self.outputPath)/\(filename)"
            }
            
            if FileManager.default.fileExists(atPath: fullPath) {
                if overwrite {
                    try? FileManager.default.removeItem(atPath: fullPath)
                    FileManager.default.createFile(atPath: fullPath, contents: jsonData, attributes: nil)
                } else {
                    Log.w("cannot write to \(fullPath), it already exists")
                }
            } else {
                Log.i("creating \(fullPath)")                      
                FileManager.default.createFile(atPath: fullPath, contents: jsonData, attributes: nil)
            }
        } catch {
            Log.e("\(error)")
        }
    }

    public func dirForImage(ofType type: FrameViewMode,
                            atSize size: ImageDisplaySize = .original) -> String?
    {
        switch type {
        case .original:
            switch size {
            case .original:
                return "\(self.imageSequencePath)/\(self.imageSequenceDirname)"
            case .preview:
                return "\(self.outputPath)/\(self.basename)-previews"
            case .thumbnail:
                return "\(self.outputPath)/\(self.basename)-thumbnails"
            }
        case .starAligned:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-aligned"

            case .preview:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .earthAligned:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-earth-aligned"

            case .preview:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-earth-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .horizon:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-horizon"

            case .preview:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-horizon-previews"
            case .thumbnail:
                return nil
            }
        case .mergedHorizon:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-mergedHorizon"

            case .preview:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-mergedHorizon-previews"
            case .thumbnail:
                return nil
            }
        case .subtraction:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-aligned-subtracted"
            case .preview:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-aligned-subtracted-previews"
            case .thumbnail:
                return nil
            }
        case .blobs:
            switch size {
            case .original:
                return nil
            case .preview:
                return "\(self.outputPath)/\(self.basename)-blobs-preview"
            case .thumbnail:
                return nil
            }
        case .removeMask:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.basename)-paintMask"
            case .preview:
                return "\(self.outputPath)/\(self.basename)-paintMask-preview"
            case .thumbnail:
                return nil
            }
        case .validation:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-validated-outlier-images"
            case .preview:
                return "\(self.outputPath)/\(self.imageSequenceDirname)-star-validated-outlier-images-previews"
            case .thumbnail:
                return nil
            }
        case .processed:
            switch size {
            case .original:
                return "\(self.outputPath)/\(self.basename)"
            case .preview:
                return "\(self.outputPath)/\(self.basename)-processed-previews"
            case .thumbnail:
                return nil
            }
        }
    }

    public var allImageDirnames: [String] {
        var ret: [String] = []
        
        if let dir = self.dirForImage(ofType: .starAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .earthAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .horizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .mergedHorizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .subtraction) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .validation) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .processed) { ret.append(dir) }
        
        if self.writeFramePreviewFiles {
            if let dir = self.dirForImage(ofType: .original, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .starAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .earthAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .horizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .mergedHorizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .subtraction, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .validation, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .blobs, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .removeMask, atSize: .preview) { ret.append(dir) }
        }
        if self.writeFrameThumbnailFiles {
            if let dir = self.dirForImage(ofType: .original, atSize: .thumbnail) { ret.append(dir) }
        }
        if self.writeFrameProcessedPreviewFiles {
            if let dir = self.dirForImage(ofType: .processed, atSize: .preview) { ret.append(dir) }
        }
        Log.d("FUCKING dirs to make: \(ret)")
        return ret
    }
}

public enum OutlierLoadingState: Sendable {
    case unloaded
    case loading
    case loaded
}

public struct Callbacks: Sendable {
    
    public var updatable: UpdatableLog?

    public var frameStateChangeCallback: (@Sendable (FrameAirplaneRemover, FrameProcessingState) -> ())?

    public var frameSavingStateChangeCallback: (@Sendable (FrameAirplaneRemover, FrameSavingState, FrameSavingState) -> ())?

    public var exisingFrameStateChangeCallback: (@Sendable (Int) -> ())?

    // called for the user to see a frame
    public var frameCheckClosure: (@Sendable (FrameAirplaneRemover) -> ())?

    // returns the total full size of the image sequence
    public var imageSequenceSizeClosure: (@Sendable (Int) -> Void)?

    public var frameOutliersLoadedCallback: (@Sendable (Int, OutlierLoadingState) -> Void)?
    
    public init() { }
}


