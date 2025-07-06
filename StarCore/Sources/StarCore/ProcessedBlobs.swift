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
    private var blobs: Set<UInt32> = []

    func getBlobs() -> Set<UInt32> { blobs }
    
    func contains(_ id: UInt32) -> Bool {
        blobs.contains(id)
    }

    func contains(_ blob: Blob) -> Bool {
        blobs.contains(blob.id)
    }

    func insert(_ id: UInt32) {
        _ = blobs.insert(id)
    }

    func insert(_ blob: Blob) {
        _ = blobs.insert(blob.id)
    }

    func union(with otherSet: ProcessedBlobs) async {
        blobs = blobs.union(await otherSet.getBlobs())
    }
}

public class ProcessedBlobsSync {
    private var blobs: Set<UInt32> = []

    func getBlobs() -> Set<UInt32> { blobs }
    
    func contains(_ id: UInt32) -> Bool {
        blobs.contains(id)
    }

    func contains(_ blob: Blob) -> Bool {
        blobs.contains(blob.id)
    }

    func insert(_ id: UInt32) {
        _ = blobs.insert(id)
    }

    func insert(_ blob: Blob) {
        _ = blobs.insert(blob.id)
    }

    func union(with otherSet: ProcessedBlobs) async {
        blobs = blobs.union(await otherSet.getBlobs())
    }
}
