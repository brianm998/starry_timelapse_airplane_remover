import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


// A square paint mask of opacity levels 
struct CircularMask {
    let values: [Bool]         // row major indexed
    let size: Int              // both width and height, always square
    let center: Int
    let radius: Int
    
    init(radius: Int)        // total size, from center
    {
        self.radius = radius
        self.center = Int(radius+1)
        self.size = 1 + 2*center
        var valuesArr = [Bool](repeating:  false, count: size*size)

        for x in 0..<size {
            for y in 0..<size {
                let xDiff = Double(x - center)
                let yDiff = Double(y - center)
                let distance = sqrt(xDiff*xDiff + yDiff*yDiff)
                valuesArr[y*size+x] = distance < Double(radius)
            }
        }
        self.values = valuesArr
    }

    func iterate(_ closure: (Int, Int) -> Void) {
        for x in 0..<size {
            for y in 0..<size {
                if values[y*size+x] {
                    closure(x, y)
                }
            }
        }
    }
}
