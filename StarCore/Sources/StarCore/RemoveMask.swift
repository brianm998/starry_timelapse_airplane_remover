import Foundation
/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// A square remove mask of opacity levels 
struct RemoveMask {
    let pixels: [Double]        // 0...1
    let size: Int               // both width and height, always square

    let center: Int

    let innerWallSize: Double
    let radius: Double
    
    init(innerWallSize: Double, // from center, opacity 100% throughout
         radius: Double)        // total size, from center
    {
        self.innerWallSize = innerWallSize
        self.radius = radius
        self.center = Int(radius+1)
        self.size = 1 + 2*center
        var pixelArray = [Double](repeating: 0, count: size*size)

        // the length in pixels of the fade window
        let fadeSize = radius - innerWallSize
        
        for x in 0..<size {
            for y in 0..<size {
                let xDiff = Double(x - center)
                let yDiff = Double(y - center)
                let distance = sqrt(xDiff*xDiff + yDiff*yDiff)
                var pixelValue = 0.0
                if distance < innerWallSize {
                    pixelValue = 1
                } else if distance < radius {
                    // how close are we to the inner wall of full opacity?
                    let fadeProgress = distance - innerWallSize
                    pixelValue = (fadeSize-fadeProgress) / fadeSize
                }
                pixelArray[y*size+x] = pixelValue
            }
        }
        self.pixels = pixelArray
    }
}



/// Per-pixel alpha for the whole frame, stored as a 16-bit index into a table of the values the
/// mask can produce instead of a `Double` per pixel (8 bytes a pixel, 337MB at 42MP, against 2).
///
/// A pixel's alpha is always one of the `RemoveMask`'s own values, so nothing is rounded: the
/// subscript returns exactly the `Double` that was stored, and the "keep the larger" update the
/// mask is convolved with can compare indices because the table is sorted ascending. A circular
/// mask has at most about size^2 / 8 distinct values, far under the 65,535 an index holds.
struct RemovalAlphaLevels {
    /// Ascending; entry 0 is 0.0, meaning "not touched".
    let table: [Double]
    private(set) var indices: [UInt16]

    init(mask: RemoveMask, pixelCount: Int) {
        var distinct = Set<Double>(mask.pixels)
        distinct.insert(0)
        self.table = distinct.sorted()
        self.indices = [UInt16](repeating: 0, count: pixelCount)
    }

    /// Nothing to remove: no table, no pixels.
    init() {
        table = [0]
        indices = []
    }

    var isEmpty: Bool { indices.isEmpty }
    var count: Int { indices.count }

    subscript(pixel: Int) -> Double { table[Int(indices[pixel])] }

    /// The table index of `value`, which must be one of the mask's values.
    func level(of value: Double) -> UInt16 {
        // binary search of the sorted table
        var low = 0, high = table.count - 1
        while low < high {
            let mid = (low + high) / 2
            if table[mid] < value { low = mid + 1 } else { high = mid }
        }
        return UInt16(clamping: low)
    }

    /// Raise a pixel to `level` if that is higher than what it has. True when it changed.
    mutating func raise(_ pixel: Int, to level: UInt16) -> Bool {
        if level > indices[pixel] {
            indices[pixel] = level
            return true
        }
        return false
    }
}
