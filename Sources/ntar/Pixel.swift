import Foundation

public struct Pixel {
    public var value: UInt64

    public init() {
        self.value = 0
    }

    public init(merging otherPixels: [Pixel]) {
        self.value = 0
        var red: UInt32 = 0
        var green: UInt32 = 0
        var blue: UInt32 = 0
        otherPixels.forEach { otherPixel in
            red += UInt32(otherPixel.red)
            green += UInt32(otherPixel.green)
            blue += UInt32(otherPixel.blue)
        }
        let count = UInt32(otherPixels.count)
        self.red = UInt16(red/count)
        self.green = UInt16(green/count)
        self.blue = UInt16(blue/count)
    }
    
    public func difference(from otherPixel: Pixel) -> Int32 {
        //print("self \(self.description) other \(otherPixel.description)")
        let red = (Int32(self.red) - Int32(otherPixel.red))
        let green = (Int32(self.green) - Int32(otherPixel.green))
        let blue = (Int32(self.blue) - Int32(otherPixel.blue))

        return max(red + green + blue / 3, max(red, max(green, blue)))
    }

    
    public var description: String {
        return "Pixel: r: '\(self.red)' g: '\(self.green)' b: '\(self.blue)'"
    }
    
    public var red: UInt16 {
        get {
            return UInt16(value & 0xFFFF)
        } set {
            value = UInt64(newValue) | (value & 0xFFFFFFFFFFFF0000)
        }
    }
    
    public var green: UInt16 {
        get {
            return UInt16((value >> 16) & 0xFFFF)
        } set {
            value = (UInt64(newValue) << 16) | (value & 0xFFFFFFFF0000FFFF)
        }
    }
    
    public var blue: UInt16 {
        get {
            return UInt16((value >> 32) & 0xFFFF)
        } set {
            value = (UInt64(newValue) << 32) | (value & 0xFFFF0000FFFFFFFF)
        }
    }
    
    public var alpha: UInt16 {
        get {
            return UInt16((value >> 48) & 0xFFFF)
        } set {
            value = (UInt64(newValue) << 48) | (value & 0x0000FFFFFFFFFFFF)
        }
    }
}
