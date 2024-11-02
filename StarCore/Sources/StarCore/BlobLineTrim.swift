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

// trim pixels that are too far from a blobs's line
public actor BlobLineTrim {

    var blobMap: [UInt16: Blob]
    let frameIndex: Int
    
    init(blobMap: [UInt16: Blob], frameIndex: Int) {
        self.frameIndex = frameIndex
        self.blobMap = blobMap
    }
    
    public struct Args: Sendable {
        let minLineLength: Double     // blobs with less line length are not processed
        let minLineFillAmount: Double // blobs with less line fill amount are not processed
        let trimAmount: Double        // trim  pixels further from the line than this

        public init(minLineLength: Double,
                    minLineFillAmount: Double,
                    trimAmount: Double)
        {
            self.minLineLength = minLineLength
            self.minLineFillAmount = minLineFillAmount
            self.trimAmount = trimAmount
        }
    }

    public func process(_ args: Args) async -> [UInt16:Blob] {
        for (_, blob) in blobMap {
            if let lineLength = await blob.lineLength(),
               lineLength > args.minLineLength
            {
                let lineFillAmount = await blob.lineFillAmount()

                if lineFillAmount > args.minLineFillAmount {
                    // XXX trim that shit
                    await blob.lineTrim(by: args.trimAmount)
                }
            }
        }
        return blobMap
    }
}
