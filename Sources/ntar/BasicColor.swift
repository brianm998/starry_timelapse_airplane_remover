import Foundation

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

// describes basic colors that are both ansi terminal colors and also Pixel values we can use to paint
// test paint values of

enum BasicColor: String {
    case black = "\u{001B}[0;30m"
    case red = "\u{001B}[0;31m"
    case green = "\u{001B}[0;32m"
    case yellow = "\u{001B}[0;33m"
    case blue = "\u{001B}[0;34m"
    case magenta = "\u{001B}[0;35m"
    case cyan = "\u{001B}[0;36m"
    case white = "\u{001B}[0;37m"
    case reset = "\u{001B}[0;0m"
    
    func name() -> String {
        switch self {
        case .black: return "Black"
        case .red: return "Red"
        case .green: return "Green"
        case .yellow: return "Yellow"
        case .blue: return "Blue"
        case .magenta: return "Magenta"
        case .cyan: return "Cyan"
        case .white: return "White"
        case .reset: return "Reset"
        }
    }

    var pixel: Pixel {
        get {
            var pixel = Pixel()
            switch self {
            case .black:
               pixel.red = 0x0000 
               pixel.green = 0x0000
               pixel.blue = 0x0000
            case .red:
               pixel.red = 0xFFFF 
               pixel.green = 0x0000
               pixel.blue = 0x0000
            case .green:
               pixel.red = 0x0000 
               pixel.green = 0xFFFF
               pixel.blue = 0x0000
            case .yellow:
               pixel.red = 0xFFFF 
               pixel.green = 0xFFFF
               pixel.blue = 0x0000
            case .blue: 
               pixel.red = 0x0000 
               pixel.green = 0x0000
               pixel.blue = 0xFFFF
            case .magenta:
               pixel.red = 0xFFFF 
               pixel.green = 0x0000
               pixel.blue = 0xFFFF
            case .cyan:
               pixel.red = 0x0000 
               pixel.green = 0xFFFF
               pixel.blue = 0xFFFF
            case .white:
               pixel.red = 0xFFFF 
               pixel.green = 0xFFFF
               pixel.blue = 0xFFFF
            case .reset:
               pixel.red = 0x0000 
               pixel.green = 0x0000
               pixel.blue = 0x0000
            }
            return pixel
        }
    }
}

func + (left: BasicColor, right: String) -> String {
    return left.rawValue + right
}

func + (left: String, right: BasicColor) -> String {
    return left + right.rawValue
}


