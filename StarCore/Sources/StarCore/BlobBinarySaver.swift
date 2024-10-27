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

/*
 saves the given set of blobs as a binary file
 UInt16 - number of blobs
 [
   UInt16 - blob id
   UInt16 - blob number of pixels
   [
     UInt16 - pixel x
     UInt16 - pixel y
     UInt16 - pixel intensity
   ]
 ]
*/
public struct BlobBinaryLoader {
    public func load(from dirname: String,
                     with frameIndex: Int) async throws -> [UInt16: Blob]
    {
        let filename = "\(dirname)/\(BlobBinarySaver.outlierBinaryFilename)"
        let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
        let request = URLRequest(url: imageURL as URL)
        let (data, _) = try await URLSession.shared.data(for: request)
        let blobDataArray = data.uInt16Array
        var index = 0
        let numberOfBlobs = blobDataArray[index]
        index += 1
        var blobMap: [UInt16:Blob] = [:]
        for _ in 0..<numberOfBlobs {
            let blob = Blob(frameIndex: frameIndex,
                            with: blobDataArray,
                            atIndex: index)
            index += await blob.persistentDataSizeBytes() / 2
            blobMap[blob.id] = blob
        }
        return blobMap
    }
}

public actor BlobBinarySaver {

    // map of all known blobs keyed by blob id
    private var blobMap: [UInt16: Blob]

    init(blobMap: [UInt16: Blob]) {
        self.blobMap = blobMap
    }

    public static let outlierBinaryFilename = "outliers.bin"
    
    public func save(to dirname: String) async {
        // save the blob refs as an image here
        let filename = "\(dirname)/\(BlobBinarySaver.outlierBinaryFilename)"

        let blobCount = UInt16(blobMap.count)
        var buffer = [blobCount].data

        for (_, blob) in blobMap {
            buffer.append(await blob.persistentDataArray().data)
        }
        
        do {
            if FileManager.default.fileExists(atPath: filename) {
                try FileManager.default.removeItem(atPath: filename) 
            }
            FileManager.default.createFile(atPath: filename,
                                           contents: buffer,
                                           attributes: nil)
        } catch {
            Log.e("error saving binary blobs \(filename): \(error)")
        }
    }
}

