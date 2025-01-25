/*
This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation

// holds a large row major array in a Sendable container
// so that it can be passed around and not re-copied a lot
public final class FrameHolder: Sendable {
    let value: [UInt16]
    let width: Int
    let height: Int

    public init(_ value: [UInt16],
                width: Int,
                height: Int)
    {
        self.value = value
        self.width = width
        self.height = height
    }

    public func value(at x: Int, and y: Int) -> UInt16 {
        let index = y*width+x
        if index < 0 || index >= value.count { return 0 }
        return value[index]
    }
}
