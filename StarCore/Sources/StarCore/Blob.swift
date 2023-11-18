import Foundation

// blobs created by the blobber
public class Blob {
    public let id: String
    public var pixels: [SortablePixel]

    public var intensity: UInt16 {
        var max: UInt32 = 0
        for pixel in pixels {
            max += UInt32(pixel.intensity)
        }
        max /= UInt32(pixels.count)
        return UInt16(max)
    }
    
    public init(_ pixel: SortablePixel) {
        self.pixels = [pixel]
        self.id = "\(pixel.x) x \(pixel.y)"
    }

    public func absorb(_ otherBlob: Blob) {
        if self.id != otherBlob.id {
            let newPixels = otherBlob.pixels
            for otherPixel in newPixels {
                otherPixel.status = .blobbed(self)
            }
            self.pixels += newPixels
        }
        _boundingBox = nil
    }

    private var _boundingBox: BoundingBox?
    
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
        var ret = [UInt16](repeating: 0, count: boundingBox.width+boundingBox.height)
        for pixel in pixels {
            ret[pixel.y+boundingBox.width+pixel.x] = pixel.intensity
        }
        return ret
    }
    
    public func outlierGroup(at frameIndex: Int) -> OutlierGroup {
        OutlierGroup(name: self.id,
                     size: UInt(self.pixels.count),
                     brightness: UInt(self.intensity),
                     bounds: self.boundingBox,
                     frameIndex: frameIndex,
                     pixels: self.pixelValues,
                     maxPixelDistance: 0xFFFF) // XXX not sure this is used anymore
    }

}
