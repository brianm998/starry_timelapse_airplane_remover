import Foundation
import logging

/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/


// represents a 16 bit per component RGB pixel
public struct Pixel {
    public var value: UInt64
    public let numberOfComponents: Int
    
    public init(numberOfComponents: Int) {
        self.value = 0
        self.numberOfComponents = numberOfComponents
    }

    // merge a list of other pixels together, accounting for 
    public init(merging otherPixels: [Pixel]) {
        self.value = 0
        var red: Double = 0
        var green: Double = 0
        var blue: Double = 0
        var alpha: Double = 0
        var maxNumberOfComponents = 0
        var count: Double = 0
        otherPixels.forEach { otherPixel in
            if otherPixel.numberOfComponents == 3 {
                red += Double(otherPixel.red)
                green += Double(otherPixel.green)
                blue += Double(otherPixel.blue)
                alpha += 0xFFFF
                count += 1
            } else if otherPixel.numberOfComponents == 4 {
                let alphaModifier = Double(otherPixel.alpha) / 0xFFFF
                red += Double(otherPixel.red) * alphaModifier
                green += Double(otherPixel.green) * alphaModifier
                blue += Double(otherPixel.blue) * alphaModifier
                alpha += Double(otherPixel.alpha)
                count += 1
            } else {
                Log.e("unhandled numberOfComponents \(otherPixel.numberOfComponents)")
            }
            if otherPixel.numberOfComponents > maxNumberOfComponents {
                maxNumberOfComponents = otherPixel.numberOfComponents
            }
        }
        self.numberOfComponents = maxNumberOfComponents
        self.red = UInt16(red/count)
        self.green = UInt16(green/count)
        self.blue = UInt16(blue/count)
        if maxNumberOfComponents == 4 {
            self.alpha = UInt16(alpha/count)
        } else {
            self.alpha = 0xFFFF
        }
      
      
    }

    // merge pixel1 in at alpha to pixel2
    // alpha 0 is all pixel 2
    // alpha 1 is all pixel 1
    public init(merging pixel1: Pixel, with pixel2: Pixel, atAlpha alpha: Double) {
        self.value = 0
        var red = UInt32(Double(pixel2.red) * (1-alpha))
        var green = UInt32(Double(pixel2.green) * (1-alpha))
        var blue = UInt32(Double(pixel2.blue) * (1-alpha))

        red += UInt32(Double(pixel1.red) * alpha)
        green += UInt32(Double(pixel1.green) * alpha)
        blue += UInt32(Double(pixel1.blue) * alpha)

        self.numberOfComponents = 3
        self.red = UInt16(red)
        self.green = UInt16(green)
        self.blue = UInt16(blue)
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

    public var intensity: UInt64 {
        UInt64(self.red) +
        UInt64(self.blue) +
        UInt64(self.green)
    }
}
/*
extension Array where Element == Pixel {
    /// Returns the “good” pixels whose intensity is ≤ mean + K·σ.
    func goodPixels(with thresholdFactor: Double = 3.0) -> [Pixel] {
        let n = count
        guard n > 1 else { return self }

        // 1) compute intensities as Doubles
        let intensities = self.map { Double($0.intensity) }

        // 2) mean
        let mean = intensities.reduce(0, +) / Double(n)

        // 3) standard deviation
        let variance = intensities
            .map { pow($0 - mean, 2) }
            .reduce(0, +) / Double(n)
        let stdDev = sqrt(variance)

        // 4) threshold = mean + thresholdFactor·stdDev
        let threshold = mean + thresholdFactor * stdDev

        // 5) keep all pixels with intensity ≤ threshold
        return zip(self, intensities)
            .filter { _, intensity in intensity <= threshold }
            .map { pixel, _ in pixel }
    }
}
*/
