import Foundation
import ArgumentParser
import CoreGraphics
import Cocoa
import StarCore

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*

 two modes:
   - extract existing validated outlier group information into a single binary image
     where each non-black pixel is one which is part of some outlier group

   - go over a newly assembled group of outlier groups for a previously validated sequence
     set new outlier groups to paint or not paint based upon their overlap with pixels
     on the validated image produced above

  This will allow for existing validated sequences to be upgraded to newer versions of star
  and to only require a small amount of further validation.  Mostly to mark airplanes which
  were not caught as outlier groups on the previous validation.

  Then we will have a whole lot more validated data with less effort
 */

@main
struct OutlierUpgraderCLI: AsyncParsableCommand {

    @Option(name: [.short, .customLong("input-sequence-dir")], help:"""
        Input file to blob
        """)
    var inputSequenceDir: String
    
    mutating func run() async throws {

        Log.handlers[.console] = ConsoleLogHandler(at: .verbose)

        Log.i("Hello, Cruel World")

        IMAGE_WIDTH = 6000      // XXX XXX XXX
        IMAGE_HEIGHT = 4000     // XXX XXX XXX
        
        let frame_dirs = try fileManager.contentsOfDirectory(atPath: inputSequenceDir)
        for item in frame_dirs {
            if let frameIndex = Int(item),
               let outlierGroups = try await loadOutliers(from: "\(inputSequenceDir)/\(frameIndex)", frameIndex: frameIndex)
            {
                Log.d("got frame \(frameIndex) w/ \(outlierGroups.members.count) outliers")
            }
        }
    }
}

func loadOutliers(from dirname: String, frameIndex: Int) async throws -> OutlierGroups? {
    var outlierGroupsForThisFrame: OutlierGroups?
    
    let startTime = Date().timeIntervalSinceReferenceDate
    var endTime1: Double = 0
    var startTime1: Double = 0
    
    if FileManager.default.fileExists(atPath: dirname) {
        startTime1 = Date().timeIntervalSinceReferenceDate
        outlierGroupsForThisFrame = try await OutlierGroups(at: frameIndex, from: dirname)
        endTime1 = Date().timeIntervalSinceReferenceDate
        Log.i("frame \(frameIndex) loaded from new binary dir")
    } 
    let end_time = Date().timeIntervalSinceReferenceDate
    Log.d("took \(end_time - startTime) seconds to load outlier group data for frame \(frameIndex)")
    Log.i("TIMES \(startTime1 - startTime) - \(endTime1 - startTime1) - \(end_time - endTime1) reading outlier group data for frame \(frameIndex)")
    
    if let _ = outlierGroupsForThisFrame  {
        Log.i("loading frame \(frameIndex) with outlier groups from file")
    } else {
        Log.d("loading frame \(frameIndex)")
    }
    return outlierGroupsForThisFrame
}

fileprivate let fileManager = FileManager.default
