/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import KHTSwift
import logging


public struct CombinedHoughLineFinder: Sendable {

    let finders: [HoughLineFinder]

    let bounds: BoundingBox
    
    public init(pixels: [SortablePixel],
                bounds: BoundingBox,
                args: HoughLineFinder.Args,
                frameIndex: Int) 
    {
        self.bounds = bounds

        /*

         refacor this to only have one finder unless we are below some configured size

         */

        
        
        var _finders: [HoughLineFinder] = []
        _finders.append(.init(pixels: pixels,
                              bounds: bounds,
                              args: args,
                              frameIndex: frameIndex,
                              imageDataBorderSize: 0))
        
        if bounds.width < 120 || bounds.height < 120 {
            // for some reason, sometimes we get better lines by padding the input data on the ends
            // this combination exists to find the best lines from all of them.
            // because this takes longer, only use it for smaller areas.
            _finders.append(.init(pixels: pixels,
                                  bounds: bounds,
                                  args: args,
                                  frameIndex: frameIndex,
                                  imageDataBorderSize: 5000))
        }
        self.finders = _finders
    }


    public func originZeroLine(from line: Line) -> Line {
        self.finders[0].originZeroLine(from: line)
    }
    
    public var lineData: [HoughLineFinder.LineInfo] {
        var base: [HoughLineFinder.LineInfo] = []

        for finder in finders { base += finder.lineData }

        // as a last ditch, add in two lines, from each opposite corners of the bounding box
        // this might be better than the line we get from KHT :(

        let f1 = Line(point1: DoubleCoord(x: 0.1, y: 0.1), // avoid having line pass through origin
                      point2: DoubleCoord(x: Double(bounds.width),
                                          y: Double(bounds.height)),
                      votes: 66)

        let f1IntensityScore =
          self.finders[0].intensityScore(for: self.finders[0].originZeroLine(from: f1))

        let f1PixelScore =
          self.finders[0].pixelScore(for: self.finders[0].originZeroLine(from: f1))

        base.append(.init(line: f1,
                          intensityScore: f1IntensityScore,
                          pixelScore: f1PixelScore,
                          border: -1))

        let f2 = Line(point1: DoubleCoord(x: Double(bounds.width), y: 0),
                      point2: DoubleCoord(x: 0, y: Double(bounds.height)),
                      votes: 68)

        let f2IntensityScore =
          self.finders[0].intensityScore(for: self.finders[0].originZeroLine(from: f2))

        let f2PixelScore =
          self.finders[0].pixelScore(for: self.finders[0].originZeroLine(from: f2))

        base.append(.init(line: f2,
                          intensityScore: f2IntensityScore,
                          pixelScore: f2PixelScore,
                          border: -2))

        return base
    }

    public var line: HoughLineFinder.LineInfo? {
        var data = self.lineData

        data.sort { $0.intensityScore > $1.intensityScore }

        if data.count > 0 {
            return data[0]
        } else {
            return nil
        }
    }
}

// use the KHT to find lines, and then return the one which best fits the input data,
// i.e. has the lowest mean distance of pixels to the line
public struct HoughLineFinder: Sendable {

    let data: [SortablePixel]
    
    let bounds: BoundingBox
    let frameIndex: Int
    let args: Args

    let _imageDataBorderSize: Int?

    public init(pixels: [SortablePixel],
                bounds: BoundingBox,
                args: Args,
                frameIndex: Int,
                imageDataBorderSize: Int? = nil) 
    {
        self.data = pixels
        self.args = args
        self.bounds = bounds
        self.frameIndex = frameIndex
        self._imageDataBorderSize = imageDataBorderSize
    }

    public struct Args: Sendable, Hashable, Equatable, Argable, Codable, Identifiable {
        
        var imageDataBorderSize: Int
        var maxLineConstant: Int// max number of of hough lines to look at

        public typealias Types = ArgType

        public var id: Self { self }

        public func description(for type: ArgType) -> String {
            switch type {
            case .imageDataBorderSize:
                return """
                  it's best to keep the important pixel data
                  away from the middle of the image,
                  as the KHT uses the center of the image
                  as the origin for its lines.
                  we get better results this way,
                  instead of giving the KHT algorithm a small
                  image with a line right through the middle of it.
                  """
            case .maxLineConstant:
                return "Return no more than this many lines, sorted by number of votes"
            }
        }

        public enum ArgType: CaseIterable, Hashable {
            case imageDataBorderSize
            case maxLineConstant
        }

        public func isInteger(_ type: ArgType) -> Bool {
            switch type {
            case .imageDataBorderSize:
                return true
            case .maxLineConstant:
                return true
            }
        }

        public func isOptional(_ type: ArgType) -> Bool { false }
        
        public func value(for type: ArgType) -> Double? {
            switch type {
            case .imageDataBorderSize:
                return Double(imageDataBorderSize)
            case .maxLineConstant:
                return Double(maxLineConstant)
            }
        }
        
        public func doubleUpdate(for type: ArgType, value: Double) -> Args? {
            switch type {
            case .imageDataBorderSize:
                return nil

            case .maxLineConstant:
                return nil

            }
        }
        
        public func intUpdate(for type: ArgType, value: Int) -> Args? {
            switch type {
            case .imageDataBorderSize:
                return Args(imageDataBorderSize: value,
                            maxLineConstant: self.maxLineConstant)

            case .maxLineConstant:
                return Args(imageDataBorderSize: self.imageDataBorderSize,
                            maxLineConstant: value)

            }
        }
        /*

         XXX

         sometimes imageDataBorderSize == 0 is best
         othertimes we get the best line with imageDataBorderSize == 5000

         try a multi approach which does both, and chooses the best line score
         
         */
        public init(imageDataBorderSize: Int = 4000,
                    maxLineConstant: Int = 500)
        {
            self.imageDataBorderSize = imageDataBorderSize
            self.maxLineConstant = maxLineConstant
        }
    }
        
    public var imageDataWidth: Int {
        if self.bounds.width < self.bounds.height {
            return self.bounds.width+self.imageDataBorderSize
        } else {
            return self.bounds.width
        }
    }

    public var imageDataHeight: Int {
        if self.bounds.height < self.bounds.width {
            return self.bounds.height+self.imageDataBorderSize
        } else {
            return self.bounds.height
        }
    }

    private func imageData() -> ImageBuffer<UInt8> {
        var imageData = ImageBuffer<UInt8>(
          width: self.imageDataWidth,
          height: self.imageDataHeight
        )

        //Log.d("frame \(frameIndex) blob image data with \(pixels.count) pixels")
        
        let minX = self.bounds.min.x
        let minY = self.bounds.min.y

        for pixel in data {
            let imageIndex = (pixel.y - minY)*imageDataWidth + (pixel.x - minX)

            imageData[imageIndex] = 0xFF

            // XXX this can give zeros, and result in no lines :(
            //imageData[imageIndex] = UInt8(pixel.intensity>>8)
            // XXX use this instead? VVV
            //imageData[imageIndex] = UInt8(pixel.intensity/0xFF)
        }

        return imageData
    }

    public func pixelScore(for line: Line) -> Double {
        let standardLine = line.standardLine
        var ret: Double = 0.0
        for pixel in data {
            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)

            if distance < 1 {
                ret += 1.0
            } else {
                ret += 1.0/(distance*distance)
            }
        }

        return ret
    }

    public func intensityScore(for line: Line) -> Double {
        let standardLine = line.standardLine
        var ret: Double = 0.0
        for pixel in data {
            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)

            let intensity = Double(pixel.intensity)/0xFFFF
            
            if distance < 1 {
                ret += intensity
            } else {
                ret += intensity/(distance*distance)
            }
        }

        return ret
    }
    
    var pixelImage: PixelatedImage? { self.imageData().image }

    public struct LineInfo: Identifiable, Sendable {
        public let id = UUID()
        
        public let line: Line
        public let intensityScore: Double
        public let pixelScore: Double
        public let border: Int
    }
    
    public var lineData: [LineInfo] {
        var ret: [LineInfo] = []

        if let pixelImage {
            let mat = pixelImage.mat 
            let lines = kernelHoughTransform(
              image: mat,
              width: pixelImage.width,
              height: pixelImage.height,
              maxResults: args.maxLineConstant
            )

            for i in 0..<lines.count {
                let originZeroLine = self.originZeroLine(from: lines[i])
                
                ret.append(LineInfo(line: lines[i],
                                    intensityScore: intensityScore(for: originZeroLine),
                                    pixelScore: pixelScore(for: originZeroLine),
                                    border: self.imageDataBorderSize))
            }
        } else {
            Log.w("no pixelated image")
        }
        return ret
    }
    
    public var imageDataBorderSize: Int {
        if let _imageDataBorderSize {
            return _imageDataBorderSize
        } else {
            return args.imageDataBorderSize
        }
    }
    
    public var line: LineInfo? {
        

        if let pixelImage = self.pixelImage {
            let mat = pixelImage.mat    
            let lines = kernelHoughTransform(
              image: mat,
              width: pixelImage.width,
              height: pixelImage.height,
              maxResults: args.maxLineConstant
            )

            /*
             - look at the first N lines
             - calculate the average distance from the line for each of them.
             - choose the best one
             */

            if lines.count > 0 {
                var bestIntensityScore: Double = 0
                var bestPixelScore: Double = 0
                var bestLineIndex = 0
                var max = lines.count
                if max > args.maxLineConstant { max = args.maxLineConstant } 
                
                for i in 0..<max {
                    let originZeroLine = self.originZeroLine(from: lines[i])

                    let intensityScore = intensityScore(for: originZeroLine)
                    let pixelScore = pixelScore(for: originZeroLine)
                    
                    if intensityScore > bestIntensityScore {
                        //Log.d("line \(i) is best theta \(lines[i].theta) avg median max \(avg) \(median) \(max)")
                        bestIntensityScore = intensityScore
                        bestPixelScore = pixelScore
                        bestLineIndex = i
                    }
                }

                return LineInfo(line: lines[bestLineIndex],
                                intensityScore: bestIntensityScore,
                                pixelScore: bestPixelScore,
                                border: 0)                
            }
        }
        return nil
    }

    public func averageMedianMaxDistance(from line: Line) -> (Double, Double, Double) {
        let standardLine = line.standardLine
        var distanceSum: Double = 0.0
        var distances:[Double] = []
        var max: Double = 0
        var numPixels: Int = 0

        numPixels = data.count
        for pixel in data {
            let distance = standardLine.distanceTo(x: pixel.x, y: pixel.y)
            distanceSum += distance
            distances.append(distance)
            if distance > max { max = distance }                
        }
        distances.sort { $0 > $1 }
        if numPixels == 0 {
            return (0, 0, 0)
        } else {
            let average = distanceSum/Double(numPixels)
            let median = distances[distances.count/2]
            return (average, median, max)
        }
    }

    public func originZeroLine(from line: Line) -> Line {
        let minX = self.bounds.min.x
        let minY = self.bounds.min.y
        let (ap1, ap2) = line.twoPoints
        return Line(point1: DoubleCoord(x: ap1.x+Double(minX),
                                        y: ap1.y+Double(minY)),
                    point2: DoubleCoord(x: ap2.x+Double(minX),
                                        y: ap2.y+Double(minY)),
                    votes: 0)
    }
    
}
