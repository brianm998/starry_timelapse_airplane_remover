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

// saves the given set of blobs as a 16 bit grayscale image,
// pixel values come from blob id number
class BlobImageSaver {

    // map of all known blobs keyed by blob id
    private var blobMap: [UInt16: Blob]

    // width of the frame
    private let width: Int

    // height of the frame
    private let height: Int

    // what frame in the sequence we're processing
    private let frameIndex: Int

    // a reference for each pixel for each blob it might belong to
    // non zero values reference a blob
    internal var blobRefs: [UInt16]

    // data condensed along the y axis
    // i.e. does any value at y value have an outlier?
    // if so, then yAxis[yValue] != 0
    internal var yAxis: [UInt8]

    public static let outlierTiffFilename = "outliers.tif"
    public static let outlierYAxisTiffFilename = "outliers-y-axis.tif"
    
    init(blobMap: [UInt16: Blob],
         width: Int,
         height: Int,
         frameIndex: Int)
    {
        self.blobMap = blobMap
        self.width = width
        self.height = height
        self.frameIndex = frameIndex

        self.blobRefs = [UInt16](repeating: 0, count: width*height)
        self.yAxis = [UInt8](repeating: 0, count: height)

        for blob in blobMap.values {
            for pixel in blob.pixels {
                let blobRefIndex = pixel.y*width+pixel.x
                blobRefs[blobRefIndex] = blob.id
                yAxis[pixel.y] = 0xFF
            }
        }
    }

    public func save(to dirname: String) {
        // save the blob refs as an image here
        let filename = "\(dirname)/\(BlobImageSaver.outlierTiffFilename)"
        do {
            Log.d("frame \(frameIndex) saving image to \(filename)")
            let blobImage = PixelatedImage(width: width, height: height,
                                           grayscale16BitImageData: blobRefs)
            try blobImage.writeTIFFEncoding(toFilename: filename)
            Log.d("frame \(frameIndex) done saving image to \(filename)")
        } catch {
            Log.e("frame \(frameIndex) error saving image \(filename): \(error)")
        }
        Log.d("frame \(frameIndex) REALLY done saving image to \(filename)")

        let yAxisFilename = "\(dirname)/\(BlobImageSaver.outlierYAxisTiffFilename)"
        do {
            Log.d("frame \(frameIndex) saving image to \(yAxisFilename)")
            let blobImage = PixelatedImage(width: 1, height: height,
                                           grayscale8BitImageData: yAxis)
            try blobImage.writeTIFFEncoding(toFilename: yAxisFilename)
            Log.d("frame \(frameIndex) done saving image to \(yAxisFilename)")
        } catch {
            Log.e("frame \(frameIndex) error saving image \(yAxisFilename): \(error)")
        }

        Log.d("frame \(frameIndex) REALLY done saving y axis image to \(yAxisFilename)")
    }
}
