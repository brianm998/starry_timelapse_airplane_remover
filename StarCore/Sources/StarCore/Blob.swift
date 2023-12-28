import Foundation
import KHTSwift
import logging

// blobs created by the blobber
                   
public class Blob: CustomStringConvertible {
    public let id: String
    public private(set) var pixels: [SortablePixel]

    public var line: Line?
    
    public var size: Int { pixels.count }

    public var impactCount: Int = 0

    public var description: String  { "Blob id: \(id) size \(size)" }
    
    public func add(pixels newPixels: [SortablePixel]) {
        for pixel in pixels {
            pixel.status = .blobbed(self)
        }
        self.pixels += newPixels
        _intensity = nil
        _boundingBox = nil
    }

    public func add(pixel: SortablePixel) {
        pixel.status = .blobbed(self)
        self.pixels.append(pixel)
        _intensity = nil
        _boundingBox = nil
    }

    private var _intensity: UInt16?
    private var _boundingBox: BoundingBox?
    
    public var intensity: UInt16 {
        if pixels.count == 0 { return 0 }
        if let _intensity = _intensity { return _intensity }
        var max: UInt64 = 0
        for pixel in pixels {
            max += UInt64(pixel.intensity)
        }
        max /= UInt64(pixels.count)
        let ret = UInt16(max)
        _intensity = ret
        return ret
    }
    
    public init(_ pixel: SortablePixel) {
        self.pixels = [pixel]
        self.id = "\(pixel.x) x \(pixel.y)"
    }

    public func makeBackground() {
        for pixel in pixels {
            pixel.status = .background
        }
        pixels = []
        _intensity = nil
        _boundingBox = nil
    }

    public func absorb(_ otherBlob: Blob) -> Bool {
        if self.id != otherBlob.id {
            Log.d("blob \(self.id) absorbing blob \(otherBlob.id)")
            let newPixels = otherBlob.pixels
            for otherPixel in newPixels {
                otherPixel.status = .blobbed(self)
            }
            self.pixels += newPixels
            _intensity = nil
            _boundingBox = nil
            return true
        }
        return false
    }

    public func isIn(matrixElement: ImageMatrixElement,
                     within borderDistance: Double = 0) -> Bool
    {
        self.boundingBox.edgeDistance(to: matrixElement.boundingBox) < borderDistance
    }
    
    public var boundingBox: BoundingBox {
        if let _boundingBox = _boundingBox { return _boundingBox }
        var min_x:Int = Int.max
        var min_y:Int = Int.max
        var max_x:Int = 0
        var max_y:Int = 0

        for pixel in pixels {
            if pixel.x < min_x { min_x = pixel.x }
            if pixel.y < min_y { min_y = pixel.y }
            if pixel.x > max_x { max_x = pixel.x }
            if pixel.y > max_y { max_y = pixel.y }
        }
        let ret = BoundingBox(min: Coord(x: min_x, y: min_y),
                              max: Coord(x: max_x, y: max_y))
        _boundingBox = ret
        return ret
    }

    public var pixelValues: [UInt16] {
        let boundingBox = self.boundingBox
        var ret = [UInt16](repeating: 0, count: boundingBox.size)
        for pixel in pixels {
            ret[(pixel.y-boundingBox.min.y)*boundingBox.width+(pixel.x-boundingBox.min.x)] = pixel.intensity
        }
        return ret
    }
    
    public func outlierGroup(at frameIndex: Int) async -> OutlierGroup {
        // XXX make this pass on the line, if there is one
        await OutlierGroup(name: self.id,
                           size: UInt(self.pixels.count),
                           brightness: UInt(self.intensity),
                           bounds: self.boundingBox,
                           frameIndex: frameIndex,
                           pixels: self.pixelValues,
                           maxPixelDistance: 0xFFFF) // XXX not sure this is used anymore
    }

    // returns minimum distance found 
    public func distanceTo(line: StandardLine) -> Double {
        var min: Double = 1_000_000_000_000
        for pixel in pixels {
            let distance = line.distanceTo(x: pixel.x, y: pixel.y)
            if distance < min { min = distance }
        }
        return min
    }

    public func distanceTo(x: Int, y: Int) -> Double {
        var min: Double = 1_000_000_000_000
        for pixel in pixels {
            let x_diff = Double(x - pixel.x)
            let y_diff = Double(y - pixel.y)
            let distance = sqrt(x_diff*x_diff+y_diff*y_diff)
            if distance < min { min = distance }
        }
        return min
    }
}
