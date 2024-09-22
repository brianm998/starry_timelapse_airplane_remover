import Foundation
import KHTSwift
import logging

/*
 blobs are created by the blobber

 blobs are the first step in finding pixels that we may want to replace.

 once filtered and refined a bunch, each blob is promoted to an OutlierGroup,
 for further processing and classification.

 blobs can grow in size, and be combined with other blobs.
 */

public struct CodableBlob: Codable,
                           Sendable
{
    public let id: UInt16
    public let pixels: Set<SortablePixel>
    public let frameIndex: Int

    enum CodingKeys: String, CodingKey {
        case id
        case pixels
        case frameIndex
    }

    public init(_ other: CodableBlob) {
        self.id = other.id
        self.pixels = other.pixels // same reference or new map?
        self.frameIndex = other.frameIndex
        //Log.d("frame \(frameIndex) blob \(self.id) alloc")
    }

    public init(id: UInt16, frameIndex: Int) {
        self.id = id
        self.frameIndex = frameIndex
        self.pixels = Set<SortablePixel>()
    }
    
    public init(_ pixel: StatusPixel, id: UInt16, frameIndex: Int) {
        self.pixels = [pixel._pixel]
        self.id = id
        self.frameIndex = frameIndex
        //Log.d("frame \(frameIndex) blob \(self.id) alloc")
    }

    public init(_ pixels: Set<StatusPixel>, id: UInt16, frameIndex: Int) {
        self.pixels = Set(pixels.map { $0._pixel })
        self.id = id
        self.frameIndex = frameIndex
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pixels = try values.decode(Set<SortablePixel>.self, forKey: .pixels)
        id = try values.decode(UInt16.self, forKey: .id)
        frameIndex = try values.decode(Int.self, forKey: .frameIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(pixels, forKey: .pixels)
        try container.encode(id, forKey: .id)
        try container.encode(frameIndex, forKey: .frameIndex)
    }
}

public actor Blob: CustomStringConvertible,
                   Hashable
{
    public let id: UInt16
    public let frameIndex: Int
    public var pixels: Set<StatusPixel> = []

    public func getPixels() -> Set<StatusPixel> { pixels }

    public func codableBlob() -> CodableBlob {
        CodableBlob(pixels, id: id, frameIndex: frameIndex)
    }
    
    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    public init(_ pixels: Set<StatusPixel>, id: UInt16, frameIndex: Int) {
        self.pixels = pixels
        self.id = id
        self.frameIndex = frameIndex
    }
    
    public init(id: UInt16, frameIndex: Int) {
        self.id = id
        self.frameIndex = frameIndex
    }
    
    public init(_ pixel: StatusPixel, id: UInt16, frameIndex: Int) {
        self.pixels = [ pixel ]
        self.id = id
        self.frameIndex = frameIndex
    }
    
    public init(_ codableBlob: CodableBlob) {
        self.id = codableBlob.id
        self.frameIndex = codableBlob.frameIndex
        self.pixels = Set(codableBlob.pixels.map { StatusPixel($0) })
    }
    
    // actual size in number of pixels
    public func size() -> Int { pixels.count }

    nonisolated public var description: String  { "Blob id: \(self.id)" }

    public func add(pixels newPixels: Set<StatusPixel>) async {
        for pixel in pixels {
            await pixel.set(status: .blobbed(self))
        }
        self.pixels = self.pixels.union(newPixels)
        reset()
    }

    public func add(pixel: StatusPixel) async {
        await pixel.set(status: .blobbed(self))
        /*self.pixels = */self.pixels.insert(pixel)
        reset()
    }

    private var _intensity: UInt16?
    private var _medianIntensity: UInt16?
    private var _boundingBox: BoundingBox?
    private var _blobLine: Line?
    private var _pixelValues: [UInt16]?
    private var _outlierGroup: OutlierGroup?
    
    // a line computed from the pixels,
    // the best fitting line we have, if any
    public var line: Line? {
        if let _blobLine { return _blobLine }
        _blobLine = HoughLineFinder(pixels: Array(self.pixels).map { $0._pixel },
                                    bounds: self.boundingBox()).line
        return _blobLine
    }

    private var _averageDistanceFromIdealLine: Double? 
    
    public var averageDistanceFromIdealLine: Double {
        if let _averageDistanceFromIdealLine {
            return _averageDistanceFromIdealLine
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
            var newPixels = Set<StatusPixel>()
            
            let standardLine = line.standardLine
            let (_, median, _) = averageMedianMaxDistance(from: line)

            for pixel in pixels {

                let pixelDistance = standardLine.distanceTo(x: pixel._pixel.x, y: pixel._pixel.y)
                if pixelDistance < 2 {
                    newPixels.insert(pixel)
                } else {

                    let bounds = self.boundingBox()
                    let x = pixel._pixel.x - bounds.min.x
                    let y = pixel._pixel.y - bounds.min.y

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
        _pixelValues = nil
        _outlierGroup = nil
        _blobLine = nil
        _averageDistanceFromIdealLine = nil
        _membersArray = nil
    }

    private var _membersArray: ([Bool])?
    
    public var membersArray: [Bool] {
        if let _membersArray { return _membersArray }
        let bounds = self.boundingBox()
        
        var members = [Bool](repeating: false,
                             count: bounds.width*bounds.height)

        for pixel in pixels {
            let x = pixel._pixel.x - bounds.min.x
            let y = pixel._pixel.y - bounds.min.y
            
            let index = y*bounds.width+x
            if index < 0 || index >= members.count {
                fatalError("bad index \(index) from [\(x), \(y)] and \(bounds)")
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

        var trimmedPixels = Set<StatusPixel>()
        let bounds = self.boundingBox()

        for pixel in pixels {
            let x = pixel._pixel.x - bounds.min.x
            let y = pixel._pixel.y - bounds.min.y
            
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
        let bounds = self.boundingBox()
        if x >= 0,
           y >= 0,
           x < bounds.width,
           y < bounds.height,
           self.membersArray[y*bounds.width+x]
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
            var newPixels = Set<StatusPixel>()
            
            let standardLine = line.standardLine
            let (_, median, max) = averageMedianMaxDistance(from: line)
            //let maxDistanceFromLine = (average+median)/2 // guess
            let maxDistanceFromLine = (median+max)/2 // guess

            for pixel in pixels {
                let pixelDistance = standardLine.distanceTo(x: pixel._pixel.x, y: pixel._pixel.y)
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
            distanceSum += standardLine.distanceTo(x: pixel._pixel.x, y: pixel._pixel.y)
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

            let distance = standardLine.distanceTo(x: pixel._pixel.x, y: pixel._pixel.y)
            
            if distance < 4 { // XXX another constant :(
                if pixel._pixel.y < minY { minY = pixel._pixel.y }
                if pixel._pixel.x < minX { minX = pixel._pixel.x }
                if pixel._pixel.y > maxY { maxY = pixel._pixel.y }
                if pixel._pixel.x > maxX { maxX = pixel._pixel.x }
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
            let distance = standardLine.distanceTo(x: pixel._pixel.x, y: pixel._pixel.y)
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

    // a line with (0,0) origin calculated from the pixels in this blob, if possible
    public var originZeroLine: Line? {
        if let line { return originZeroLine(from: line) }
        return nil
    }

    public func originZeroLine(from line: Line) -> Line {
        let bounds = self.boundingBox()

        let minX = bounds.min.x
        let minY = bounds.min.y
        let (ap1, ap2) = line.twoPoints
        return Line(point1: DoubleCoord(x: ap1.x+Double(minX),
                                        y: ap1.y+Double(minY)),
                    point2: DoubleCoord(x: ap2.x+Double(minX),
                                        y: ap2.y+Double(minY)),
                    votes: 0)
    }
    
    public func intensity() -> UInt16 { // mean intensity
        if pixels.count == 0 { return 0 }
        if let _intensity { return _intensity }
        var max: UInt64 = 0
        for pixel in pixels {
            max += UInt64(pixel._pixel.intensity)
        }
        max /= UInt64(pixels.count)
        let ret = UInt16(max)
        _intensity = ret
        return ret
    }

    public func medianIntensity() -> UInt16 {
        if pixels.count == 0 { return 0 }
        if let _medianIntensity { return _medianIntensity }
        let intensities = pixels.map { $0._pixel.intensity }
        if intensities.count == 0 {
            _medianIntensity = 0
            return 0
        }
        let ret = intensities.sorted()[intensities.count/2]
        _medianIntensity = ret
        return ret
    }

    public func makeBackground() async {
        for pixel in pixels {
            await pixel.set(status: .background)
        }
        pixels = []
        reset()
    }

    public func absorb(_ otherBlob: Blob, always: Bool = false) async -> Bool {
        if always || self.id != otherBlob.id {

            //let selfBeforeSize = self.size
            
            let newPixels = await otherBlob.getPixels()
            for otherPixel in newPixels {
                await otherPixel.set(status: .blobbed(self))
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

    public func boundingBox() -> BoundingBox {
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
                if pixel._pixel.x < min_x { min_x = pixel._pixel.x }
                if pixel._pixel.y < min_y { min_y = pixel._pixel.y }
                if pixel._pixel.x > max_x { max_x = pixel._pixel.x }
                if pixel._pixel.y > max_y { max_y = pixel._pixel.y }
            }
        }
        let ret = BoundingBox(min: Coord(x: min_x, y: min_y),
                              max: Coord(x: max_x, y: max_y))
        _boundingBox = ret
        return ret
    }

    // XXX replace this with passing in the full outlier image
    // to each outlier, and having them deal with it directly
    // will hopefully speed things up by reducing memory allocations
    public var pixelValues: [UInt16] {
        if let _pixelValues { return _pixelValues }
        let boundingBox = self.boundingBox()
        var ret = [UInt16](repeating: 0, count: boundingBox.size)
        for pixel in pixels {
            ret[(pixel._pixel.y-boundingBox.min.y)*boundingBox.width+(pixel._pixel.x-boundingBox.min.x)] = pixel._pixel.intensity
        }
        _pixelValues = ret
        return ret
    }

    // a point close to the center of this blob if it's a line, relative to its boundingBox
    public var centralLineCoord: DoubleCoord? {
        let center = self.boundingBox().centerDouble
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
        let center = self.boundingBox().centerDouble
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
        if let _outlierGroup { return _outlierGroup }
        let group = OutlierGroup(id: self.id,
                                 size: UInt(self.pixels.count),
                                 brightness: UInt(self.intensity()),
                                 bounds: self.boundingBox(),
                                 frameIndex: frameIndex,
                                 pixels: self.pixelValues,
                                 pixelSet: self.pixels,
                                 line: self.line)
        _outlierGroup = group
        return group
    }

    // returns minimum distance found 
    public func distanceTo(line: StandardLine) -> Double {
        var min: Double = 1_000_000_000_000
        for pixel in pixels {
            let distance = line.distanceTo(x: pixel._pixel.x, y: pixel._pixel.y)
            if distance < min { min = distance }
        }
        return min
    }

    public func distanceTo(x: Int, y: Int) -> Double {
        var min: Double = 1_000_000_000_000
        for pixel in pixels {
            let x_diff = Double(x - pixel._pixel.x)
            let y_diff = Double(y - pixel._pixel.y)
            let distance = sqrt(x_diff*x_diff+y_diff*y_diff)
            if distance < min { min = distance }
        }
        return min
    }
    
    public static func == (lhs: Blob, rhs: Blob) -> Bool {
        return lhs.id == rhs.id
    }

    public func borderBrightness(in originalImage: RawPixelData) -> Double {
        let b = self.pixels
        
        var dimmerCount = 0.0
        var brighterCount = 0.0
        
        for pixel in self.pixels {
            /*
             for every pixel in this newly expanded self, examine every neighbor pixel
             in the original image which is not part of the blob.
             if this neighbor pixel is the same brightness or more than the pixel we're
             coming from, then throw away this blob
             */

            let i = originalImage.intensity(atX: pixel._pixel.x, andY: pixel._pixel.y)

            let neighbors = [
              (pixel._pixel.x - 1, pixel._pixel.y - 1),
              (pixel._pixel.x,     pixel._pixel.y - 1),
              (pixel._pixel.x + 1, pixel._pixel.y - 1),
              (pixel._pixel.x - 1, pixel._pixel.y    ),
              (pixel._pixel.x + 1, pixel._pixel.y    ),
              (pixel._pixel.x - 1, pixel._pixel.y + 1),
              (pixel._pixel.x,     pixel._pixel.y + 1),
              (pixel._pixel.x + 1, pixel._pixel.y + 1),
            ]

            for neighbor in neighbors {
                if let value = image(originalImage, isBrighterAt: neighbor, than: i, ignoring: b) {
                    if value {
                        brighterCount += 1
                    } else {
                        dimmerCount += 1
                    }
                }
            }
        }

        brighterCount /= Double(self.pixels.count)
        dimmerCount   /= Double(self.pixels.count)

        // the ratio of brighter to dimmer
        // higher is brighter
        return brighterCount/dimmerCount
    }

    fileprivate func image(_ image: RawPixelData,
                           isBrighterAt at: (Int, Int),
                           than intensity: UInt,
                           ignoring blobPixels: Set<StatusPixel>) -> Bool?
    {
        let x = at.0
        let y = at.1

        let sortablePixel = StatusPixel(x: x, y: y,
                                        intensity: 0) // not used here

        if blobPixels.contains(sortablePixel) { return nil }

        return image.intensity(atX: x, andY: y) > intensity
    }
}

public func medianIntensities(of blobs: [Blob]) async -> [UInt16] {
    var intensities: [UInt16] = []

    for blob in blobs {
        intensities.append(await blob.medianIntensity())
    }

    return intensities
}
