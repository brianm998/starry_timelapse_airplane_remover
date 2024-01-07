import Foundation
import KHTSwift
import logging

// blobs created by the blobber
                   
public class Blob: CustomStringConvertible {
    public let id: String
    public private(set) var pixels: [SortablePixel]
    public let frameIndex: Int
    
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
        _blobImageData = nil
        _blobLine = nil
        _averageDistanceFromIdealLine = nil
    }

    public func add(pixel: SortablePixel) {
        pixel.status = .blobbed(self)
        self.pixels.append(pixel)
        _intensity = nil
        _boundingBox = nil
        _blobImageData = nil
        _blobLine = nil
        _averageDistanceFromIdealLine = nil
    }

    private var _intensity: UInt16?
    private var _boundingBox: BoundingBox?
    private var _blobImageData: [UInt16]?
    private var _blobLine: Line?

    // a line computed from the pixels, origin is relative to the bounding box
    public var line: Line? {
        if let blobLine = _blobLine { return blobLine }
        
        let blobImageData = self.blobImageData
        
        let pixelImage = PixelatedImage(width: self.boundingBox.width,
                                        height: self.boundingBox.height,
                                        grayscale16BitImageData: blobImageData)

        if let image = pixelImage.nsImage {
            let lines = kernelHoughTransform(image: image, clusterMinSize: 4)
            //Log.d("frame \(frameIndex) blob \(self) got \(lines.count) lines from KHT")
            if lines.count > 0 {
                _blobLine = lines[0]
                return lines[0]
            }
        }
        return nil
    }
    
    public var blobImageData: [UInt16] {
        if let blobImageData = _blobImageData { return blobImageData }
        
        var blobImageData = [UInt16](repeating: 0,
                                     count: self.boundingBox.width*self.boundingBox.height)
        
        //Log.d("frame \(frameIndex) blob image data with \(pixels.count) pixels")
        
        let minX = self.boundingBox.min.x
        let minY = self.boundingBox.min.y
        for pixel in pixels {
            let imageIndex = (pixel.y - minY)*self.boundingBox.width + (pixel.x - minX)
            blobImageData[imageIndex] = 0xFFFF//pixel.intensity
        }

        _blobImageData = blobImageData
        return blobImageData
    }

    private var _averageDistanceFromIdealLine: Double? 
    
    public var averageDistanceFromIdealLine: Double {
        if let averageDistanceFromIdealLine = _averageDistanceFromIdealLine {
            return averageDistanceFromIdealLine
        }
        if let line = self.originZeroLine {
            let ret = averageDistance(from: line)
            _averageDistanceFromIdealLine = ret
            return ret
        }
        //Log.d("frame \(frameIndex) blob \(self) averageDistanceFromIdealLine has no lines :(")
        _averageDistanceFromIdealLine = 420420420
        return 420420420
    }

    // assumes line has 0,0 origin
    public func averageDistance(from line: Line) -> Double {
        let standardLine = line.standardLine
        var distanceSum: Double = 0.0
        for pixel in pixels {
            distanceSum += standardLine.distanceTo(x: pixel.x, y: pixel.y)
        }
        return distanceSum/Double(pixels.count)
    }
    
    // a line calculated from the pixels in this blob, if possible
    public var originZeroLine: Line? {
        if let line = self.line {
            let minX = self.boundingBox.min.x
            let minY = self.boundingBox.min.y
            let (ap1, ap2) = line.twoPoints
            return Line(point1: DoubleCoord(x: ap1.x+Double(minX),
                                            y: ap1.y+Double(minY)),
                        point2: DoubleCoord(x: ap2.x+Double(minX),
                                            y: ap2.y+Double(minY)),
                        votes: 0)
        }
        return nil
    }
    
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

    public init(_ other: Blob) {
        self.id = other.id
        self.pixels = other.pixels
        self.frameIndex = other.frameIndex
    }
    
    public init(_ pixel: SortablePixel, frameIndex: Int) {
        self.pixels = [pixel]
        self.id = "\(pixel.x) x \(pixel.y)"
        self.frameIndex = frameIndex
    }

    public init(frameIndex: Int) {
        self.pixels = []
        self.id = "empty"
        self.frameIndex = frameIndex
    }

    public func makeBackground() {
        for pixel in pixels {
            pixel.status = .background
        }
        pixels = []
        _intensity = nil
        _boundingBox = nil
        _blobImageData = nil
        _blobLine = nil
        _averageDistanceFromIdealLine = nil
    }

    public func absorb(_ otherBlob: Blob) -> Bool {
        if self.id != otherBlob.id {
            //Log.d("frame \(frameIndex) blob \(self.id) absorbing blob \(otherBlob.id)")
            let newPixels = otherBlob.pixels
            for otherPixel in newPixels {
                otherPixel.status = .blobbed(self)
            }
            self.pixels += newPixels
            _intensity = nil
            _boundingBox = nil
            _blobImageData = nil
            _blobLine = nil
            _averageDistanceFromIdealLine = nil
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

        if pixels.count == 0 {
             min_x = 0
             min_y = 0
        } else {
            for pixel in pixels {
                if pixel.x < min_x { min_x = pixel.x }
                if pixel.y < min_y { min_y = pixel.y }
                if pixel.x > max_x { max_x = pixel.x }
                if pixel.y > max_y { max_y = pixel.y }
            }
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

    // a point close to the center of this blob if it's a line, relative to its boundingBox
    public var centralLineCoord: DoubleCoord? {
        let center = self.boundingBox.centerDouble
        if let line = self.line {
            let standardLine = line.standardLine
            
            switch line.iterationOrientation {
            case .horizontal:
                return DoubleCoord(x: center.x,
                                   y: standardLine.y(forX: Double(center.x)))
            case .vertical:
                return DoubleCoord(x: standardLine.x(forY: Double(center.y)),
                                   y: center.y)
            }
        }
        return nil
    }
        
    // a point close to the center of this blob if it's a line, with origin zero 
    public var originZeroCentralLineCoord: DoubleCoord? {
        let center = self.boundingBox.centerDouble
        if let line = self.originZeroLine {
            let standardLine = line.standardLine
            
            switch line.iterationOrientation {
            case .horizontal:
                return DoubleCoord(x: center.x,
                                   y: standardLine.y(forX: Double(center.x)))
            case .vertical:
                return DoubleCoord(x: standardLine.x(forY: Double(center.y)),
                                   y: center.y)
            }
        }
        return nil
    }
        
    public func outlierGroup(at frameIndex: Int) -> OutlierGroup {
        // XXX make this pass on the line, if there is one
        OutlierGroup(name: self.id,
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

    // returns a merged blob, if and only if the combined blob
    // is closer to being a line when combined
    // than when the blobs are separate 
    public func lineMerge(with otherBlob: Blob) -> Blob? {

        // first clone self
        let newBlob = Blob(self)

        // then see if we can absorb the other blob
        if newBlob.absorb(otherBlob) {

            // make sure this new blob has an ideal line detected
            if let newLine = newBlob.originZeroLine {


                /*

                 averageDistance(from: ) is expecting a line in the bounding box of the blob

                 we're using the same line with different reference frames

                 need to update this to translate lines appropriately when measuring
                 the distance of the pixels in a blob to it.

                 right now it's a mess because that's not the case
                 
                 */
                
                // new blobs distance from its own ideal line
                let newBlobAvg = newBlob.averageDistance(from: newLine)

                // self distance from newBlobs ideal line
                let selfAvg = self.averageDistance(from: newLine)

                // otherBlob distance from newBlobs ideal line
                let otherBlobAvg = otherBlob.averageDistance(from: newLine)

                //Log.d("frame \(frameIndex) blob \(self) avg \(selfAvg) otherBlob \(otherBlob) avg \(otherBlobAvg) newBlobAvg \(newBlobAvg)")

                let distance = self.boundingBox.edgeDistance(to: otherBlob.boundingBox)

                var fudge: Double = -1.44 // XXX constant
/*
                if distance < 20 { // XXX constants
                    fudge = -1.44
                }
  */              
                // this new blob needs to be closer to its own line than anything else
                if newBlobAvg+fudge < otherBlobAvg,
                   newBlobAvg+fudge < selfAvg,
                   newBlobAvg+fudge < self.averageDistanceFromIdealLine,
                   newBlobAvg+fudge < otherBlob.averageDistanceFromIdealLine
                {
                    // only add the new blob if the line score is better
                    // than that of the separate blobs on both the new
                    // blob line, and also their own ideal lines
                    Log.d("frame \(frameIndex) adding new absorbed blob \(newBlob) from \(self) and \(otherBlob) because \(newBlobAvg) < \(otherBlobAvg) && < \(selfAvg) && < \(self.averageDistanceFromIdealLine) && < \(otherBlob.averageDistanceFromIdealLine)")

                    return newBlob
                } else {
                    Log.d("frame \(frameIndex) NOT adding new absorbed blob \(newBlob) from \(self) and \(otherBlob) because something is wrong in this calculation: fudge \(fudge) distance \(distance) - \(newBlobAvg) < \(otherBlobAvg) && < \(selfAvg) && < \(self.averageDistanceFromIdealLine) && < \(otherBlob.averageDistanceFromIdealLine)")
                }
            } else {
                Log.i("frame \(frameIndex) blob \(newBlob) has no line")
            }
        } else {
            Log.i("frame \(frameIndex) blob \(newBlob) failed to absorb blob (self)")
        }
        return nil
    }
}
