import Foundation
import KHTSwift
import logging

// blobs created by the blobber
                   
public class Blob: CustomStringConvertible {
    public let id: String
    public private(set) var pixels = Set<SortablePixel>()
    public let frameIndex: Int
    
    public var size: Int { pixels.count }

    public var impactCount: Int = 0

    public var description: String  { "Blob id: \(id) size \(size)" }
    
    public func add(pixels newPixels: Set<SortablePixel>) {
        for pixel in pixels {
            pixel.status = .blobbed(self)
        }
        self.pixels = self.pixels.union(newPixels)
        reset()
    }

    public func add(pixel: SortablePixel) {
        pixel.status = .blobbed(self)
        self.pixels.insert(pixel)
        reset()
    }

    private var _intensity: UInt16?
    private var _medianIntensity: UInt16?
    private var _boundingBox: BoundingBox?
    private var _blobImageData: [UInt16]?
    private var _blobLine: Line?

    // XXX this affects the reference point of lines returned !!! XXX
    let blobImageDataBorderSize = 24
    // XXX if this works, need to modify the line returned so its reference point is
    // taken into account, originZeroLine has been modified, does it work?
    
    // a line computed from the pixels, origin is relative to the bounding box
    public var line: Line? {
        if let blobLine = _blobLine { return blobLine }
        
        let blobImageData = self.blobImageData
        
        let pixelImage = PixelatedImage(width: self.boundingBox.width + blobImageDataBorderSize * 2,
                                        height: self.boundingBox.height + blobImageDataBorderSize * 2,
                                        grayscale16BitImageData: blobImageData)

        // XXX XXX XXX
        // write out an image for every blob, slow, but helpful for debugging blob stuff
        //try? pixelImage.writeTIFFEncoding(toFilename: "/tmp/Blob_frame_\(frameIndex)_\(self).png")
        // XXX XXX XXX
        
        if let image = pixelImage.nsImage {
            let lines = kernelHoughTransform(image: image, clusterMinSize: 4)
            if lines.count > 0,
               lines[0].votes > 500 // XXX hardcode to ignore lines without much data behind them
            {
                Log.d("frame \(frameIndex) blob \(self) got \(lines.count) lines from KHT returning \(lines[0]) [\(self.boundingBox.width), \(self.boundingBox.height)]")
                _blobLine = lines[0]
                return lines[0]
            }
        }
        return nil
    }
    
    public var blobImageData: [UInt16] {
        if let blobImageData = _blobImageData { return blobImageData }
        
        var blobImageData = [UInt16](repeating: 0,
                                     count: (self.boundingBox.width+blobImageDataBorderSize*2) *
                                            (self.boundingBox.height+blobImageDataBorderSize*2))
        
        //Log.d("frame \(frameIndex) blob image data with \(pixels.count) pixels")
        
        let minX = self.boundingBox.min.x
        let minY = self.boundingBox.min.y
        for pixel in pixels {
            let imageIndex = (pixel.y - minY + blobImageDataBorderSize)*self.boundingBox.width +
                             (pixel.x - minX + blobImageDataBorderSize)
            //blobImageData[imageIndex] = pixel.intensity
            blobImageData[imageIndex] = 0xFFFF
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

    // trims outlying pixels from the group, especially
    // ones with very few neighboring pixels
    public func fancyLineTrim(by minNeighbors: Int = 3) {
        if let line = self.originZeroLine {
            var newPixels = Set<SortablePixel>()
            
            let standardLine = line.standardLine
            let (average, median, max) = averageMedianMaxDistance(from: line)

            for pixel in pixels {

                let pixelDistance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
                if pixelDistance < 2 {
                    newPixels.insert(pixel)
                } else {

                    let x = pixel.x - self.boundingBox.min.x
                    let y = pixel.y - self.boundingBox.min.y

                    var neighborCount: Int = 0
                    neighborCount += self.hasPixel(x: x-1, y: y-1)
                    neighborCount += self.hasPixel(x: x,   y: y-1)
                    neighborCount += self.hasPixel(x: x+1, y: y-1)
                    neighborCount += self.hasPixel(x: x-1, y: y)
                    neighborCount += self.hasPixel(x: x+1, y: y)
                    neighborCount += self.hasPixel(x: x-1, y: y+1)
                    neighborCount += self.hasPixel(x: x,   y: y+1)
                    neighborCount += self.hasPixel(x: x+1, y: y+1)

                    if pixelDistance < median {
                        if neighborCount > 2 { newPixels.insert(pixel) }
                    } else if neighborCount > 1 {
                        newPixels.insert(pixel)
                    }
                }
            }
            let diff = self.pixels.count - newPixels.count
            self.pixels = newPixels
            Log.d("blog \(self) trimming \(diff) pixels")
            reset()
        }
    }

    private func reset() {
        _intensity = nil
        _medianIntensity = nil
        _boundingBox = nil
        _blobImageData = nil
        _blobLine = nil
        _averageDistanceFromIdealLine = nil
        _membersArray = nil
    }

    private var _membersArray: ([Bool])?
    
    public var membersArray: [Bool] {
        if let _membersArray { return _membersArray }
        let bounds = self.boundingBox
        
        var members = [Bool](repeating: false,
                             count: bounds.width*bounds.height)

        for pixel in pixels {
            let x = pixel.x - self.boundingBox.min.x
            let y = pixel.y - self.boundingBox.min.y
            
            let index = y*bounds.width+x
            if index < 0 || index >= members.count {
                fatalError("bad index \(index) from [\(x), \(y)] and \(self.boundingBox)")
            }
            members[index] = true
        }
        _membersArray = members
        return members
    }
    
    public func neighboringPixelTrim(by minNeighbors: Int = 2) {
        /*
         for each pixel in pixels
         if no other pixels are next to it, discard it
         */

        var trimmedPixels = Set<SortablePixel>()

        for pixel in pixels {
            let x = pixel.x - self.boundingBox.min.x
            let y = pixel.y - self.boundingBox.min.y
            
            var neighborCount: Int = 0
            neighborCount += self.hasPixel(x: x-1, y: y-1)
            neighborCount += self.hasPixel(x: x,   y: y-1)
            neighborCount += self.hasPixel(x: x+1, y: y-1)
            neighborCount += self.hasPixel(x: x-1, y: y)
            neighborCount += self.hasPixel(x: x+1, y: y)
            neighborCount += self.hasPixel(x: x-1, y: y+1)
            neighborCount += self.hasPixel(x: x,   y: y+1)
            neighborCount += self.hasPixel(x: x+1, y: y+1)

            if neighborCount > minNeighbors { trimmedPixels.insert(pixel) }
        }

        if trimmedPixels.count != self.pixels.count {
            Log.d("frame \(frameIndex) blob \(self) DID PIXEL TRIM \(self.pixels.count-trimmedPixels.count) pixels from a start of \(self.pixels.count) pixels")
            self.pixels = trimmedPixels
            reset()
        } else {
            Log.d("frame \(frameIndex) blob \(self) DID NOT PIXEL TRIM ANY PIXELS")
        }
    }

    private func hasPixel(x: Int, y: Int) -> Int {
        if x >= 0,
           y >= 0,
           x < self.boundingBox.width,
           y < self.boundingBox.height,
           self.membersArray[y*self.boundingBox.width+x]
        {
            return 1
        } else {
            return 0
        }
    }
    
    // trims outlying pixels from the group, ones that are not
    // close enough to the ideal line for this group
    public func lineTrim() {
        if let line = self.originZeroLine {
            var newPixels = Set<SortablePixel>()
            
            let standardLine = line.standardLine
            let (average, median, max) = averageMedianMaxDistance(from: line)
            //let maxDistanceFromLine = (average+median)/2 // guess
            let maxDistanceFromLine = (median+max)/2 // guess

            for pixel in pixels {
                let pixelDistance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
                if pixelDistance <= maxDistanceFromLine {
                    newPixels.insert(pixel)
                }
            }
            let diff = self.pixels.count - newPixels.count
            self.pixels = newPixels
            Log.d("blog \(self) trimming \(diff) pixels")
            reset()
        }
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
    
    // assumes line has 0,0 origin
    public func averageDistanceAndLineLength(from line: Line) -> (Double, Double) {
        var minX = Int.max
        var minY = Int.max
        var maxX = 0
        var maxY = 0
        
        let standardLine = line.standardLine
        var distanceSum: Double = 0.0
        for pixel in pixels {

            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
            
            if distance < 4 { // XXX another constant :(
                if pixel.y < minY { minY = pixel.y }
                if pixel.x < minX { minX = pixel.x }
                if pixel.y > maxY { maxY = pixel.y }
                if pixel.x > maxX { maxX = pixel.x }
            }

            distanceSum += distance 
        }
        let xDiff = Double(maxX-minX)
        let yDiff = Double(maxY-minY)
        let totalLength = sqrt(xDiff*xDiff+yDiff*yDiff)
        
        return (distanceSum/Double(pixels.count), totalLength)
    }
    
    public func averageMedianMaxDistance(from line: Line) -> (Double, Double, Double) {
        let standardLine = line.standardLine
        var distanceSum: Double = 0.0
        var distances:[Double] = []
        var max: Double = 0
        for pixel in pixels {
            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
            distanceSum += distance
            distances.append(distance)
            if distance > max { max = distance }
        }
        distances.sort { $0 > $1 }
        if pixels.count == 0 {
            return (0, 0, 0)
        } else {
            let average = distanceSum/Double(pixels.count)
            let median = distances[distances.count/2]
            return (average, median, max)
        }
    }
    
    // a line calculated from the pixels in this blob, if possible
    public var originZeroLine: Line? {
        if let line = self.line {
            let minX = self.boundingBox.min.x - blobImageDataBorderSize
            let minY = self.boundingBox.min.y - blobImageDataBorderSize
            let (ap1, ap2) = line.twoPoints
            return Line(point1: DoubleCoord(x: ap1.x+Double(minX),
                                            y: ap1.y+Double(minY)),
                        point2: DoubleCoord(x: ap2.x+Double(minX),
                                            y: ap2.y+Double(minY)),
                        votes: 0)
        }
        return nil
    }
    
    public var intensity: UInt16 { // mean intensity
        if pixels.count == 0 { return 0 }
        if let _intensity { return _intensity }
        var max: UInt64 = 0
        for pixel in pixels {
            max += UInt64(pixel.intensity)
        }
        max /= UInt64(pixels.count)
        let ret = UInt16(max)
        _intensity = ret
        return ret
    }

    public var medianIntensity: UInt16 {
        if pixels.count == 0 { return 0 }
        if let _medianIntensity { return _medianIntensity }
        let intensities = pixels.map { $0.intensity }
        if intensities.count == 0 {
            _medianIntensity = 0
            return 0
        }
        let ret = intensities.sorted()[intensities.count/2]
        _medianIntensity = ret
        return ret
    }

    public init(_ other: Blob) {
        self.id = other.id
        self.pixels = other.pixels // same reference or new map?
        self.frameIndex = other.frameIndex
        //Log.d("frame \(frameIndex) blob \(self.id) alloc")
    }
    
    public init(_ pixel: SortablePixel, frameIndex: Int) {
        self.pixels = [pixel]
        self.id = "\(pixel.x) x \(pixel.y)"
        self.frameIndex = frameIndex
        //Log.d("frame \(frameIndex) blob \(self.id) alloc")
    }

    public init(frameIndex: Int) {
        self.pixels = []
        self.id = "empty"
        self.frameIndex = frameIndex
        //Log.d("frame \(frameIndex) blob \(self.id) alloc")
    }

    deinit {
        Log.d("frame \(frameIndex) blob \(self.id) dealloc")
    }
    
    public func makeBackground() {
        for pixel in pixels {
            pixel.status = .background
        }
        pixels = []
        reset()
    }

    public func absorb(_ otherBlob: Blob) -> Bool {
        if self.id != otherBlob.id {

            //let selfBeforeSize = self.size
            
            let newPixels = otherBlob.pixels
            for otherPixel in newPixels {
                otherPixel.status = .blobbed(self)
            }
            self.pixels = self.pixels.union(newPixels)
            reset()

            //let selfAfterSize = self.size

            //if selfAfterSize != selfBeforeSize + otherBlob.size {
                // here the blobs overlapped, which isn't supposed to happen
                //Log.w("frame \(frameIndex) blob \(self.id) size \(selfBeforeSize) -> \(selfAfterSize) absorbed blob \(otherBlob.id) size \(otherBlob.size)")
        //} else {
                //Log.d("frame \(frameIndex) blob \(self.id) size \(selfBeforeSize) -> \(selfAfterSize) absorbed blob \(otherBlob.id) size \(otherBlob.size)")
          //  }
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
        if let _boundingBox { return _boundingBox }
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
                     pixels: self.pixelValues)
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
                
                // new blobs distance from its own ideal line
                let newBlobAvg = newBlob.averageDistance(from: newLine)

                // self distance from newBlobs ideal line
                let selfAvg = self.averageDistance(from: newLine)

                // otherBlob distance from newBlobs ideal line
                let otherBlobAvg = otherBlob.averageDistance(from: newLine)

                //Log.d("frame \(frameIndex) blob \(self) avg \(selfAvg) otherBlob \(otherBlob) avg \(otherBlobAvg) newBlobAvg \(newBlobAvg)")

                let distance = self.boundingBox.edgeDistance(to: otherBlob.boundingBox)

                //var fudge: Double = -1.44 // XXX constant
                var fudge: Double = -3 // XXX constant
                //var fudge: Double = -0.44 // XXX constant
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
                    Log.v("frame \(frameIndex) NOT adding new absorbed blob \(newBlob) from \(self) and \(otherBlob) because something is wrong in this calculation: fudge \(fudge) distance \(distance) - \(newBlobAvg) < \(otherBlobAvg) && < \(selfAvg) && < \(self.averageDistanceFromIdealLine) && < \(otherBlob.averageDistanceFromIdealLine)")
                }
            } else {
               // Log.i("frame \(frameIndex) blob \(newBlob) has no line")
            }
        } else {
           // Log.i("frame \(frameIndex) blob \(newBlob) failed to absorb blob (self)")
        }
        return nil
    }

    public func lineMergeV2(with otherBlob: Blob) -> Blob? {

        let startTime = NSDate().timeIntervalSince1970
        Log.d("frame \(frameIndex) \(self) lineMergeV2 with: \(otherBlob)")
        
        // first clone self
        let newBlob = Blob(self)

        var ret: Blob?

        // then see if we can absorb the other blob
        if newBlob.absorb(otherBlob) {

            // make sure this new blob has an ideal line detected
            if let newLine = newBlob.originZeroLine {

                // new blobs distance from its own ideal line
                let newBlobAvg = newBlob.averageDistance(from: newLine)

                // self distance from its own ideal line
                let selfAvg = self.averageDistance(from: newLine)

                // otherBlob distance from its own ideal line
                let otherBlobIdealAvg = otherBlob.averageDistanceFromIdealLine

                // otherBlob distance from newBlobs ideal line
                let otherBlobAvg = otherBlob.averageDistance(from: newLine)

                let minimumAvgDist = Double(self.size)/2
                
                Log.d("frame \(frameIndex) blob \(self) avg \(selfAvg) otherBlob \(otherBlob) avg \(otherBlobAvg) newBlobAvg \(newBlobAvg)")

                let distance = self.boundingBox.edgeDistance(to: otherBlob.boundingBox)

                var fudge: Double = 3 // XXX constant

                // this new blob needs to be closer to its own line than anything else
                if otherBlobAvg < otherBlobIdealAvg+fudge, // is the other blob closer to this line than its own?
                   newBlobAvg < selfAvg+fudge,
                   selfAvg < minimumAvgDist,
                   selfAvg*2 < newBlobAvg // XXX constant to keep smashing from killing the blob avg
                {
                    // only add the new blob if the line score is better
                    // than that of the separate blobs on both the new
                    // blob line, and also their own ideal lines

                    Log.d("frame \(frameIndex) adding new absorbed blob \(newBlob) from \(self) and \(otherBlob) because \(otherBlobAvg) < \(otherBlobAvg+fudge) && \(newBlobAvg) < \(selfAvg+fudge) && \(selfAvg) < \(minimumAvgDist) && \(selfAvg*2) < \(newBlobAvg) from \(newLine)")

                    ret = newBlob
                } else {
                    Log.v("frame \(frameIndex) NOT adding new absorbed blob \(newBlob) from \(self) and \(otherBlob) because \(otherBlobAvg) > \(otherBlobAvg+fudge) || \(newBlobAvg) > \(selfAvg+fudge) || \(selfAvg) > \(minimumAvgDist) || \(selfAvg*2) > \(newBlobAvg) from \(newLine)")
                }
            } else {
                Log.i("frame \(frameIndex) blob \(newBlob) has no line")
            }
        } else {
            Log.i("frame \(frameIndex) blob \(newBlob) failed to absorb blob (self)")
        }
        let endTime = NSDate().timeIntervalSince1970
        Log.d("frame \(frameIndex) \(self) lineMergeV2 with: \(otherBlob) after \(endTime - startTime) seconds, ret = \(ret)")
        return ret
    }
}
