import Foundation
/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// A square paint mask of opacity levels 
struct PaintMask {
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

