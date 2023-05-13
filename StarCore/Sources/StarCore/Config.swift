import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

func sixteenBitVersion(ofPercentage percentage: Double) -> UInt16 {
    return UInt16((percentage/100)*Double(0xFFFF))
}

public struct Config: Codable {

    public init() {
        self.outputPath = "."
        self.outlierMaxThreshold = 0
        self.outlierMinThreshold = 0
        self.minGroupSize = 0
        self.numConcurrentRenders = 0
        self.image_sequence_dirname = ""
        self.image_sequence_path = ""
        self.writeOutlierGroupFiles = false
        self.writeFramePreviewFiles = false
        self.writeFrameProcessedPreviewFiles = false
        self.writeFrameThumbnailFiles = false

        // XXX 16 bit hardcode
        self.min_pixel_distance = sixteenBitVersion(ofPercentage: outlierMaxThreshold)

        // XXX 16 bit hardcode
        self.max_pixel_distance = sixteenBitVersion(ofPercentage: outlierMinThreshold)
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
                outlierMaxThreshold: Double,
                outlierMinThreshold: Double,
                minGroupSize: Int,
                numConcurrentRenders: Int,
                imageSequenceName: String,
                imageSequencePath: String,
                writeOutlierGroupFiles: Bool,
                writeFramePreviewFiles: Bool,
                writeFrameProcessedPreviewFiles: Bool,
                writeFrameThumbnailFiles: Bool)
    {
        if let outputPath = outputPath {
            self.outputPath = outputPath
        } else {
            self.outputPath = "."
        }
        self.outlierMaxThreshold = outlierMaxThreshold
        self.outlierMinThreshold = outlierMinThreshold
        self.minGroupSize = minGroupSize
        self.numConcurrentRenders = numConcurrentRenders
        self.image_sequence_dirname = imageSequenceName
        self.image_sequence_path = imageSequencePath
        self.writeOutlierGroupFiles = writeOutlierGroupFiles
        self.writeFramePreviewFiles = writeFramePreviewFiles
        self.writeFrameProcessedPreviewFiles = writeFrameProcessedPreviewFiles
        self.writeFrameThumbnailFiles = writeFrameThumbnailFiles

        // XXX 16 bit hardcode
        self.min_pixel_distance = sixteenBitVersion(ofPercentage: outlierMaxThreshold)

        // XXX 16 bit hardcode
        self.max_pixel_distance = sixteenBitVersion(ofPercentage: outlierMinThreshold)
        TaskRunner.maxConcurrentTasks = UInt(numConcurrentRenders)
    }

    // the base dir under which to create dir(s) for output sequence(s)
    public var outputPath: String
    
    // percentage difference between same pixels on different frames to consider an outlier
    public var outlierMaxThreshold: Double

    // computed over 16 bits per pixel from the value above
    public var min_pixel_distance: UInt16

    // min percentage difference between same pixels on different frames to consider an outlier
    public var outlierMinThreshold: Double

    // computed over 16 bits per pixel from the value above
    public var max_pixel_distance: UInt16
    
    // groups smaller than this are ignored
    public var minGroupSize: Int

    // how many cpu cores should we max out at?
    public var numConcurrentRenders: Int

    // the name of the directory containing the input sequence
    public var image_sequence_dirname: String

    // where the input image sequence dir lives
    public var image_sequence_path: String
    
    // write out individual outlier group images
    public var writeOutlierGroupFiles: Bool

    // write out a preview file for each frame
    public var writeFramePreviewFiles: Bool

    // write out a processed preview file for each frame
    public var writeFrameProcessedPreviewFiles: Bool

    // write out a small thumbnail preview file for each frame
    public var writeFrameThumbnailFiles: Bool

    // how far in each direction do we go when doing final processing?
    public var number_final_processing_neighbors_needed = 5 // in each direction

    // the minimum outlier group size at the top of the screen
    // smaller outliers at the top are discarded early on
    public var min_group_size_at_top = 400
    

    // what percentage of the top of the screen is considered far enough
    // above the horizon to not need really small outlier groups
    // between the bottom and the top of this area, the minimum
    // outlier group size increases
    public var upper_sky_percentage: Double = 66 // top 66% of the screen

    public var supported_image_file_types = [".tif", ".tiff"] // XXX move this out

    // XXX use this to try to avoid running out of memory somehow
    // maybe determine megapixels of images, and guestimate usage and
    // avoid spawaning too many threads?
    public var memory_size_bytes = ProcessInfo.processInfo.physicalMemory
    public var memory_size_gigs = ProcessInfo.processInfo.physicalMemory/(1024*1024*1024)

    // used by updatable log
    public var progress_bar_length = 50

    public var preview_width: Int = default_preview_width
    public var preview_height: Int = default_preview_height

    // XXX try making these larger now that video plays better
    public static var default_preview_width: Int = 1617 // 1080p in 4/3 aspect ratio
    public static var default_preview_height: Int = 1080
    
    public var thumbnail_width: Int = default_thumbnail_width
    public var thumbnail_height: Int = default_thumbnail_height

    public static var default_thumbnail_width: Int = 80
    public static var default_thumbnail_height: Int = 60
    
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

    public var star_version = "0.3.3" // XXX move this out

    public func writeJson(named filename: String) {
        
            // write to config json

            let encoder = JSONEncoder()
            encoder.outputFormatting = .prettyPrinted

            do {
                let json_data = try encoder.encode(self)

                let full_path = "\(self.outputPath)/\(filename)"
                if file_manager.fileExists(atPath: full_path) {
                    Log.w("cannot write to \(full_path), it already exists")
                } else {
                    Log.i("creating \(full_path)")                      
                    file_manager.createFile(atPath: full_path, contents: json_data, attributes: nil)
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
    public var frameCheckClosure: ((FrameAirplaneRemover) async -> ())?

    // called by the final processor to keep running when user is checking frames
    public var countOfFramesToCheck: (() async -> Int)?

    // returns the total full size of the image sequence
    public var imageSequenceSizeClosure: ((Int) -> Void)?

}

fileprivate let file_manager = FileManager.default