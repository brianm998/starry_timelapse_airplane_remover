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

public actor ProcessedBlobs {
    private var blobs: Set<UInt16> = []

    func getBlobs() -> Set<UInt16> { blobs }
    
    func contains(_ id: UInt16) -> Bool {
        blobs.contains(id)
    }

    func insert(_ id: UInt16) {
        _ = blobs.insert(id)
    }

    func union(with otherSet: ProcessedBlobs) async {
        blobs = blobs.union(await otherSet.getBlobs())
    }
}
