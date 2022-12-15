import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

struct Config {

    init() {
        self.outputPath = "."
        self.outlierMaxThreshold = 0
        self.outlierMinThreshold = 0
        self.minGroupSize = 0
        self.assumeAirplaneSize = 0
        self.numConcurrentRenders = 0
        self.test_paint = false
        self.image_sequence_dirname = ""
        self.image_sequence_path = ""
        self.writeOutlierGroupFiles = false

        // XXX 16 bit hardcode
        self.min_pixel_distance = UInt16((outlierMaxThreshold/100)*Double(0xFFFF))

        // XXX 16 bit hardcode
        self.max_pixel_distance = UInt16((outlierMinThreshold/100)*Double(0xFFFF))
    }

    init(outputPath: String?,
         outlierMaxThreshold: Double,
         outlierMinThreshold: Double,
         minGroupSize: Int,
         assumeAirplaneSize: Int,
         numConcurrentRenders: Int,
         test_paint: Bool,
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
        self.assumeAirplaneSize = assumeAirplaneSize
        self.numConcurrentRenders = numConcurrentRenders
        self.test_paint = test_paint
        self.image_sequence_dirname = imageSequenceName
        self.image_sequence_path = imageSequencePath
        self.writeOutlierGroupFiles = writeOutlierGroupFiles

        self.min_pixel_distance = UInt16((outlierMaxThreshold/100)*Double(0xFFFF)) // XXX 16 bit hardcode

        self.max_pixel_distance = UInt16((outlierMinThreshold/100)*Double(0xFFFF)) // XXX 16 bit hardcode
    }
    
    let outputPath: String
    let outlierMaxThreshold: Double
    let outlierMinThreshold: Double
    let minGroupSize: Int
    let assumeAirplaneSize: Int
    let numConcurrentRenders: Int
    let test_paint: Bool
    let image_sequence_dirname: String
    let image_sequence_path: String
    let writeOutlierGroupFiles: Bool
    let min_pixel_distance: UInt16
    let max_pixel_distance: UInt16
    
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


    let supported_image_file_types = [".tif", ".tiff"] // XXX move this out
}
