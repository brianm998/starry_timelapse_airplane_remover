import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

public struct Config: Codable {

    public init() {
        self.outputPath = "."
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
    public static func read(fromJsonFilename filename: String) async throws -> Config {
        let config_url = NSURL(fileURLWithPath: filename, isDirectory: false) as URL
        let (config_data, _) = try await URLSession.shared.data(for: URLRequest(url: config_url))
        let decoder = JSONDecoder()
        let config = try decoder.decode(Config.self, from: config_data)

        return config
    }

    public init(outputPath: String?,
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

    public var detectionType: DetectionType
    
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
    public var numberFinalProcessingNeighborsNeeded = 2 // in each direction

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
    public var ignoreLowerPixels: Int?

    // XXX try making these larger now that video plays better
    public static let defaultPreviewWidth: Int = 1617 // 1080p in 4/3 aspect ratio
    public static let defaultPreviewHeight: Int = 1080
    
    public var thumbnailWidth: Int = defaultThumbnailWidth
    public var thumbnailHeight: Int = defaultThumbnailHeight

    public static var defaultThumbnailWidth: Int = 80
    public static var defaultThumbnailHeight: Int = 60

    // how far away from an outlier group pixel do we keep painting?
    public static let defaultOutlierGroupPaintBorderPixels: Double = 6

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
    // 0.7.0 updated FullFrameBlobber, added BlobProcessor and LinearBlobConnector, KHT works now
    
    public var starVersion = "0.7.0" // XXX move this out

    public var basename: String {
        let _basename = "\(self.imageSequenceDirname)-star-v-\(self.starVersion)-\(self.detectionType.rawValue)"
        return _basename.replacingOccurrences(of: ".", with: "_")
    }

    public var outlierOutputDirname: String {
        "\(self.outputPath)/\(self.basename)-outliers"
    }
    
    public func writeJson(named filename: String) {
        
        // write to config json

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]

        do {
            let jsonData = try encoder.encode(self)

            let fullPath = "\(self.outputPath)/\(filename)"
            if fileManager.fileExists(atPath: fullPath) {
                Log.w("cannot write to \(fullPath), it already exists")
            } else {
                Log.i("creating \(fullPath)")                      
                fileManager.createFile(atPath: fullPath, contents: jsonData, attributes: nil)
            }
        } catch {
            Log.e("\(error)")
        }
    }
}

public class Callbacks {
    public init() { }
    
    public var updatable: UpdatableLog?

    public var frameStateChangeCallback: ((FrameAirplaneRemover, FrameProcessingState) -> ())?
    // called for the user to see a frame
    public var frameCheckClosure: ((FrameAirplaneRemover) -> ())?

    // returns the total full size of the image sequence
    public var imageSequenceSizeClosure: ((Int) -> Void)?

}

fileprivate let fileManager = FileManager.default
