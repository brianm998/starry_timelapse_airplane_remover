/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import logging
import Cocoa

public class ImageMatrixElement: Hashable, CustomStringConvertible {
    public let x: Int                  // offset in original image
    public let y: Int
    public let width: Int
    public let height: Int
    
    public var image: NSImage? // don't keep this image around forever
    public var lines: [Line]?
    
    public init(x: Int,
                y: Int,
                width: Int,
                height: Int)
    {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public init(x: Int,
                y: Int,
                image: NSImage)
    {
        self.x = x
        self.y = y
        self.image = image
        self.width = Int(image.size.width)
        self.height = Int(image.size.height)
    }

    public static func == (lhs: ImageMatrixElement, rhs: ImageMatrixElement) -> Bool {
        return lhs.x == rhs.x && lhs.y == rhs.y &&
           lhs.width == rhs.width && lhs.height == rhs.height
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(width)
        hasher.combine(height)
    }
    
    public var description: String { "MatrixElement: [\(x), \(y)] -> [\(width), \(height)]" }
}
