/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa
import kht_bridge
import ImageIO

/*

 remaining problems after mat conversion:
   
 - re-test for crashes on processed frame

 * re-do ImageAccessor to ditch NSCache and cache by reference counting w/ weak ref
 - add UI counters to show how many of each type of image there is, and how much
   ram they are taking based upon their buffer sizes.
 
 */
fileprivate let doingMemoryTesting = false

fileprivate let activeImageCounter = ActiveImageCounter()

fileprivate actor ActiveImageCounter {
    private var counts: [String: Int] = [:]
    private let sleepIntervalNanoseconds: UInt64 = 5_000_000_000
    
    init() {
        Task {
            try? await Task.sleep(nanoseconds: sleepIntervalNanoseconds)
            await self.log()
        }
    }

    private func log() {
        Task {
            Log.d("we have \(self.currentCount) active images")
            for key in counts.keys {
                if let count = counts[key] {
                    Log.d("\(key) has \(count) active images")
                }
            }
            try? await Task.sleep(nanoseconds: sleepIntervalNanoseconds)
            self.log()
        }
    }

    private func hashKey(for file: String, and function: String, at line: Int) -> String {
        "\(file)@\(function):\(line)"
    }

    var currentCount: Int {
        var ret: Int = 0
        _  = counts.values.map { ret += $0 }
        return ret
    }
    
    func add(for file: String,
             and function: String,
             at line: Int)    
    {
        let key = hashKey(for: file, and: function, at: line)
        let existing = counts[key, default: 0]
        counts[key] = existing+1
    }
    
    func decrement(for file: String,
                   and function: String,
                   at line: Int)
    {
        let key = hashKey(for: file, and: function, at: line)
        let existing = counts[key, default: 0]
        if existing == 1 {
            counts.removeValue(forKey: key)
        } else {
            counts[key] = existing-1
        }
    } 
}


public final class PixelatedImage: Sendable {
    public let width: Int
    public let height: Int

    // pixel component level access to image data
    public let imageData: DataFormat

    // total number of pixels for each pixel
    public let bitsPerPixel: Int
    public let bytesPerRow: Int
    public let bitsPerComponent: Int
    public let bytesPerPixel: Int

    public let componentsPerPixel: Int

    // we are always instantiated with a cv::Mat, so keep its wrapper here so the
    // image buffer stays allocated while this object does
    public let mat: MatWrapper

    // these are just here to keep the memory retained,
    // all access is through the MatWrapper
    public let eightBitBuffer: ImageBuffer<UInt8>? 
    public let sixteenBitBuffer: ImageBuffer<UInt16>? 
    public let thirtyTwoBitBuffer: ImageBuffer<Int32>? 
    
    // enum to bridge between Data and direct individual component access
    // do we have 8 bits per component, or 16?
    // pixels could have multiple components, or just one.
    public enum DataFormat: Sendable {

        // the number of bits per component, not per pixel
        case eightBit(UnsafeBufferPointer<UInt8>)
        case sixteenBit(UnsafeBufferPointer<UInt16>)
        case thirtyTwoBit(UnsafeBufferPointer<Int32>)

        var byteCount: Int {
            switch self {
            case .eightBit(let pointer):
                return pointer.count
            case .sixteenBit(let pointer):
                return pointer.count*2
            case .thirtyTwoBit(let pointer):
                return pointer.count*4
            }
        }
    }

    public var byteCount: Int { imageData.byteCount }
        
    public convenience init?(filename: String) {
        if FileManager.default.fileExists(atPath: filename),
           let wrapper = MatWrapper.load(fromFilename: filename)
        {
            self.init(mat: wrapper)
        } else {
            return nil
        }
    }
    
    public init?(mat: MatWrapper,
                 eightBitBuffer: ImageBuffer<UInt8>? = nil,
                 sixteenBitBuffer: ImageBuffer<UInt16>? = nil,
                 thirtyTwoBitBuffer: ImageBuffer<Int32>? = nil,
                 file: String = #file,
                 function: String = #function,
                 line: Int = #line)
    {
        //Log.d("init from mat [\(mat.cols), \(mat.rows)]")
        if mat.isEmpty { return nil }
        self.file = file
        self.function = function
        self.line = line
        self.width = mat.cols
        self.height = mat.rows
        self.bytesPerRow = Int(mat.step)
        self.mat = mat // retain ownership so memory stays alive
        self.bitsPerPixel = mat.bitsPerPixel
        self.bitsPerComponent = mat.bitsPerComponent
        self.bytesPerPixel = mat.bitsPerPixel/8
        self.componentsPerPixel = mat.channels
        self.thirtyTwoBitBuffer = thirtyTwoBitBuffer
        self.sixteenBitBuffer = sixteenBitBuffer
        self.eightBitBuffer = eightBitBuffer
        if mat.bitsPerComponent == 32 {
            self.imageData = .thirtyTwoBit(mat.buffer(of: Int32.self))
        } else if mat.bitsPerComponent == 16 {
            self.imageData = .sixteenBit(mat.buffer(of: UInt16.self))
        } else if mat.bitsPerComponent == 8 {
            self.imageData = .eightBit(mat.buffer(of: UInt8.self))
        } else {
            Log.w("unsupported bitsPerComponent \(mat.bitsPerComponent)")
            return nil
        }
    }

    // XXX this method can probably go away
    public func updated(with imageData: ImageBuffer<UInt16>) -> PixelatedImage? {
        imageData.image
    }

    deinit {
        if doingMemoryTesting {
            // allow these values to outlive deinit
            let _file = file
            let _function = function
            let _line = line
            Task { await activeImageCounter.decrement(for: _file, and: _function, at: _line) }
        }
    }

    fileprivate let file: String
    fileprivate let function: String
    fileprivate let line: Int
}


extension PixelatedImage {

    private func bufferIsZero<T: Numeric & Comparable>(
      _ buffer: UnsafeBufferPointer<T>,
      atX x: Int,
      andY y: Int
    ) -> Bool {
        let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
        let red = buffer[offset]

        if red != 0 { return false }
        if self.componentsPerPixel >= 2 {
            let green = buffer[offset+1]
            if green != 0 { return false }
        }
        if self.componentsPerPixel >= 3 {
            let blue = buffer[offset+2]
            if blue != 0 { return false }
        }
        return true
    }
    
    func isZero(atX x: Int, andY y: Int) -> Bool {
        switch imageData {
        case .sixteenBit(let buffer):
            return bufferIsZero(buffer, atX: x, andY: y)

        case .eightBit(let buffer):
            return bufferIsZero(buffer, atX: x, andY: y)

        case .thirtyTwoBit(let buffer):
            return bufferIsZero(buffer, atX: x, andY: y)
            
        }
    }

    private func bufferIsMax<T: FixedWidthInteger>(
      _ buffer: UnsafeBufferPointer<T>,
      atX x: Int,
      andY y: Int
    ) -> Bool {
        let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
        let red = buffer[offset]

        if red != T.max { return false }
        if self.componentsPerPixel >= 2 {
            let green = buffer[offset+1]
            if green != T.max { return false }
        }
        if self.componentsPerPixel >= 3 {
            let blue = buffer[offset+2]
            if blue != T.max { return false }
        }
        return true
    }
    
    func isMax(atX x: Int, andY y: Int) -> Bool {
        switch imageData {

        case .sixteenBit(let buffer):
            return bufferIsMax(buffer, atX: x, andY: y)

        case .eightBit(let buffer):
            return bufferIsMax(buffer, atX: x, andY: y)

        case .thirtyTwoBit(let buffer):
            return bufferIsMax(buffer, atX: x, andY: y)
            
        }
    }
    
    public func readPixel(atX x: Int, andY y: Int) -> Pixel {
        switch imageData {
        case .sixteenBit(let buffer):
            let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
            var pixel = Pixel(numberOfComponents: self.componentsPerPixel)
            pixel.red = buffer[offset]
            if self.componentsPerPixel >= 2 {
                pixel.green = buffer[offset+1]
            }
            if self.componentsPerPixel >= 3 {
                pixel.blue = buffer[offset+2]
            }
            if self.componentsPerPixel == 4 {
                pixel.alpha = buffer[offset+3]
            }
            return pixel
            
        case .thirtyTwoBit(_):
            fatalError("not supported yet")
            break

        case .eightBit(_):
            fatalError("not supported yet")
            break
        }
    }

    func sortablePixels(baseX: Int, baseY: Int) -> [SortablePixel] {
        var ret: [SortablePixel] = []
        switch imageData {
        case .sixteenBit(let buffer):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if buffer[offset] != 0 {
                        ret.append(
                          SortablePixel(
                            x: x + baseX,
                            y: y + baseY,
                            value: .sixteenBit(buffer[offset]
                            )
                          )
                        )
                    }
                }
            }
            
        case .eightBit(let buffer):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if buffer[offset] != 0 {
                        ret.append(
                          SortablePixel(
                            x: x + baseX,
                            y: y + baseY,
                            value: .eightBit(buffer[offset]
                            )
                          )
                        )
                    }
                }
            }

        case .thirtyTwoBit(let buffer):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if buffer[offset] != 0 {
                        ret.append(
                          SortablePixel(
                            x: x + baseX,
                            y: y + baseY,
                            value: .thirtyTwoBit(buffer[offset]
                            )
                          )
                        ) // XXX numerical overflow was happening here :(
                    }
                }
            }
        }
        return ret
    }
    
    func intensity(at pixel: SortablePixel) -> UInt {
        intensity(atX: pixel.x, andY: pixel.y)
    }

    private func bufferIntensity<T: FixedWidthInteger>(
      _ buffer: UnsafeBufferPointer<T>,
      atX x: Int,
      andY y: Int
    ) -> UInt {
        let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
        var intensity: UInt = 0
        if offset < buffer.count {
            intensity += UInt(buffer[offset])
            if self.componentsPerPixel >= 2 {
                intensity += UInt(buffer[offset+1])
            }
            if self.componentsPerPixel >= 3 {
                intensity += UInt(buffer[offset+2])
            }
            if self.componentsPerPixel == 4 {
                intensity += UInt(buffer[offset+3])
            }
        }
        return intensity
    }
    
    func intensity(atX x: Int, andY y: Int) -> UInt {
        switch imageData {
        case .thirtyTwoBit(let buffer):
            return bufferIntensity(buffer, atX: x, andY: y)

        case .sixteenBit(let buffer):
            return bufferIntensity(buffer, atX: x, andY: y)

        case .eightBit(let buffer):
            return bufferIntensity(buffer, atX: x, andY: y)
        }
    }

    public var nsImage: NSImage? { mat.nsImage() }

    // write out the base image data
    public func writeTIFFEncoding(toFilename imageFilename: String) {
        self.mat.write(to: imageFilename)
    }

    public func horizonTest() throws -> PixelatedImage {
        let selfMat = self.mat
        let resultMat = PixelatedImageBridge.detectHorizon(selfMat)
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot create horizon mask"
        }
    }

    public func bitwiseNot() throws -> PixelatedImage {
        let selfMat = self.mat
        let resultMat = PixelatedImageBridge.bitwiseNot(selfMat)
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot run bitwise not"
        }
    }

    public func bitwiseAnd(with image: PixelatedImage) throws -> PixelatedImage {
        let selfMat = self.mat
        let otherMat = image.mat
        let resultMat = PixelatedImageBridge.bitwiseAnd(selfMat, withImage: otherMat)
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot run bitwise and"
        }
    }

    public func bitwiseOr(with image: PixelatedImage) throws -> PixelatedImage {
        let selfMat = self.mat
        let otherMat = image.mat
        let resultMat = PixelatedImageBridge.bitwiseOr(selfMat, withImage: otherMat)
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot run bitwise or"
        }
    }
    
    public func cannyEdgeDetect(
      minThreshold: Double,
      maxThreshold: Double,
      useL2Gradient: Bool
    ) throws -> PixelatedImage {
        let selfMat = self.mat
        let resultMat = PixelatedImageBridge.cannyEdgeDetect(
          selfMat,
          minThreshold: minThreshold,
          maxThreshold: maxThreshold,
          useL2Gradient: useL2Gradient
        )
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot perform edge detection"
        }
    }

    /// Dynamic programming horizon tracing.
    /// Finds the optimal left-to-right path through the image that follows
    /// strong horizontal edges (Sobel vertical gradient + Canny edges).
    /// Returns a binary mask: white (255) above the horizon, black (0) below.
    ///
    /// - Parameters:
    ///   - cannyMinThreshold: Canny edge detection minimum threshold
    ///   - cannyMaxThreshold: Canny edge detection maximum threshold
    ///   - useL2Gradient: Use L2 gradient for Canny edge detection
    ///   - smoothnessLambda: Penalty per pixel of vertical displacement between
    ///     adjacent columns (higher = smoother horizon). Default 2.0.
    ///   - sobelWeight: Weight for Sobel vertical gradient in cost function. Default 0.6.
    ///   - cannyWeight: Weight for Canny edge presence in cost function. Default 0.4.
    ///   - searchTopFraction: Fraction from top of image where horizon search starts.
    ///   - searchBottomFraction: Fraction from top where horizon search ends.
    /// - Returns: A `PixelatedImage` binary mask, or nil if detection fails.
    public func dpHorizonDetect(
      cannyMinThreshold: Double = 50,
      cannyMaxThreshold: Double = 120,
      useL2Gradient: Bool = true,
      smoothnessLambda: Double = 2.0,
      sobelWeight: Double = 0.6,
      cannyWeight: Double = 0.4,
      searchTopFraction: Double = 0.0,
      searchBottomFraction: Double = 1.0
    ) throws -> PixelatedImage {
        guard let resultMat = PixelatedImageBridge.dpHorizonMask(
                self.mat,
                cannyMin: cannyMinThreshold,
                cannyMax: cannyMaxThreshold,
                useL2Gradient: useL2Gradient,
                smoothnessLambda: smoothnessLambda,
                sobelWeight: sobelWeight,
                cannyWeight: cannyWeight,
                searchTopFraction: searchTopFraction,
                searchBottomFraction: searchBottomFraction
              )
        else {
            throw "DP horizon detection failed"
        }
        guard let result = PixelatedImage(mat: resultMat) else {
            throw "cannot create PixelatedImage from DP horizon mask"
        }
        return result
    }

    // returns a 16 bit grayscale image that results from subtrating
    // the given frame from this frame, done in c++ opencv2 land for speed
    public func subtract(_ otherFrame: PixelatedImage) throws -> PixelatedImage {
        // convert images to cv::Mat
        let selfMat = self.mat
        let otherMat = otherFrame.mat
        Log.d("subtract \(otherMat) from \(selfMat)")
        // jump into c++ land for the actual subtraction
        let resultMat = PixelatedImageBridge.subtractImage(otherMat, fromImage: selfMat)

        // reconstruct a PixelatedImage from the returned cv::Mat
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot create PixelatedImage from resulting mat during image subtraction"
        }
    }

    public var isEmpty: Bool { self.mat.isEmpty }
    
    public var clone: PixelatedImage {
        PixelatedImage(mat: self.mat.clone())! // XXX
    }
    
    // used as a classification criteria
    // values below 0.1 are more likely to be airplanes,
    // a small number of airplanes give higher values
    public func borderBrightness(of pixels: Set<SortablePixel>) -> Double
    {
        var dimmerCount = 0.0
        var brighterCount = 0.0
        
        for pixel in pixels {
            /*
             for every pixel in this newly expanded self, examine every neighbor pixel
             in the original image which is not part of the blob.
             if this neighbor pixel is the same brightness or more than the pixel we're
             coming from, then throw away this blob
             */

            let i = self.intensity(at: pixel) 
            let neighbors = [
              (pixel.x - 1, pixel.y - 1),
              (pixel.x,     pixel.y - 1),
              (pixel.x + 1, pixel.y - 1),
              (pixel.x - 1, pixel.y    ),
              (pixel.x + 1, pixel.y    ),
              (pixel.x - 1, pixel.y + 1),
              (pixel.x,     pixel.y + 1),
              (pixel.x + 1, pixel.y + 1),
            ]

            for neighbor in neighbors {
                if let value = isImage(self,
                                       brighterAt: neighbor,
                                       than: i,
                                       ignoring: pixels)
                {
                    if value {
                        brighterCount += 1
                    } else {
                        dimmerCount += 1
                    }
                }
            }
        }

        brighterCount /= Double(pixels.count)
        dimmerCount   /= Double(pixels.count)

        // the ratio of brighter to dimmer
        // higher is brighter
        return brighterCount/dimmerCount
    }


    // splits image into a matrix of chunked elements of a max size
    public func splitIntoMatrix(maxWidth: Int,
                                maxHeight: Int,
                                overlapPercent: Double = 0) -> [ImageMatrixElement]
    {
        let ret = self.mat.split(withTileWidth: Int32(maxWidth),
                                 tileHeight: Int32(maxHeight),
                                 overlapPercent: overlapPercent)
          .compactMap { ImageMatrixElement(objcElement: $0) }

        Log.d("split into matrix returning \(ret)")

        return ret
    }    

    /// Returns a binary (black/white) image using Otsu's thresholding.
    /// - Ignores alpha channel, but combines RGB channels into grayscale.
    public var binaryOtsuImage: PixelatedImage? {
        // Step 1: Build grayscale intensities (average of RGB, ignoring alpha if present)
        Log.d("binaryOtsuImage from \(self.description)")
        let (intensities, maxValue): ([UInt], UInt) = {
            switch self.imageData {
            case .sixteenBit(let buffer):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: buffer.count, by: comps).map { i -> UInt in
                    let rgb = buffer[i ..< i + comps].prefix(3) // drop alpha if present
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(UInt16.max))

            case .eightBit(let buffer):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: buffer.count, by: comps).map { i -> UInt in
                    let rgb = buffer[i ..< i + comps].prefix(3)
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(UInt8.max))
                
            case .thirtyTwoBit(let buffer):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: buffer.count, by: comps).map { i -> UInt in
                    let rgb = buffer[i ..< i + comps].prefix(3)
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(Int32.max))
            }
        }()

        // Step 2: Build histogram
        var histogram = [UInt](repeating: 0, count: Int(maxValue) + 1)
        for intensity in intensities {
            histogram[Int(intensity)] += 1
        }

        let totalPixels = intensities.count
        let total: Double = Double(totalPixels)

        // Step 3: Compute Otsu threshold
        var sumAll: Double = 0
        for i in 0..<histogram.count {
            sumAll += Double(i) * Double(histogram[i])
        }

        var sumB: Double = 0
        var weightB: Double = 0
        var maxVariance: Double = -1
        var threshold: Int = 0

        for t in 0..<histogram.count {
            weightB += Double(histogram[t])
            if weightB == 0 { continue }
            let weightF = total - weightB
            if weightF == 0 { break }

            sumB += Double(t) * Double(histogram[t])

            let meanB = sumB / weightB
            let meanF = (sumAll - sumB) / weightF

            let betweenVar = weightB * weightF * pow(meanB - meanF, 2)

            if betweenVar > maxVariance {
                maxVariance = betweenVar
                threshold = t
            }
        }

        // Step 4: Apply threshold → binary 8 bit image
        let out = intensities.map { $0 > UInt(threshold) ? UInt8.max : 0 }

        var buffer: ImageBuffer<UInt8>? = nil
        
        out.withUnsafeBufferPointer { pointer in
            // this copies the buffer
            buffer = ImageBuffer<UInt8>(
              pointer: pointer,
              width: width,
              height: height)
        }

        return buffer?.image
    }

    var ensureEightBit: PixelatedImage? {
        PixelatedImage(mat: mat.ensureEightBit())
    }
}



public extension PixelatedImage {
    
    func bottomCrop(by numberOfPixels: Int) -> PixelatedImage? {
        PixelatedImage(mat: mat.bottomCrop(Int32(numberOfPixels)))
    }
}


fileprivate func isImage(_ image: PixelatedImage,
                         brighterAt at: (Int, Int),
                         than intensity: UInt,
                         ignoring blobPixels: Set<SortablePixel>) -> Bool?
{
    let x = at.0
    let y = at.1

    if x < 0 || y < 0 { return nil }
    
    let sortablePixel = SortablePixel(x: x, y: y,
                                      value: .eightBit(0)) // not used here

    if blobPixels.contains(sortablePixel) { return nil }

    return image.intensity(atX: x, andY: y)  > intensity
}

extension ContiguousBytes {
    func objects<T>() -> [T] { withUnsafeBytes { .init($0.bindMemory(to: T.self)) } }

    // convert Data to [Int32]
    public var uInt32Array: [Int32] { objects() }

    // convert Data to [UInt16]
    public var uInt16Array: [UInt16] { objects() }

    // convert Data to [UInt8]
    public var uInt8Array: [UInt8] { objects() }
}

// convert a [Int32] array to Data
extension Array<Int32> {
    public var data: Data {
        let data = self.withUnsafeBufferPointer { Data(buffer: $0) }
        return data
    }
}

// convert a [UInt16] array to Data
extension Array<UInt16> {
    public var data: Data {
        let data = self.withUnsafeBufferPointer { Data(buffer: $0) }
        return data
    }
}

// convert a [UInt8] array to Data
extension Array<UInt8> {
    public var data: Data {
        let data = self.withUnsafeBufferPointer { Data(buffer: $0) }
        return data
    }
}

public class ImageMatrixElement: @unchecked Sendable, Hashable, CustomStringConvertible {
    public let x: Int                  // offset in original image
    public let y: Int
    public let width: Int
    public let height: Int
    public let horizonTopY: Int?
    public let horizonBottomY: Int?
    
    public let image: PixelatedImage

    public var objcElement: ObjcImageMatrixElement {
        let ret = ObjcImageMatrixElement()
        ret.x = Int32(self.x)
        ret.y = Int32(self.y)
        ret.width = Int32(self.width)
        ret.height = Int32(self.height)
        //ret.horizonTopY = self.horizonTopY
        //ret.horizonBottomY = self.horizonBottomY
        ret.image = image.mat
        return ret
    }

    public init?(objcElement: ObjcImageMatrixElement) {
        if let image = PixelatedImage(mat: objcElement.image) {
            self.image = image
        } else {
            Log.w("unable to make image")
            return nil
        }
        self.x = Int(objcElement.x)
        self.y = Int(objcElement.y)
        self.width = Int(objcElement.width)
        self.height = Int(objcElement.height)
        self.horizonTopY = nil
        self.horizonBottomY = nil
    }
    
    public init(x: Int,
                y: Int,
                image: PixelatedImage,
                horizonTopY: Int? = nil,
                horizonBottomY: Int? = nil)
    {
        self.x = x
        self.y = y
        self.image = image
        self.width = Int(image.width)
        self.height = Int(image.height)
        self.horizonTopY = horizonTopY
        self.horizonBottomY = horizonBottomY
    }

    public var sortablePixels: [SortablePixel] {
        image.sortablePixels(baseX: x, baseY: y)
    }

    public func intensity(atX x: Int, andY y: Int) -> UInt? {
        if contains(x: x, y: y) {
            return image.intensity(atX: x-self.x, andY: y-self.y)
        } else {
            return nil
        }
    }

    public func contains(x: Int, y: Int) -> Bool {
        x > self.x &&
        y > self.y &&
        x < self.x + width &&
        y < self.y + height
    }
    
    public static func == (lhs: ImageMatrixElement, rhs: ImageMatrixElement) -> Bool {
         lhs.x == rhs.x && lhs.y == rhs.y &&
           lhs.width == rhs.width && lhs.height == rhs.height
    }

    public var bounds: BoundingBox {
        BoundingBox(min: Coord(x: x, y: y),
                    max: Coord(x: x+width, y: y+height))
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(x)
        hasher.combine(y)
        hasher.combine(width)
        hasher.combine(height)
    }
    
    public var description: String { "MatrixElement: [\(x), \(y)] -> [\(width), \(height)]" }
}

extension PixelatedImage {
    // reassemble an image from matrix elements
    public convenience init?(from matrixElements: [ImageMatrixElement]) {
        precondition(!matrixElements.isEmpty, "Matrix must contain at least one element")
        Log.d("combine from \(matrixElements)")
        let mat = MatWrapper.combine(from: matrixElements.map { $0.objcElement })
        self.init(mat: mat)
    }
}

extension PixelatedImage {
    public func medianMerge(
      with frames: [String],
      outlierThreshold: Double = 1.2,
      includeAll: Bool = false
    ) -> PixelatedImage? {
        if let mat = ImageAligner.medianMergeImage(
             self.mat,
             withFilenames: frames,
             outlierThreshold: outlierThreshold,
             includeAll: includeAll
           ) as? MatWrapper
        {
            return PixelatedImage(mat: mat)
        } else {
            return nil
        }
    }
    
    // move image up vertically by some number of pixels
    public func shiftImageUp(by pixels: Int) -> PixelatedImage? {
        let result = PixelatedImageBridge.shiftImageUp(
          self.mat,
          shiftPixels: Int32(pixels)
        )
        return PixelatedImage(mat: result)
    }
    
    // raises the mask by the given amount, creating a gradient
    // areas that were non zero and within borderAmount of the border
    // will be part of the gradient
    public func raiseMaskBy(_ borderAmount: Int) -> PixelatedImage? {
        PixelatedImage(
          mat: ImageAligner.createGradientMask(
            intoSky: self.mat,
            gradientDistance: Int32(borderAmount)
          )
        )
    }
    
    // raises the mask by the given amount, creating a gradient
    // areas that were non zero and within borderAmount of the border
    // will be part of the gradient
    public func raiseLoweredBy(_ borderAmount: Int) -> PixelatedImage? {
        PixelatedImage(
          mat: ImageAligner.createGradientMask(
            intoGround: self.mat,
            gradientDistance: Int32(borderAmount)
          )
        )
    }
    
    public func horizonBounds() -> HorizonBounds {
        // first convert images to cv::Mat
        let baseMat = self.mat 
        let bounds = PixelatedImageBridge.horizonExtents(fromImage: baseMat)

        return HorizonBounds(
          topY: bounds.horizonTopY,
          bottomY: bounds.horizonBottomY
        )
    }

    public func maxBrightnessScale(in darksMask: PixelatedImage) -> Double {
        // first convert images to cv::Mat
        let baseMat = self.mat
        let maskMat = darksMask.mat

        return PixelatedImageBridge.maxBrightnessScale(
          forImage: baseMat,
          maskImage: maskMat
        )
    }

    public func brightenDarks(with darksMask: PixelatedImage, by amount: Double) throws -> PixelatedImage {
        // first convert images to cv::Mat
        
        let baseMat = self.mat
        let maskMat = darksMask.mat

        // then process in cv world
        let processedMat = PixelatedImageBridge.brightenDarks(
          baseMat,
          mask: maskMat,
          amount: amount
        )

        // then convert back in to PixelatedImage
        if let ret = PixelatedImage(mat: processedMat) { return ret }

        throw "cannot brighten darks"
    }

    public func darkenDarks(with darksMask: PixelatedImage, by amount: Double) throws -> PixelatedImage {

        // first convert images to cv::Mat
        let baseMat = self.mat
        let maskMat = darksMask.mat
            
        // then process in cv world
        let processedMat = PixelatedImageBridge.darkenDarks(
          baseMat,
          mask: maskMat,
          amount: amount
        )

        // then convert back in to PixelatedImage
        if let ret = PixelatedImage(mat: processedMat) { return ret }

        throw "cannot darken darks"
    }

    public func apply(
      mask: PixelatedImage,
      with background: PixelatedImage
    ) throws -> PixelatedImage {
        let selfMat = self.mat
        let backgroundMat = background.mat
        let maskMat = mask.mat
        Log.d("apply self \(selfMat) background \(backgroundMat) mask \(maskMat)")

        let combinedMat =
          PixelatedImageBridge.combineImage(
            selfMat,
            mask: maskMat,
            background: backgroundMat
          )
        if let ret = PixelatedImage(mat: combinedMat) { return ret }

        throw "Unable to apply mask to image"
    }

    public func upScaleTo(width: UInt, height: UInt) -> PixelatedImage? {
        PixelatedImage(mat: self.mat.upScale(to: width, height: height))
    }

    public func downScaleTo(width: UInt, height: UInt) -> PixelatedImage? {
        PixelatedImage(mat: self.mat.downScale(to: width, height: height))
    }

    public func saveJpeg(withQuality quality: UInt, filename: String) {
        try? ensureParentDirectoriesExist(for: filename)
        self.mat.saveJpeg(withQuality: quality, filename: filename)
    }

    public var description: String { "PixelatedImage: \(self.mat)" }

    public var ensure16Bits: PixelatedImage {
        if self.mat.is16Bits() {
            return self
        } else {
            return PixelatedImage(mat: self.mat.ensure16Bits()) ?? self
        }
    }

    public var ensure8Bits: PixelatedImage {
        if self.mat.is8Bits() {
            return self
        } else {
            return PixelatedImage(mat: self.mat.ensure8Bits()) ?? self
        }
    }
}
    
extension MatWrapper: @unchecked @retroactive Sendable {}
extension UnsafeBufferPointer: @unchecked @retroactive Sendable {}

extension MatWrapper {
    func buffer<T>(of type: T.Type) -> UnsafeBufferPointer<T> {
        let count = self.lengthInBytes / MemoryLayout<T>.stride
        return UnsafeBufferPointer(start: dataPtr.assumingMemoryBound(to: T.self),
                                   count: count)
    }

    func mutableBuffer<T>(of type: T.Type) -> UnsafeMutableBufferPointer<T> {
        let count = self.lengthInBytes / MemoryLayout<T>.stride
        return UnsafeMutableBufferPointer(start: UnsafeMutableRawPointer(mutating: dataPtr)!
                                            .assumingMemoryBound(to: T.self),
                                          count: count)
    }

    override public var description: String {
        if self.isEmpty {
            return "mat: empty"
        } else {
            return "mat: size [\(self.cols), \(self.rows)] channels \(self.channels) step \(self.step) bitsPerComponent \(self.bitsPerComponent)"
        }
    }
}

extension AlignmentResult {
    var aligned: PixelatedImage? {
        if let mat = self.alignedMat,
           !mat.isEmpty
        {
            PixelatedImage(mat: mat)
        } else {
            nil
        }
    }

    var failed: PixelatedImage? {
        if let mat = self.failedMat,
           !mat.isEmpty
        {
            PixelatedImage(mat: mat)
        } else {
            nil
        }
    }

    var horizon: PixelatedImage? {
        if let mat = self.horizonMask,
           !mat.isEmpty
        {
            PixelatedImage(mat: mat)
        } else {
            nil
        }
    }
}

