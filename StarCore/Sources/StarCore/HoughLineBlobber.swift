import Foundation
import CoreGraphics
import Cocoa
import logging


/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*
 A blobber that blobbs along hough lines
 
 */
public class HoughLineBlobber: AbstractBlobber {

    let houghLines: [MatrixElementLine]
    
    public init(imageWidth: Int,
                imageHeight: Int,
                pixelData: [UInt16],
                frameIndex: Int,
                neighborType: NeighborType,
                contrastMin: Double,
                houghLines: [MatrixElementLine])
    {
        self.houghLines = houghLines
        
        super.init(imageWidth: imageWidth,
                   imageHeight: imageHeight,
                   pixelData: pixelData,
                   frameIndex: frameIndex,
                   neighborType: neighborType,
                   contrastMin: contrastMin)

        // XXX need to actually blob here

        /*

         This blobber will iterate over each hough line in order of highest voted line first

         need to iterate on each point of the line between ends of the matrix element

         if the pixel on the line is bright enough, then simply create a blob there.
         perhaps restrict the blob to a certain distance from the line we're iterating on

         if the pixel on the line is dimmer, apply edge detection by iterating
         again 90 degrees orthogonal to the line, for a small number of pixels, like 10-20.

         

         
         
         */
    }
}
