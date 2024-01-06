import Foundation
import KHTSwift

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


// An iterator that can iterate in an expanding circle around a central point
struct CircularIterator {
    fileprivate let values: [CoordWithDistance]
    let size: Int              // both width and height, always square
    let center: Int
    let radius: Int
    
    init(radius: Int)        // total size, from center
    {
        self.radius = radius
        self.center = Int(radius+1)
        self.size = 1 + 2*center
        var valuesArr: [CoordWithDistance] = []
        let centerCoord = Coord(x: self.center, y: self.center)

        for x in 0..<size {
            for y in 0..<size {
                let coord = Coord(x: x, y: y)
                let distance = coord.distance(from: centerCoord)

                valuesArr.append(CoordWithDistance(coord: coord, distance: distance))
            }
        }
        
        valuesArr.sort { $0.distance < $1.distance }
        self.values = valuesArr
    }

    // iterate circularly around the given x, y point
    func iterate(x: Int, y: Int, _ closure: (Int, Int) -> Bool) {
        for item in values {
            if item.distance <= Double(radius) {
                if closure(item.coord.x - center + x, item.coord.y - center + y) == false {
                    return
                }
            }
        }
    }
}

private struct CoordWithDistance {
    let coord: Coord
    let distance: Double
}
