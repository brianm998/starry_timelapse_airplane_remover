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
public actor Blob: CustomStringConvertible,
                   Hashable
{
    nonisolated(unsafe) public var id: UInt16
    public let frameIndex: Int
    public var pixels: Set<SortablePixel> = []
    public weak var statusTracker: PixelStatusTracker?
    
    public func getPixels() -> Set<SortablePixel> { pixels }

    nonisolated public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public init(_ pixels: Set<SortablePixel>, // more than UInt16.max pixels is bad
                id: UInt16,
                frameIndex: Int,
                statusTracker: PixelStatusTracker? = nil)
    {
        self.pixels = pixels
        self.id = id
        self.frameIndex = frameIndex
        self.statusTracker = statusTracker
    }
    
    public init(id: UInt16,
                frameIndex: Int,
                statusTracker: PixelStatusTracker? = nil)
    {
        self.id = id
        self.frameIndex = frameIndex
        self.statusTracker = statusTracker
    }
    
    public init(_ pixel: SortablePixel,
                id: UInt16,
                frameIndex: Int,
                statusTracker: PixelStatusTracker? = nil)
    {
        self.pixels = [ pixel ]
        self.id = id
        self.frameIndex = frameIndex
        self.statusTracker = statusTracker
    }

    public init(frameIndex: Int,
                with persitentDataArray: [UInt16],
                atIndex index: Int,
                statusTracker: PixelStatusTracker? = nil)
    {
        self.statusTracker = statusTracker
        var index = index

        self.frameIndex = frameIndex
        self.pixels = [ ]

        self.id = persitentDataArray[index]
        index += 1
        
        let pixelCount = persitentDataArray[index]
        index += 1
        
        for _ in 0..<pixelCount {
            pixels.update(with: SortablePixel(x: Int(persitentDataArray[index]),
                                              y: Int(persitentDataArray[index+1]),
                                              intensity: persitentDataArray[index+2]))
            index += 3
        }
    }

    public func update(id: UInt16) { self.id = id }
    
    public func persistentDataArray() -> [UInt16] {
        let size = self.persistentDataSizeBytes()
        var array = [UInt16](repeating: 0, count: size/2)

        var index: Int = 0

        var pixelCountForSave = pixels.count
        var pixelsToSave = pixels
        
        if pixelCountForSave >= UInt16.max {
            // if a blob has more than 65536 pixels, that's a problem.
            // both because we store its size in 16 bits, and also because
            // our use case doesn't really have any blobs this big that matter
            // trim it down to size, throwing away the dimmest pixels.
            pixelCountForSave = Int(UInt16.max) - 1
            let sortedPixels = pixels.sorted { $0.intensity > $1.intensity }
            pixelsToSave = Set(sortedPixels[0..<pixelCountForSave])
        }
        
        // can crash if pixels.count > UInt16.max 
        let pixelCount = UInt16(pixelCountForSave)

        array[index] = self.id
        index += 1

        array[index] = pixelCount
        index += 1

        for pixel in pixelsToSave {
            array[index] = UInt16(pixel.x)
            index += 1

            array[index] = UInt16(pixel.y)
            index += 1

            array[index] = pixel.intensity
            index += 1
        }

        return array
    }
    
    public func persistentDataSizeBytes() -> Int {

        var size = 0

        // id UInt16
        size += 2

        // numberPixels UInt16
        size += 2

        // three UInt16 values for each pixel (x, y, intensity)
        size += self.pixels.count*6 
        
        return size
    }
    
    
    // actual size in number of pixels
    public func size() -> Int { pixels.count }

    nonisolated public var description: String  { "Blob id: \(self.id)" }

    public func add(pixels newPixels: Set<SortablePixel>) async {
        for pixel in newPixels {
            await statusTracker?.record(status: .blobbed(self), for: pixel)
            self.pixels.update(with: pixel)
        }
        reset()
    }

    public func add(pixel: SortablePixel) async {
        let newPixel = pixel
        await statusTracker?.record(status: .blobbed(self), for: pixel)
        /*self.pixels = */self.pixels.update(with: newPixel)
        reset()
    }

    private var _lineFillAmount: Double? 
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
        _blobLine = HoughLineFinder(pixels: Array(self.pixels),
                                    bounds: self.boundingBox(),
                                    medianIntensity: self.medianIntensity(),
                                    maxIntensity: self.maxIntensity(),
                                    frameIndex: frameIndex).line
        return _blobLine
    }


    /*

     XXX write code in the BlobProcessor to use this at the end of processing
     to try to detach any blobs we can split up.

     use it only on larger blobs (1-200?)

     
     */
    // use KHT to see if we have more than one line in this group of pixels
    public func lineSplit(args: BlobLineSplitter.Args) -> [[SortablePixel]]
    {
        let hlf = HoughLineFinder(pixels: Array(self.pixels),
                                  bounds: self.boundingBox(),
                                  medianIntensity: self.medianIntensity(),
                                  maxIntensity: self.maxIntensity(),
                                  frameIndex: frameIndex)

        let (pixelsToKeep, newPixelSets) =
          hlf.lineSplit(args: args, optimalLine: hlf.line)
        
        if newPixelSets.count > 0 {
            Log.d("frame \(frameIndex) blob \(self.size()) lineSplit found \(newPixelSets.count) new pixel sets, reducing size of blob by \(self.pixels.count-pixelsToKeep.count) pixels")
            self.pixels = Set(pixelsToKeep)
            reset()
            return newPixelSets
        }
        return []
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

    public func lineLength() -> Double? {
        if let line = self.originZeroLine {
            let (_, lineLength) = averageDistanceAndLineLength(from: line)
            return lineLength
        } else {
            return nil
        }
    }

    public func medianDistanceFromIdealLine() -> (Double, Double)? {
        if let line = self.originZeroLine {
            let (_, lineLength) = averageDistanceAndLineLength(from: line)
            let (_, median, _) = averageMedianMaxDistance(from: line)
            return (median, lineLength)
        } else {
            return nil
        }
    }

    // removes all pixels below the given intensity floor
    public func intensityTrim(by intensityFloor: UInt16) {
        for pixel in pixels {
            if pixel.intensity < intensityFloor {
                pixels.remove(pixel)
            }
        }
    }
    
    // trims outlying pixels from the group, especially
    // ones with very few neighboring pixels
    public func fancyLineTrim(by minNeighbors: Int = 3) {
        if let line = self.originZeroLine {
            var newPixels = Set<SortablePixel>()
            
            let standardLine = line.standardLine
            let (_, median, _) = averageMedianMaxDistance(from: line)

            for pixel in pixels {

                let pixelDistance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
                if pixelDistance < 2 {
                    newPixels.update(with: pixel)
                } else {

                    let bounds = self.boundingBox()
                    let x = pixel.x - bounds.min.x
                    let y = pixel.y - bounds.min.y

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
                        if neighborCount > 2 { newPixels.update(with: pixel) }
                    } else if neighborCount > 1 {
                        newPixels.update(with: pixel)
                    }
                }
            }
            let diff = self.pixels.count - newPixels.count
            self.pixels = newPixels
            Log.d("blog \(self) trimming \(diff) pixels")
            reset()
        }
    }

    private var _bunchCalculator: BunchCalculator?

    private var _bunches: [Set<SortablePixel>]?

    public func bunches() -> [Set<SortablePixel>] {
        if let _bunches { return _bunches }
        let ret = self.bunchCalculator().calculateBunches()
        _bunches = ret
        return ret
    }
    
    public func bunchCalculator() -> BunchCalculator {
        if let _bunchCalculator { return _bunchCalculator }
        let ret = BunchCalculator(from: self.pixels,
                                  with: self.boundingBox(),
                                  maxPixelDistance: maxBunchDistance)
        _bunchCalculator = ret
        return ret
    }
    
    private func reset() {
        _lineFillAmount = nil
        _intensity = nil
        _medianIntensity = nil
        _boundingBox = nil
        _pixelValues = nil
        _outlierGroup = nil
        _blobLine = nil
        _averageDistanceFromIdealLine = nil
        _membersArray = nil
        _maxIntensity = nil
        _bunchCount = nil
        _medianBunchSize = nil
        _maxBunchSize = nil
        _bunchCalculator = nil
    }

    private var _membersArray: ([Bool])?
    
    public var membersArray: [Bool] {
        if let _membersArray { return _membersArray }
        let bounds = self.boundingBox()
        
        var members = [Bool](repeating: false,
                             count: bounds.width*bounds.height)

        for pixel in pixels {
            let x = pixel.x - bounds.min.x
            let y = pixel.y - bounds.min.y
            
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

        var trimmedPixels = Set<SortablePixel>()
        let bounds = self.boundingBox()

        for pixel in pixels {
            let x = pixel.x - bounds.min.x
            let y = pixel.y - bounds.min.y
            
            var neighborCount: Int = 0
            neighborCount += self.hasPixel(x: x-1, y: y-1)
            neighborCount += self.hasPixel(x: x,   y: y-1)
            neighborCount += self.hasPixel(x: x+1, y: y-1)
            neighborCount += self.hasPixel(x: x-1, y: y)
            neighborCount += self.hasPixel(x: x+1, y: y)
            neighborCount += self.hasPixel(x: x-1, y: y+1)
            neighborCount += self.hasPixel(x: x,   y: y+1)
            neighborCount += self.hasPixel(x: x+1, y: y+1)

            if neighborCount > minNeighbors { trimmedPixels.update(with: pixel) }
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

    public func remove(pixels: Set<SortablePixel>) {
        self.pixels.subtract(pixels)
    }
        
    public func remove(pixel: SortablePixel) {
        self.pixels.remove(pixel)
    }
        
    // mutates the blob by removing all pixels with lesser intensity
    public func removePixels(dimmerThan intensity: UInt16) {
        var shouldReset = false
        for pixel in pixels {
            if pixel.intensity < intensity {
                pixels.remove(pixel)
                shouldReset = true
            }
        }
        if shouldReset { reset() }
    }
    
    // trims outlying pixels from the group, ones that are not
    // close enough to the ideal line for this group
    public func lineTrim() {
        if let line = self.originZeroLine {
            var newPixels = Set<SortablePixel>()
            
            let standardLine = line.standardLine
            let (_, median, max) = averageMedianMaxDistance(from: line)
            //let maxDistanceFromLine = (average+median)/2 // guess
            let maxDistanceFromLine = (median+max)/2 // guess

            for pixel in pixels {
                let pixelDistance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
                if pixelDistance <= maxDistanceFromLine {
                    newPixels.update(with: pixel)
                }
            }
            let diff = self.pixels.count - newPixels.count
            self.pixels = newPixels
            Log.d("blog \(self) trimming \(diff) pixels")
            reset()
        }
    }
    
    // trims outlying pixels from the group, ones that are not
    // close enough to the ideal line for this group
    public func lineTrim(by maxDistance: Double = 12) {
        if let line = self.originZeroLine {
            var newPixels = Set<SortablePixel>()
            
            let standardLine = line.standardLine

            for pixel in pixels {
                let pixelDistance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
                if pixelDistance <= maxDistance {
                    newPixels.update(with: pixel)
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
            max += UInt64(pixel.intensity)
        }
        max /= UInt64(pixels.count)
        let ret = UInt16(max)
        _intensity = ret
        return ret
    }

    public func medianIntensity() -> UInt16 {
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

    public func maxIntensity() -> UInt16 {
        if pixels.count == 0 { return 0 }
        if let _maxIntensity { return _maxIntensity }
        var ret: UInt16 = 0
        for pixel in pixels {
            if pixel.intensity > ret { ret = pixel.intensity }
        }
        _maxIntensity = ret
        return ret
    }

    fileprivate var _bunchCount: Int? = nil
    fileprivate var _medianBunchSize: Int? = nil
    fileprivate var _maxBunchSize: Int? = nil
    fileprivate var _maxIntensity: UInt16? = nil
    
    public func bunchCount() async -> Int {
        if let _bunchCount { return _bunchCount }

        (_bunchCount, _medianBunchSize, _maxBunchSize) =
          await calculateBunchData(from: self, maxPixelDistance: maxBunchDistance)

        return _bunchCount!
    }
    
    public func medianBunchSize() async -> Int {
        if let _medianBunchSize { return _medianBunchSize }

        (_bunchCount, _medianBunchSize, _maxBunchSize) =
          await calculateBunchData(from: self, maxPixelDistance: maxBunchDistance)

        return _medianBunchSize!
    }
    
    public func maxBunchSize() async -> Int {
        if let _maxBunchSize { return _maxBunchSize }

        (_bunchCount, _medianBunchSize, _maxBunchSize) =
          await calculateBunchData(from: self, maxPixelDistance: maxBunchDistance)

        return _maxBunchSize!
    }

    public func absorb(_ pixels: Set<SortablePixel>) {
        self.pixels.formUnion(pixels)
    }
    
    public func absorb(_ pixels: [SortablePixel]) {
        self.pixels.formUnion(pixels)
    }
    
    public func absorb(_ otherBlob: Blob, always: Bool = false) async -> Bool {
        let otherBlobSize = await otherBlob.size()

        // hard max size on blobs because of how we save them
        if otherBlobSize + self.size() > UInt16.max { return false }
        
        if always || self.id != otherBlob.id {
            
            let selfBeforeSize = self.size()
            
            let newPixels = await otherBlob.getPixels()
            var updatedPixels = self.pixels
            for otherPixel in newPixels {
                await statusTracker?.record(status: .blobbed(self), for: otherPixel)
                updatedPixels.update(with: otherPixel)
            }
            self.pixels = updatedPixels
            reset()

            let selfAfterSize = self.size()

            if selfAfterSize != selfBeforeSize + (await otherBlob.size()) {
                //Log.w("frame \(frameIndex) blob \(self.id) \(selfAfterSize) != \(selfBeforeSize) + \(await otherBlob.size())")
                if frameIndex == 0 {
                  //  Log.i("frame \(frameIndex) blob \(self.id) \(self.pixels.count) pixels \(self.pixels)")
                    //Log.i("frame \(frameIndex) other blob \(otherBlob.id) pixels \(await otherBlob.pixels)")
                }
            }
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

        // XXX move to a BoundingBox constructor
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


    public func lineFillAmount() -> Double {
        if let _lineFillAmount { return _lineFillAmount }

        var ret = 0.0
        if let line = self.line {
            ret = calculateLineFillAmount(from: line,
                                          with: self.boundingBox(),
                                          and: self.pixelValues,
                                          and: self.pixels)
        }
        _lineFillAmount = ret
        return ret
    }


    // remove any pixels within this bounding box from this blob and return them
    public func slice(with boundingBox: BoundingBox) -> Set<SortablePixel> {
        var ret: Set<SortablePixel> = []
        
        let bounds = self.boundingBox()
        if let overlap = bounds.overlap(with: boundingBox) {
            for pixel in pixels {
                if overlap.contains(pixel) {
                    ret.update(with: pixel)
                    pixels.remove(pixel)
                }
            }
        }
        if ret.count > 0 { reset() }
        return ret
    }
    
    public var pixelValues: [UInt16] {
        if let _pixelValues { return _pixelValues }
        let boundingBox = self.boundingBox()
        var ret = [UInt16](repeating: 0, count: boundingBox.size)
        for pixel in pixels {
            ret[(pixel.y-boundingBox.min.y)*boundingBox.width+(pixel.x-boundingBox.min.x)] = pixel.intensity
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
                                 pixelSet: self.pixels)
        _outlierGroup = group
        return group
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
    
    public static func == (lhs: Blob, rhs: Blob) -> Bool {
        return lhs.id == rhs.id
    }

}

public func medianIntensities(of blobs: [Blob]) async -> [UInt16] {
    var intensities: [UInt16] = []

    for blob in blobs {
        intensities.append(await blob.medianIntensity())
    }

    return intensities
}
