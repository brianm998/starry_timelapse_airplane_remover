/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
//import CoreGraphics
//import Cocoa

class OutlierGroup {
    let name: String
    let size: UInt
    let bounds: BoundingBox
    let brightness: UInt

    var shouldPaint: PaintReason?

    var lines: [Line] = []

    var line: Line { return lines[0] }
    
    var paint_score_from_lines: Double = 0
    var size_score: Double = 0
    var aspect_ratio_score: Double = 0
    var value_score: Double = 0

    init(name: String,
         size: UInt,
         brightness: UInt,
         bounds: BoundingBox)

    {
        self.name = name
        self.size = size
        self.brightness = brightness
        self.bounds = bounds
    }
    
    var score: Double {
        var overall_score =
          size_score +
          aspect_ratio_score + 
          (value_score/100) + 
          paint_score_from_lines
        
        overall_score /= 4
        return overall_score
    }
}
