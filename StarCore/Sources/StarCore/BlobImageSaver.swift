import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// used to save the given set of blobs as a 16 bit grayscale image,
// pixel values come from blob id number
// now just used for these static properites, which will go away once we've
// fully moved away from the outliers.tiff 
public struct BlobImageSaver {

    public static let outlierTiffFilename = "outliers.tif"
    public static let outlierYAxisBinaryFilename = "outliers-y-axis.bin"
    
}
