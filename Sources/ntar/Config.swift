import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

func sixteenBitVersion(ofPercentage percentage: Double) -> UInt16 {
    return UInt16((percentage/100)*Double(0xFFFF))
}

@available(macOS 10.15, *) 
struct Config {

    init() {
        self.outputPath = "."
        self.outlierMaxThreshold = 0
        self.outlierMinThreshold = 0
        self.minGroupSize = 0
        self.numConcurrentRenders = 0
        self.test_paint = false
        self.test_paint_output_path = ""
        self.image_sequence_dirname = ""
        self.image_sequence_path = ""
        self.writeOutlierGroupFiles = false

        // XXX 16 bit hardcode
        self.min_pixel_distance = sixteenBitVersion(ofPercentage: outlierMaxThreshold)

        // XXX 16 bit hardcode
        self.max_pixel_distance = sixteenBitVersion(ofPercentage: outlierMinThreshold)
    }

    init(outputPath: String?,
         outlierMaxThreshold: Double,
         outlierMinThreshold: Double,
         minGroupSize: Int,
         numConcurrentRenders: Int,
         test_paint: Bool,
         test_paint_output_path: String,
         imageSequenceName: String,
         imageSequencePath: String,
         writeOutlierGroupFiles: Bool)
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
        self.test_paint = test_paint
        self.test_paint_output_path = test_paint_output_path
        self.image_sequence_dirname = imageSequenceName
        self.image_sequence_path = imageSequencePath
        self.writeOutlierGroupFiles = writeOutlierGroupFiles

        // XXX 16 bit hardcode
        self.min_pixel_distance = sixteenBitVersion(ofPercentage: outlierMaxThreshold)

        // XXX 16 bit hardcode
        self.max_pixel_distance = sixteenBitVersion(ofPercentage: outlierMinThreshold)
    }

    // the base dir under which to create dir(s) for output sequence(s)
    let outputPath: String
    
    // percentage difference between same pixels on different frames to consider an outlier
    let outlierMaxThreshold: Double

    // computed over 16 bits per pixel from the value above
    let min_pixel_distance: UInt16

    // min percentage difference between same pixels on different frames to consider an outlier
    let outlierMinThreshold: Double

    // computed over 16 bits per pixel from the value above
    let max_pixel_distance: UInt16
    
    // groups smaller than this are ignored
    let minGroupSize: Int

    // how many cpu cores should we max out at?
    let numConcurrentRenders: Int

    // write out test paint images
    let test_paint: Bool

    // where to create the test paint output dir
    let test_paint_output_path: String
    
    // the name of the directory containing the input sequence
    let image_sequence_dirname: String

    // where the input image sequence dir lives
    let image_sequence_path: String
    
    // write out individual outlier group images
    let writeOutlierGroupFiles: Bool

    let medium_hough_line_score: Double = 0.4 // close to being a line, not really far
    // how far in each direction do we go when doing final processing?
    let number_final_processing_neighbors_needed = 1 // in each direction

    let final_theta_diff: Double = 10       // how close in theta/rho outliers need to be between frames
    let final_rho_diff: Double = 20        // 20 works

    let center_line_theta_diff: Double = 18 // used in outlier streak detection
    // 25 is too large

    // the minimum outlier group size at the top of the screen
    // smaller outliers at the top are discarded early on
    let min_group_size_at_top = 400
    

    // what percentage of the top of the screen is considered far enough
    // above the horizon to not need really small outlier groups
    // between the bottom and the top of this area, the minimum
    // outlier group size increases
    let upper_sky_percentage: Double = 66 // top 66% of the screen


    // these parameters are used to throw out outlier groups from the
    // initial list to consider.  Smaller groups than this must have
    // a hough score this big or greater to be included.
    let max_must_look_like_line_size: Int = 500
    let max_must_look_like_line_score: Double = 0.25
    let surface_area_to_size_max = 0.5


    let supported_image_file_types = [".tif", ".tiff"] // XXX move this out

    // XXX use this to try to avoid running out of memory somehow
    // maybe determine megapixels of images, and guestimate usage and
    // avoid spawaning too many threads?
    let memory_size_bytes = ProcessInfo.processInfo.physicalMemory
    let memory_size_gigs = ProcessInfo.processInfo.physicalMemory/(1024*1024*1024)

    // used by updatable log
    let progress_bar_length = 50

    var updatable: UpdatableLog?

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

    let ntar_version = "0.1.3"
    
}
