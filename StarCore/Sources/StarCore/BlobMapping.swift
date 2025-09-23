import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// indicates that two blobs are linked, i.e. mapped together
public struct BlobMapping: Hashable, Equatable, Sendable {
    let id1: Int32
    let id2: Int32

    public init(_ id1: Int32, _ id2: Int32) {
        // make sure the ids are ordered so (2,1) == (1,2)
        if id1 < id2 {
            self.id1 = id1
            self.id2 = id2
        } else {
            self.id1 = id2
            self.id2 = id1
        }
    }
    
    public func contains(id: Int32) -> Bool { id1 == id || id2 == id }
    
    public static func == (lhs: BlobMapping, rhs: BlobMapping) -> Bool {
        // [a,b] == [a,b]
        if lhs.id1 == rhs.id1,
           lhs.id2 == rhs.id2
        {
            return true
        }
        return false
    }
}
