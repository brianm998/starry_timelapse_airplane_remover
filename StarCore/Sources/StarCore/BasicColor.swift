import Foundation

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

// describes basic colors that are both ansi terminal colors and also Pixel values we can use to paint
// test paint values of

public enum BasicColor: String {
    case black = "\u{001B}[0;30m"
    case red = "\u{001B}[0;31m"
    case green = "\u{001B}[0;32m"
    case yellow = "\u{001B}[0;33m"
    case blue = "\u{001B}[0;34m"
    case magenta = "\u{001B}[0;35m"
    case cyan = "\u{001B}[0;36m"
    case white = "\u{001B}[0;37m"
    case reset = "\u{001B}[0;0m"

    case brightBlack = "\u{001b}[30;1m"
    case brightRed = "\u{001b}[31;1m"
    case brightGreen = "\u{001b}[32;1m"
    case brightYellow = "\u{001b}[33;1m"
    case brightBlue = "\u{001b}[34;1m"
    case brightMagenta = "\u{001b}[35;1m"
    case brightCyan = "\u{001b}[36;1m"
    case brightWhite = "\u{001b}[37;1m"
    
    public func name() -> String {
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
        case .brightBlack: return "Bright Black"
        case .brightRed: return "Bright Red"
        case .brightGreen: return "Bright Green"
        case .brightYellow: return "Bright Yellow"
        case .brightBlue: return "Bright Blue"
        case .brightMagenta: return "Bright Magenta"
        case .brightCyan: return "Bright Cyan"
        case .brightWhite: return "Bright White"
        }
    }

    public var pixel: Pixel {
        get {
            var pixel = Pixel()
            switch self {
            case .black:
               pixel.red = 0x0000 
               pixel.green = 0x0000
               pixel.blue = 0x0000
            case .red:
               pixel.red = 0xBBBB 
               pixel.green = 0x0000
               pixel.blue = 0x0000
            case .green:
               pixel.red = 0x0000 
               pixel.green = 0xBBBB
               pixel.blue = 0x0000
            case .yellow:
               pixel.red = 0xBBBB 
               pixel.green = 0xBBBB
               pixel.blue = 0x0000
            case .blue: 
               pixel.red = 0x0000 
               pixel.green = 0x0000
               pixel.blue = 0xBBBB
            case .magenta:
               pixel.red = 0xBBBB 
               pixel.green = 0x0000
               pixel.blue = 0xBBBB
            case .cyan:
               pixel.red = 0x0000 
               pixel.green = 0xBBBB
               pixel.blue = 0xBBBB
            case .white:
               pixel.red = 0xBBBB 
               pixel.green = 0xBBBB
               pixel.blue = 0xBBBB
            case .reset:
               pixel.red = 0x0000 
               pixel.green = 0x0000
               pixel.blue = 0x0000

            case .brightBlack:
               pixel.red = 0x3333
               pixel.green = 0x3333
               pixel.blue = 0x3333
            case .brightRed:
               pixel.red = 0xFFFF 
               pixel.green = 0x0000
               pixel.blue = 0x0000
            case .brightGreen:
               pixel.red = 0x0000 
               pixel.green = 0xFFFF
               pixel.blue = 0x0000
            case .brightYellow:
               pixel.red = 0xFFFF 
               pixel.green = 0xFFFF
               pixel.blue = 0x0000
            case .brightBlue:
               pixel.red = 0x0000 
               pixel.green = 0x0000
               pixel.blue = 0xFFFF
            case .brightMagenta:
               pixel.red = 0xFFFF 
               pixel.green = 0x0000
               pixel.blue = 0xFFFF
            case .brightCyan:
               pixel.red = 0x0000 
               pixel.green = 0xFFFF
               pixel.blue = 0xFFFF
            case .brightWhite:
               pixel.red = 0xFFFF 
               pixel.green = 0xFFFF
               pixel.blue = 0xFFFF
            }
            return pixel
        }
    }
}

public func + (left: BasicColor, right: String) -> String {
    return left.rawValue + right
}

public func + (left: String, right: BasicColor) -> String {
    return left + right.rawValue
}


