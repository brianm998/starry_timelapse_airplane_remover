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

    private var updateCallbacks: [(Config) -> Void] = []

    /// Shared state for adaptive horizon parameter search across frames.
    /// This allows subsequent frames to narrow their search based on what worked
    /// for previous frames in the same sequence.
    public let adaptiveHorizonState = AdaptiveHorizonState()
    
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

    public func onUpdate(closure: @escaping @Sendable (Config) -> Void) {
        updateCallbacks.append(closure)
    }
    
    public func save() {
        _config.writeJson(named: _jsonFilename, overwrite: true) 
    }

    public func jsonFilename() -> String { _jsonFilename }
    
    public func config() -> Config { _config }

    public func update(_ config: Config) {
        self._config = config
        save()
        for callback in updateCallbacks {
            callback(config)
        }
    }
}

public struct Config: Codable, Sendable, Transferable {
 
    public static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }

    public init() {
        self.outputPath = "."
        self.tempOutputPath = "."
        self.cleanMethod = .automatic(false)
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
    public static func read(fromJsonFilename filename: String) throws -> Config {
        let config_url = NSURL(fileURLWithPath: filename, isDirectory: false) as URL

        let config_data = try Data(contentsOf: config_url)
        //let (config_data, _) = try await URLSession.shared.data(for: URLRequest(url: config_url))
        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: config_data)

        return config
    }

    public init(
      outputPath: String?,
      cleanMethod: CleanMethod = .automatic(false),
      detectionType: DetectionType = .strong,
      imageSequenceName: String,
      imageSequencePath: String,
      writeOutlierGroupFiles: Bool,
      writeFramePreviewFiles: Bool,
      writeFrameProcessedPreviewFiles: Bool,
      writeFrameThumbnailFiles: Bool
    ) {
        let prefix = "star_temp_\(imageSequenceName)"
        
        if let outputPath {
            self.tempOutputPath = "\(outputPath)/\(prefix)"
            self.outputPath = outputPath
        } else {
            self.tempOutputPath = "./\(prefix)"
            self.outputPath = "."
        }
        
        self.cleanMethod = cleanMethod
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

    // the base dir under which to create dir(s) for output sequence(s)
    public var tempOutputPath: String

    // the default pixel replement method for this sequence
    public var cleanMethod: CleanMethod

    // any frame specific overrides to the default pixel replacement method
    // indexed by frame number
    public var pixelReplacementOverrides: [Int:CleanMethod] = [:]

    public func cleanMethod(for frameIndex: Int) -> CleanMethod {
        if let method = pixelReplacementOverrides[frameIndex] {
            method
        } else {
            cleanMethod
        }
    }

    // per-frame overrides for numberStaticNeighborFrames, indexed by frame number.
    // allows specific frames to use a larger (or smaller) neighbor count for the
    // merged horizon computation without slowing down the whole sequence.
    public var staticNeighborFrameOverrides: [Int:Int] = [:]

    public func numberStaticNeighborFrames(for frameIndex: Int) -> Int {
        if let override = staticNeighborFrameOverrides[frameIndex] {
            override
        } else {
            numberStaticNeighborFrames
        }
    }

    // per-frame overrides for numberAlignedNeighborFrames, indexed by frame number.
    // allows specific frames to use a different neighbor count for star alignment
    // without changing the default for the whole sequence.
    public var alignedNeighborFrameOverrides: [Int:Int] = [:]

    public func numberAlignedNeighborFrames(for frameIndex: Int) -> Int {
        if let override = alignedNeighborFrameOverrides[frameIndex] {
            override
        } else {
            numberAlignedNeighborFrames
        }
    }
    
    // used with CleanMethod.selective and .automatic(true)
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

    // use when smoothing homography of moving videos
    // smaller values give more smoothing
    public var homographySmoothingEpsilon = 1e-2 // get this right

    // when camera is not moving, use this value instead of
    // numberAlignedNeighborFrames for calculating the merged horizon for each frame
    public var numberStaticNeighborFrames = 16 // total
    
    // this can stay this way more easily now that star supports video import to .tiff directly

    // really this should be filtered with cv::haveImageReader("image.exr");
    // and it is not specific to an image sequence, move it elsewhere
    public var supportedImageFileTypes = [".tif", ".tiff", "jpg", "jpeg", "png", "bmp", "ndr", "ppm", "pgm", "pdm"]

    // Memory management: fraction of physical memory that star is allowed to use.
    // Value between 0.1 and 0.95.  MemoryMonitor will gate large allocations
    // when mat memory exceeds this fraction of physical RAM.
    public var maxMatMemoryFraction: Double = 0.75

    // Memory management: minimum bytes of available system memory to preserve.
    // MemoryMonitor will delay allocations if available memory drops below this.
    // Default 1 GB.
    public var minAvailableMemoryBytes: UInt64 = 1_073_741_824

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

    // use the combined+RW horizon detector (Otsu + DP + SIOX → median → Random Walker)?
    // when true, this replaces the legacy adaptive Otsu/DP search in loadOrCreateHorizonMask.
    // set to false to fall back to the previous adaptive search approach.
    public var useCombinedHorizonDetection: Bool = true

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

    public var numberOfFramesToProcessConcurrently: Int = ProcessInfo.processInfo.processorCount
    
    // max number of frames to concurrently calculation keypoints on
    public var maxConcurrentKeypointCalculations: Int = ProcessInfo.processInfo.processorCount/2
    
    // when doing auto aligned outputs, how far to shift up the horizon mask
    // when doing a final composite image.
    public var horizonVerticalShiftAmount: Int = 8

    // try to align earth on moving frames?
    // turned off by default as it's still expermintal
    public var allowEarthAlignment: Bool = false

    // use homography-based horizon refinement after star alignment?
    // turned off by default as it's still experimental
    public var useHomographyRefinedHorizon: Bool = false

    // --- Adaptive horizon detection parameters ---

    // What size do we detect the horizon at?
    // Lower values are faster but less precise
    // expressed as [width, height] 
    public var horizonSearchSize: [Int] = [384, 384]

    // [min, max] bounds for the crop percentage search range.
    // Each value is a percentage (0-100) of the image height to ignore from the top.
    // The actual crop amounts tested are computed by dividing this range into
    // horizonSearchCropCount1 evenly spaced steps for the first pass, then
    // horizonSearchCropCount2 steps for a refined second pass around the first best.
    // An empty array disables adaptive search.
    public var horizonSearchCropBounds: [Double] = [10, 90]

    // Number of evenly spaced crop percentage values to test in the first pass.
    // The range defined by horizonSearchCropBounds is divided into this many steps.
    // e.g. bounds=[30,70] and count1=5 produces [30, 40, 50, 60, 70].
    public var horizonSearchCropCount1: Int = 16

    // Number of evenly spaced crop percentage values to test in the second
    // refinement pass. The second pass search area is centered on the first pass
    // best value and spans one first-pass step in each direction, divided into
    // this many steps.
    // e.g. if first pass step=10 and best=50, second pass searches [40..60]
    // divided into horizonSearchCropCount2 steps.
    public var horizonSearchCropCount2: Int = 24

    // After the first frame's horizon is detected, narrow the search area for
    // subsequent frames. This is the number of percentage points to add above
    // and below the previously detected best crop amount.
    // e.g. if best crop was 50 and this is 15, next frame searches [35, 50, 65].
    public var horizonSearchNarrowingRange: Double = 20

    // [min, max] range for the DP smoothness penalty (cost per pixel of vertical
    // displacement). Higher = smoother horizon line. Typical range: 0.5–5.0.
    // Set both values equal (and count=1) to use a single fixed value.
    public var dpHorizonSmoothnessLambdaRange: [Double] = [1, 2]

    // Number of evenly-spaced lambda values to test within the range above.
    // 1 = use only the min (or both equal) value. Higher = finer grid search.
    public var dpHorizonSmoothnessLambdaCount: Int = 4

    // [min, max] range for the Sobel vertical gradient weight in the DP cost.
    // Higher values make the path follow strong intensity transitions more.
    public var dpHorizonSobelWeightRange: [Double] = [0.2, 1.2]

    // Number of evenly-spaced Sobel weight values to test within the range above.
    public var dpHorizonSobelWeightCount: Int = 4

    // [min, max] range for the Canny edge presence weight in the DP cost.
    // Higher values make the path follow detected edges more.
    public var dpHorizonCannyWeightRange: [Double] = [0.2, 1.2]

    // Number of evenly-spaced Canny weight values to test within the range above.
    public var dpHorizonCannyWeightCount: Int = 4

    public var alignmentMaxKeypoints: Int = 2000
    public var alignmentWriteDebugImages: Bool = false
    public var alignmentGroundHorizonExtension: Int = 100 // extend the horizon for ground by this amount to get more keypoints
    public var alignmentSkyHorizonExtension: Int = 40
    public var alignmentBaseImageDilateSize: Int = 20
    public var alignmentBaseImageThresholdValue: Int = 100

    public var imageWidth: Int = 0
    public var imageHeight: Int = 0
    public var imageBytesPerPixel: Int = 0
    public var imageBitsPerComponent: Int = 0
    public var fileExtension: String = "tiff"
    
    // threshold used for throwing out bad pixels before replacing with them
    // good vs
    var pixelThreshold: Double = 1.2
    
    mutating public func set(videoInfo: VideoInfo) {
        self.frameRate = videoInfo.frameRate
        self.codec = videoInfo.codec
        self.encoder = videoInfo.encoder ?? .prores
        self.pixelFormat = videoInfo.pixelFormat
        self.muxer = videoInfo.muxer
        self.hasAudio = videoInfo.hasAudio
    }

    mutating public func set(imageInfo: ImageInfo) {
        self.imageWidth = imageInfo.imageWidth
        self.imageHeight = imageInfo.imageHeight
        self.imageBytesPerPixel = imageInfo.imageBytesPerPixel
        self.imageBitsPerComponent = imageInfo.imageBitsPerComponent
        self.fileExtension = imageInfo.fileExtension
    }

    public init(from decoder: Decoder) throws {
        // start with all your initializer defaults
        self = Config()

        let c = try decoder.container(keyedBy: CodingKeys.self)
        
        self.pixelThreshold = try c.decodeIfPresent(Double.self, forKey: .pixelThreshold) ?? self.pixelThreshold
        self.tempOutputPath = try c.decodeIfPresent(String.self, forKey: .tempOutputPath) ?? self.tempOutputPath
        self.outputPath = try c.decodeIfPresent(String.self, forKey: .outputPath) ?? self.outputPath
        self.cleanMethod = try c.decodeIfPresent(CleanMethod.self, forKey: .cleanMethod) ?? self.cleanMethod
        self.pixelReplacementOverrides = try c.decodeIfPresent([Int:CleanMethod].self, forKey: .pixelReplacementOverrides) ?? self.pixelReplacementOverrides
        self.staticNeighborFrameOverrides = try c.decodeIfPresent([Int:Int].self, forKey: .staticNeighborFrameOverrides) ?? self.staticNeighborFrameOverrides
        self.alignedNeighborFrameOverrides = try c.decodeIfPresent([Int:Int].self, forKey: .alignedNeighborFrameOverrides) ?? self.alignedNeighborFrameOverrides        
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
        self.useCombinedHorizonDetection = try c.decodeIfPresent(Bool.self, forKey: .useCombinedHorizonDetection) ?? self.useCombinedHorizonDetection
        self.horizonStripWidth = try c.decodeIfPresent(Int.self, forKey: .horizonStripWidth) ?? self.horizonStripWidth
        self.useCannyForHorizonDetection = try c.decodeIfPresent(Bool.self, forKey: .useCannyForHorizonDetection) ?? self.useCannyForHorizonDetection
        self.cannyMinThreshold = try c.decodeIfPresent(Double.self, forKey: .cannyMinThreshold) ?? self.cannyMinThreshold
        self.cannyMaxThreshold = try c.decodeIfPresent(Double.self, forKey: .cannyMaxThreshold) ?? self.cannyMaxThreshold
        self.cannyUseL2Gradient = try c.decodeIfPresent(Bool.self, forKey: .cannyUseL2Gradient) ?? self.cannyUseL2Gradient

        self.horizonMinY = try c.decodeIfPresent(Int.self, forKey: .horizonMinY)
        self.horizonMaxY = try c.decodeIfPresent(Int.self, forKey: .horizonMaxY)
        self.numberOfFramesToProcessConcurrently = try c.decodeIfPresent(Int.self, forKey: .numberOfFramesToProcessConcurrently) ?? self.numberOfFramesToProcessConcurrently
        self.maxConcurrentKeypointCalculations = try c.decodeIfPresent(Int.self, forKey: .maxConcurrentKeypointCalculations) ?? self.maxConcurrentKeypointCalculations

        self.horizonVerticalShiftAmount = try c.decodeIfPresent(Int.self, forKey: .horizonVerticalShiftAmount) ?? self.horizonVerticalShiftAmount

        self.allowEarthAlignment = try c.decodeIfPresent(Bool.self, forKey: .allowEarthAlignment) ?? self.allowEarthAlignment

        self.useHomographyRefinedHorizon = try c.decodeIfPresent(Bool.self, forKey: .useHomographyRefinedHorizon) ?? self.useHomographyRefinedHorizon

        
        self.alignmentMaxKeypoints = try c.decodeIfPresent(Int.self, forKey: .alignmentMaxKeypoints) ?? self.alignmentMaxKeypoints
        self.alignmentWriteDebugImages = try c.decodeIfPresent(Bool.self, forKey: .alignmentWriteDebugImages) ?? self.alignmentWriteDebugImages
        self.alignmentGroundHorizonExtension = try c.decodeIfPresent(Int.self, forKey: .alignmentGroundHorizonExtension) ?? self.alignmentGroundHorizonExtension
        self.alignmentSkyHorizonExtension = try c.decodeIfPresent(Int.self, forKey: .alignmentSkyHorizonExtension) ?? self.alignmentSkyHorizonExtension
        self.alignmentBaseImageDilateSize = try c.decodeIfPresent(Int.self, forKey: .alignmentBaseImageDilateSize) ?? self.alignmentBaseImageDilateSize
        self.alignmentBaseImageThresholdValue = try c.decodeIfPresent(Int.self, forKey: .alignmentBaseImageThresholdValue) ?? self.alignmentBaseImageThresholdValue
        

        self.starVersion = try c.decodeIfPresent(String.self, forKey: .starVersion) ?? self.starVersion

        self.numberFinalProcessingNeighborsNeeded = try c.decodeIfPresent(Int.self, forKey: .numberFinalProcessingNeighborsNeeded) ?? self.numberFinalProcessingNeighborsNeeded
        self.numberAlignedNeighborFrames = try c.decodeIfPresent(Int.self, forKey: .numberAlignedNeighborFrames) ?? self.numberAlignedNeighborFrames
        self.numberStaticNeighborFrames = try c.decodeIfPresent(Int.self, forKey: .numberStaticNeighborFrames) ?? self.numberStaticNeighborFrames        
        self.supportedImageFileTypes = try c.decodeIfPresent([String].self, forKey: .supportedImageFileTypes) ?? self.supportedImageFileTypes

        self.horizonSearchSize = try c.decodeIfPresent([Int].self, forKey: .horizonSearchSize) ?? self.horizonSearchSize
        self.horizonSearchCropBounds = try c.decodeIfPresent([Double].self, forKey: .horizonSearchCropBounds) ?? self.horizonSearchCropBounds
        self.horizonSearchCropCount1 = try c.decodeIfPresent(Int.self, forKey: .horizonSearchCropCount1) ?? self.horizonSearchCropCount1
        self.horizonSearchCropCount2 = try c.decodeIfPresent(Int.self, forKey: .horizonSearchCropCount2) ?? self.horizonSearchCropCount2
        self.horizonSearchNarrowingRange = try c.decodeIfPresent(Double.self, forKey: .horizonSearchNarrowingRange) ?? self.horizonSearchNarrowingRange
        self.dpHorizonSmoothnessLambdaRange = try c.decodeIfPresent([Double].self, forKey: .dpHorizonSmoothnessLambdaRange) ?? self.dpHorizonSmoothnessLambdaRange
        self.dpHorizonSmoothnessLambdaCount = try c.decodeIfPresent(Int.self, forKey: .dpHorizonSmoothnessLambdaCount) ?? self.dpHorizonSmoothnessLambdaCount
        self.dpHorizonSobelWeightRange = try c.decodeIfPresent([Double].self, forKey: .dpHorizonSobelWeightRange) ?? self.dpHorizonSobelWeightRange
        self.dpHorizonSobelWeightCount = try c.decodeIfPresent(Int.self, forKey: .dpHorizonSobelWeightCount) ?? self.dpHorizonSobelWeightCount
        self.dpHorizonCannyWeightRange = try c.decodeIfPresent([Double].self, forKey: .dpHorizonCannyWeightRange) ?? self.dpHorizonCannyWeightRange
        self.dpHorizonCannyWeightCount = try c.decodeIfPresent(Int.self, forKey: .dpHorizonCannyWeightCount) ?? self.dpHorizonCannyWeightCount

        self.maxMatMemoryFraction = try c.decodeIfPresent(Double.self, forKey: .maxMatMemoryFraction) ?? self.maxMatMemoryFraction
        self.minAvailableMemoryBytes = try c.decodeIfPresent(UInt64.self, forKey: .minAvailableMemoryBytes) ?? self.minAvailableMemoryBytes
    }

    /// Expand a [min, max] range and a step count into an array of evenly-spaced values.
    /// - count=1 → [min]  (single value; if min==max this is just that value)
    /// - count=2 → [min, max]
    /// - count>2 → min, min+step, …, max
    public static func expandRange(_ range: [Double], count: Int) -> [Double] {
        guard range.count >= 2 else { return [range.first ?? 0] }
        let lo = range[0]
        let hi = range[1]
        let n  = max(1, count)
        if n == 1 { return [lo] }
        let step = (hi - lo) / Double(n - 1)
        return (0..<n).map { lo + Double($0) * step }
    }

    /// Convenience accessors that expand the range+count pairs into value arrays.
    public var dpHorizonSmoothnessLambdaValues: [Double] {
        Config.expandRange(dpHorizonSmoothnessLambdaRange, count: dpHorizonSmoothnessLambdaCount)
    }
    public var dpHorizonSobelWeightValues: [Double] {
        Config.expandRange(dpHorizonSobelWeightRange, count: dpHorizonSobelWeightCount)
    }
    public var dpHorizonCannyWeightValues: [Double] {
        Config.expandRange(dpHorizonCannyWeightRange, count: dpHorizonCannyWeightCount)
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
    // 0.10.0 added automatic as new processing mode
    //        much improved initial instructions view
    //        bug fixes
    //        lots of horizon calculation improvements
    // 0.10.1 save full image alignment info
    //        add alignment params to config and UI
    //        add support for jpeg and other file types
    // 0.10.2 a lot of small 8 bit image fixes
    // 0.10.3 added alignment info window
    //        added fix bad alignment button (use existing homography)
    //        added second pass of alignment to fix bad alignment automatically
    // 0.10.4 fixed second pass of alignment to actually work
    //        updated deviation checks to use a min/max range, not median
    // 0.10.5 added more status and error reporting
    //        single thread alignment pre frame for better results
    // 0.10.6 added graph processing, split up processing into smaller chunks
    //        added alignment validation to estimate alignment for frames without enough stars
    //        bug fixes, runs a lot faster, less ram (hopefully)
    //        resurrected CLI
    // 0.10.7 adaptive horizon detection
    //        resurrected merged horizons
    //        finds best static horizon
    //        much faster preview generation in GUI
    //        much faster startup in GUI
    
    public var starVersion = Config.latestVersion

    public static let latestVersion = "0.10.8"

    // defaults to basename below if not set
    public var finalOutputDir: String? = nil
    
    public var basename: String {
        let _basename = "\(self.imageSequenceDirname)-star-v-\(self.starVersion)"
          .sanitized
        return _basename.replacingOccurrences(of: ".", with: "_")
    }

    public var outlierOutputDirname: String {
        "\(self.tempOutputPath)/outliers"
    }
    
    public func writeJson(named filename: String, overwrite: Bool = false) {
        
        // write to config json

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        do {
            let jsonData = try encoder.encode(self)

            var fullPath = ""
            if filename.hasPrefix(self.tempOutputPath) {
                fullPath = filename
            } else {
                fullPath = "\(self.tempOutputPath)/\(filename)"
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

    public var dirForKeypointData: String {
        "\(self.tempOutputPath)/keypoints"
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
                return "\(self.tempOutputPath)/previews"
            case .thumbnail:
                return "\(self.tempOutputPath)/thumbnails"
            }
        case .starAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/aligned"

            case .preview:
                return "\(self.tempOutputPath)/aligned-previews"
            case .thumbnail:
                return nil
            }
        case .failedStarAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/failed-aligned"

            case .preview:
                return "\(self.tempOutputPath)/failed-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .failedEarthAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/earth-failed-aligned"

            case .preview:
                return "\(self.tempOutputPath)/earth-failed-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .earthAligned:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/earth-aligned"

            case .preview:
                return "\(self.tempOutputPath)/earth-aligned-previews"
            case .thumbnail:
                return nil
            }
        case .horizon:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/horizon"

            case .preview:
                return "\(self.tempOutputPath)/horizon-previews"
            case .thumbnail:
                return nil
            }
        case .mergedHorizon:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/mergedHorizon"

            case .preview:
                return "\(self.tempOutputPath)/mergedHorizon-previews"
            case .thumbnail:
                return nil
            }
        case .refinedHorizon:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/refinedHorizon"

            case .preview:
                return "\(self.tempOutputPath)/refinedHorizon-previews"
            case .thumbnail:
                return nil
            }
        case .subtraction:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/aligned-subtracted"
            case .preview:
                return "\(self.tempOutputPath)/aligned-subtracted-previews"
            case .thumbnail:
                return nil
            }
        case .blobs:
            switch size {
            case .original:
                return nil
            case .preview:
                return "\(self.tempOutputPath)/blobs-preview"
            case .thumbnail:
                return nil
            }
        case .removeMask:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/paintMask"
            case .preview:
                return "\(self.tempOutputPath)/paintMask-preview"
            case .thumbnail:
                return nil
            }
        case .validation:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/validated-outlier-images"
            case .preview:
                return "\(self.tempOutputPath)/validated-outlier-images-previews"
            case .thumbnail:
                return nil
            }
        case .autoProcessed:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/auto-processed"
            case .preview:
                return "\(self.tempOutputPath)/auto-processed-previews"
            case .thumbnail:
                return nil
            }

        case .autoSelectiveProcessed:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/auto-selective-processed"
            case .preview:
                return "\(self.tempOutputPath)/auto-selective-processed-previews"
            case .thumbnail:
                return nil
            }

        case .selectiveProcessed:
            switch size {
            case .original:
                return "\(self.tempOutputPath)/selective-processed"
            case .preview:
                return "\(self.tempOutputPath)/selective-processed-previews"
            case .thumbnail:
                return nil
            }

        case .final:
            switch size {
            case .original:
                return self.outputSequenceDirname
            case .preview:
                return "\(self.tempOutputPath)/final-sequence-previews"
            case .thumbnail:
                return nil
            }
        }
    }

    public var outputSequenceDirname: String {
        if let finalOutputDir {
            return finalOutputDir
        } else {
            return "\(self.outputPath)/\(self.basename)"
        }
    }
    
    public var allImageDirnames: [String] {
        var ret: [String] = []
        
        if let dir = self.dirForImage(ofType: .starAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .failedStarAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .failedEarthAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .earthAligned) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .horizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .mergedHorizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .refinedHorizon) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .subtraction) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .validation) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .autoProcessed) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .autoSelectiveProcessed) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .selectiveProcessed) { ret.append(dir) }
        if let dir = self.dirForImage(ofType: .final) { ret.append(dir) }
        
        if self.writeFramePreviewFiles {
            if let dir = self.dirForImage(ofType: .original, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .starAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .failedStarAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .earthAligned, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .horizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .mergedHorizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .refinedHorizon, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .subtraction, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .validation, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .blobs, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .removeMask, atSize: .preview) { ret.append(dir) }
        }
        if self.writeFrameThumbnailFiles {
            if let dir = self.dirForImage(ofType: .original, atSize: .thumbnail) { ret.append(dir) }
        }
        if self.writeFrameProcessedPreviewFiles {
            if let dir = self.dirForImage(ofType: .final, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .autoProcessed, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .autoSelectiveProcessed, atSize: .preview) { ret.append(dir) }
            if let dir = self.dirForImage(ofType: .selectiveProcessed, atSize: .preview) { ret.append(dir) }
        }
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

    public var frameOutliersLoadedCallback: (@Sendable (Int, OutlierLoadingState) -> Void)?
    
    public init() { }
}


extension String {
    /// Returns a sanitized version of the string, replacing shell-unsafe characters with `_`.
    var sanitized: String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-/")
        let ret = self.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }.reduce("") { $0 + String($1) }
        return ret
    }
}
