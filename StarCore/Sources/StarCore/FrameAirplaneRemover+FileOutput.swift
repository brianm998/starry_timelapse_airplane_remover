import Foundation
import CoreGraphics
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*

 Methods used by the FrameAirplaneRemover to save outliers file
 
 */
extension FrameAirplaneRemover {

    // write out just the OutlierGroupValueMatrix, which just what
    // the decision tree needs, and not very large
    public func writeOutlierValuesCSV() async throws {

        Log.d("frame \(self.frameIndex) writeOutlierValuesCSV")
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            // write out the decision tree value matrix too
            Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1")

            let frameOutlierDir = "\(outputDirname)/\(self.frameIndex)"
            let positiveFilename = "\(frameOutlierDir)/\(OutlierGroupValueMatrix.positiveDataFilename)"
            let negativeFilename = "\(frameOutlierDir)/\(OutlierGroupValueMatrix.negativeDataFilename)"

            // check to see if both of these files exist already
            if fileManager.fileExists(atPath: positiveFilename),
               fileManager.fileExists(atPath: negativeFilename) {
                Log.i("frame \(self.frameIndex) not recalculating outlier values with existing files")
            } else {
                let valueMatrix = OutlierGroupValueMatrix()
                
                if let outliers = self.outlierGroupList() {
                    Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1a \(outliers.count) outliers")
                    let startTime = NSDate().timeIntervalSince1970
                    // XXX start time
                    
                    for (index, outlier) in outliers.enumerated() {
                        if index % 10 == 0 {
                            let duration = NSDate().timeIntervalSince1970 - startTime
                            Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 1b \(index) after \(duration) seconds")
                        }
                        await valueMatrix.append(outlierGroup: outlier)
                    }
                }
                Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 2")

                try valueMatrix.writeCSV(to: frameOutlierDir)
                Log.d("frame \(self.frameIndex) writeOutlierValuesCSV 3")
            }
        }
        Log.d("frame \(self.frameIndex) DONE writeOutlierValuesCSV")
    }

    // write out a directory of individual OutlierGroup binaries
    // for each outlier in this frame
    // large, still not fast, but lots of data
    public func writeOutliersBinary() async {
        if config.writeOutlierGroupFiles,
           let outputDirname = self.outlierOutputDirname
        {
            do {
                try await self.outlierGroups?.write(to: outputDirname)
            } catch {
                Log.e("error \(error)")
            }                
        }
    }
}

fileprivate let fileManager = FileManager.default
