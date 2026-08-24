/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import StarCppBridge
import logging
#if canImport(CoreGraphics)
import CoreGraphics
#endif
#if canImport(CoreVideo)
import CoreVideo
#endif
#if canImport(ImageIO)
import ImageIO
#endif
#if canImport(AppKit)
import AppKit
#endif

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
    // @unchecked because the UnsafeBufferPointer lifetimes are managed
    // by the owning MatWrapper, which keeps the cv::Mat memory alive.
    public enum DataFormat: @unchecked Sendable {

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

    /// Return a CV_8UC1 (single-channel 8-bit grayscale) version of this image.
    /// Used whenever an image is about to be used as a horizon mask, ensuring
    /// all downstream OpenCV operations (e.g. distanceTransform) receive the
    /// correct type regardless of how the file was written to disk.
    public var asHorizonMask: PixelatedImage? {
        PixelatedImage(mat: mat.ensureGray8U())
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

    #if canImport(CoreGraphics)
    /// Create a CGImage from this image's pixel data.
    public var cgImage: CGImage? {
        let src = mat.is8Bits ? mat : mat.ensure8Bits()
        let w = Int(src.cols)
        let h = Int(src.rows)
        let ch = Int(src.channels)
        guard w > 0 && h > 0, let ptr = src.dataPtr else { return nil }

        let bitsPerComponent = 8
        let bitsPerPixel = bitsPerComponent * ch
        let bytesPerRow = Int(src.step)

        // OpenCV uses BGR order; CoreGraphics needs RGB
        let colorSpace: CGColorSpace
        let bitmapInfo: CGBitmapInfo
        switch ch {
        case 1:
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = CGBitmapInfo(rawValue: 0)
        case 3:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            // BGR → we'll swap below
            bitmapInfo = CGBitmapInfo(rawValue: 0)
        case 4:
            colorSpace = CGColorSpaceCreateDeviceRGB()
            bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
        default:
            return nil
        }

        // For BGR(A), swap to RGB(A) into a temporary buffer
        let data: UnsafeRawPointer
        let tempBuffer: UnsafeMutableRawPointer?
        if ch >= 3 {
            let totalBytes = h * bytesPerRow
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: totalBytes)
            let srcPtr = ptr.assumingMemoryBound(to: UInt8.self)
            for row in 0..<h {
                for col in 0..<w {
                    let si = row * bytesPerRow + col * ch
                    let di = row * bytesPerRow + col * ch
                    buf[di]     = srcPtr[si + 2]  // R ← B
                    buf[di + 1] = srcPtr[si + 1]  // G ← G
                    buf[di + 2] = srcPtr[si]      // B ← R
                    if ch == 4 { buf[di + 3] = srcPtr[si + 3] }
                }
            }
            data = UnsafeRawPointer(buf)
            tempBuffer = UnsafeMutableRawPointer(buf)
        } else {
            data = ptr
            tempBuffer = nil
        }
        defer { tempBuffer?.deallocate() }

        guard let provider = CGDataProvider(dataInfo: nil,
                                             data: data,
                                             size: h * bytesPerRow,
                                             releaseData: { _, _, _ in }) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: bitsPerComponent,
                       bitsPerPixel: bitsPerPixel,
                       bytesPerRow: bytesPerRow,
                       space: colorSpace,
                       bitmapInfo: bitmapInfo,
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
    #endif

    #if canImport(AppKit)
    /// Create an NSImage from this image's pixel data.
    public var nsImage: NSImage? {
        guard let cgImage = self.cgImage else { return nil }
        let w = Int(mat.cols)
        let h = Int(mat.rows)
        return NSImage(cgImage: cgImage, size: NSSize(width: w, height: h))
    }
    #endif

    /// Write out the base image data. Returns whether the file is now on disk.
    ///
    /// (The name is historical — the format comes from the filename extension, not from
    /// anything TIFF-specific here.)
    ///
    /// `@discardableResult` so the many debug, mask and preview writers are unaffected, but
    /// the result is real and the output-frame path checks it: before this the whole chain
    /// down to `cv::imwrite` returned void, so a failed write was logged in C++ and invisible
    /// to Swift.
    @discardableResult
    public func writeTIFFEncoding(toFilename imageFilename: String) -> Bool {
        self.mat.write(to: imageFilename)
    }

    public func horizonTest() throws -> PixelatedImage {
        let selfMat = self.mat
        guard let resultMat = PixelatedImageBridge.detectHorizon(selfMat) else {
            throw "detectHorizon returned nil"
        }
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot create horizon mask"
        }
    }

    public func bitwiseNot() throws -> PixelatedImage {
        let selfMat = self.mat
        guard let resultMat = PixelatedImageBridge.bitwiseNot(selfMat) else {
            throw "bitwiseNot returned nil"
        }
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot run bitwise not"
        }
    }

    public func bitwiseAnd(with image: PixelatedImage) throws -> PixelatedImage {
        let selfMat = self.mat
        let otherMat = image.mat
        guard let resultMat = PixelatedImageBridge.bitwiseAnd(selfMat, withImage: otherMat) else {
            throw "bitwiseAnd returned nil"
        }
        if let ret = PixelatedImage(mat: resultMat) {
            return ret
        } else {
            throw "cannot run bitwise and"
        }
    }

    public func bitwiseOr(with image: PixelatedImage) throws -> PixelatedImage {
        let selfMat = self.mat
        let otherMat = image.mat
        guard let resultMat = PixelatedImageBridge.bitwiseOr(selfMat, withImage: otherMat) else {
            throw "bitwiseOr returned nil"
        }
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
        guard let resultMat = PixelatedImageBridge.cannyEdgeDetect(
          selfMat,
          minThreshold: minThreshold,
          maxThreshold: maxThreshold,
          useL2Gradient: useL2Gradient
        ) else {
            throw "cannyEdgeDetect returned nil"
        }
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
        guard let resultMat = PixelatedImageBridge.subtractImage(otherMat, fromImage: selfMat) else {
            throw "subtractImage returned nil"
        }

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
        let ret = self.mat.split(tileWidth: Int32(maxWidth),
                                 tileHeight: Int32(maxHeight),
                                 overlapPercent: overlapPercent)
          .compactMap { tile in
              guard let img = PixelatedImage(mat: tile.image) else { return nil as ImageMatrixElement? }
              return ImageMatrixElement(x: tile.x, y: tile.y, image: img)
          }

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
        guard let cropped = mat.bottomCrop(Int32(numberOfPixels)) else { return nil }
        return PixelatedImage(mat: cropped)
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

    // The lower bounds are inclusive: a tile owns the column at its own x and the row at its own y.
    //
    // These were `>` rather than `>=`, so every tile disowned its first row and column.  That was
    // not cosmetic: `intensity(atX:andY:)` is gated on this, and HoughLineMatrixBlobConnector reads
    // blob ids through it while walking a hough line across a tile.  Blob ids sitting on a tile's
    // top or left edge were therefore invisible to it, and since the tiles cover the frame that
    // left a one pixel grid of blind lines across the whole image where a line crossing there
    // could not connect the blobs on either side.
    public func contains(x: Int, y: Int) -> Bool {
        x >= self.x &&
        y >= self.y &&
        x < self.x + width &&
        y < self.y + height
    }
    
    public static func == (lhs: ImageMatrixElement, rhs: ImageMatrixElement) -> Bool {
         lhs.x == rhs.x && lhs.y == rhs.y &&
           lhs.width == rhs.width && lhs.height == rhs.height
    }

    // BoundingBox is inclusive — its width is max - min + 1 — so the far corner is one short of
    // x + width.  It used to be x + width, which made bounds.width one greater than the tile's own
    // width and had the box overlap its neighbour by a column.  HoughLineMatrixBlobConnector walks
    // `bounds.intersections(with:)` across the tile, so the walk ran a pixel past the edge.
    public var bounds: BoundingBox {
        BoundingBox(min: Coord(x: x, y: y),
                    max: Coord(x: x+width-1, y: y+height-1))
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
        // Return nil rather than trapping.  This is a failable initializer, and no elements is
        // exactly the case a caller would expect nil for — `MatWrapper.combine(from:)` below
        // already answers nil for an empty list.  It used to be a `precondition`, which cannot be
        // recovered from.  Nothing in the tree calls this today, so the trap was unreachable.
        guard !matrixElements.isEmpty else {
            Log.w("cannot combine an image from no matrix elements")
            return nil
        }
        Log.d("combine from \(matrixElements)")
        let tiles = matrixElements.map { e in
            MatTileElement(x: e.x, y: e.y, width: e.width, height: e.height, image: e.image.mat)
        }
        guard let mat = MatWrapper.combine(from: tiles) else { return nil }
        self.init(mat: mat)
    }
}

extension PixelatedImage {
    /// Accumulate binary horizon masks from `filenames` via a producer/consumer
    /// pipeline and return the majority-vote result as a binary image.
    public static func accumulatedHorizonMask(fromFilenames filenames: [String]) -> PixelatedImage? {
        guard let mat = ImageAligner.accumulateHorizonMasks(filenames: filenames) else { return nil }
        return PixelatedImage(mat: mat)
    }

    /// Median merge this image with the frames named by `frames`.
    ///
    /// Pass `config` so the merge can stream from scratch files instead of holding
    /// every source in memory when the set is large — see
    /// `Config.mergeStreamingThresholdMB` — and so it can decode more than one source
    /// at a time, see `Config.mergeLoadConcurrency`. Without it the merge keeps
    /// everything resident, which is `frames.count + 1` whole frames, and loads them
    /// one at a time.
    public func medianMerge(
      with frames: [String],
      outlierThreshold: Double = 1.2,
      includeAll: Bool = false,
      config: Config? = nil
    ) -> PixelatedImage? {
        let mat = ImageAligner.medianMergeImage(
            self.mat,
            withFilenames: frames,
            outlierThreshold: outlierThreshold,
            includeAll: includeAll,
            scratchDir: config?.tempOutputPath,
            streamingThresholdBytes: Int64(config?.mergeStreamingThresholdMB ?? 0) * 1024 * 1024,
            loadConcurrency: config?.mergeLoadConcurrency ?? 1
        )
        return PixelatedImage(mat: mat)
    }
    
    /// Warp this image using the given row-major 3×3 homography (9 elements).
    public func warped(with homography: [Double]) -> PixelatedImage? {
        let hMat = MatWrapper(homographyValues: homography) 
        guard let result = PixelatedImageBridge.warpImage(self.mat, withHomography: hMat) else { return nil }
        return PixelatedImage(mat: result)
    }

    /// Warp this binary horizon mask using the given row-major 3×3 homography.
    /// Uses nearest-neighbour interpolation (preserves 0/255) and fills
    /// out-of-bounds pixels with white (sky = 255) so warp borders are never
    /// misread as ground.
    public func warpedAsHorizonMask(with homography: [Double]) -> PixelatedImage? {
        let hMat = MatWrapper(homographyValues: homography)
        guard let result = PixelatedImageBridge.warpHorizonMask(self.mat, withHomography: hMat) else { return nil }
        return PixelatedImage(mat: result)
    }

    /// Per-pixel absolute difference converted to 8-bit grayscale.
    public func absDiff(with other: PixelatedImage) -> PixelatedImage? {
        guard let result = PixelatedImageBridge.absDiffGrayscale(self.mat, withImage: other.mat) else { return nil }
        return PixelatedImage(mat: result)
    }

    // move image up vertically by some number of pixels
    public func shiftImageUp(by pixels: Int) -> PixelatedImage? {
        guard let result = PixelatedImageBridge.shiftImageUp(
          self.mat,
          shiftPixels: Int32(pixels)
        ) else { return nil }
        return PixelatedImage(mat: result)
    }
    
    // raises the mask by the given amount, creating a gradient
    // areas that were non zero and within borderAmount of the border
    // will be part of the gradient
    public func raiseMaskBy(_ borderAmount: Int) -> PixelatedImage? {
        PixelatedImage(
          mat: ImageAligner.createGradientMaskIntoSky(
            self.mat,
            gradientDistance: Int32(borderAmount)
          )
        )
    }
    
    // raises the mask by the given amount, creating a gradient
    // areas that were non zero and within borderAmount of the border
    // will be part of the gradient
    public func raiseLoweredBy(_ borderAmount: Int) -> PixelatedImage? {
        PixelatedImage(
          mat: ImageAligner.createGradientMaskIntoGround(
            self.mat,
            gradientDistance: Int32(borderAmount)
          )
        )
    }
    
    public func horizonBounds() -> HorizonBounds? {
        // first convert images to cv::Mat
        let baseMat = self.mat
        guard let bounds = PixelatedImageBridge.horizonExtents(fromImage: baseMat) else {
            return nil
        }

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
        guard let processedMat = PixelatedImageBridge.brightenDarks(
          baseMat,
          mask: maskMat,
          amount: amount
        ) else {
            throw "brightenDarks returned nil"
        }

        // then convert back in to PixelatedImage
        if let ret = PixelatedImage(mat: processedMat) { return ret }

        throw "cannot brighten darks"
    }

    public func darkenDarks(with darksMask: PixelatedImage, by amount: Double) throws -> PixelatedImage {

        // first convert images to cv::Mat
        let baseMat = self.mat
        let maskMat = darksMask.mat
            
        // then process in cv world
        guard let processedMat = PixelatedImageBridge.darkenDarks(
          baseMat,
          mask: maskMat,
          amount: amount
        ) else {
            throw "darkenDarks returned nil"
        }

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

        guard let combinedMat =
          PixelatedImageBridge.combineImage(
            selfMat,
            mask: maskMat,
            background: backgroundMat
          ) else {
            throw "combineImage returned nil"
        }
        if let ret = PixelatedImage(mat: combinedMat) { return ret }

        throw "Unable to apply mask to image"
    }

    public func upScaleTo(width: UInt, height: UInt) -> PixelatedImage? {
        guard let scaled = self.mat.upScale(to: width, height: height) else { return nil }
        return PixelatedImage(mat: scaled)
    }

    public func downScaleTo(width: UInt, height: UInt) -> PixelatedImage? {
        guard let scaled = self.mat.downScale(to: width, height: height) else { return nil }
        return PixelatedImage(mat: scaled)
    }

    /// Save as a JPEG. Returns whether the file is now on disk.
    @discardableResult
    public func saveJpeg(withQuality quality: UInt, filename: String) -> Bool {
        try? ensureParentDirectoriesExist(for: filename)
        return self.mat.saveJpeg(quality: UInt32(quality), filename: filename)
    }

    public var description: String { "PixelatedImage: \(self.mat)" }

    public var ensure16Bits: PixelatedImage {
        if self.mat.is16Bits {
            return self
        } else {
            return PixelatedImage(mat: self.mat.ensure16Bits()) ?? self
        }
    }

    public var ensure8Bits: PixelatedImage {
        if self.mat.is8Bits {
            return self
        } else {
            return PixelatedImage(mat: self.mat.ensure8Bits()) ?? self
        }
    }
}
    
#if canImport(CoreVideo)
// MARK: - CVPixelBuffer

extension PixelatedImage {

    /// Returns the image as an 8-bit BGRA `CVPixelBuffer` (format `kCVPixelFormatType_32BGRA`)
    /// suitable for passing directly to a CoreML model.
    ///
    /// `kCVPixelFormatType_32BGRA` is the pixel format most widely accepted by CoreML's
    /// `MLFeatureValue(pixelBuffer:)`.  CoreML automatically converts the BGRA buffer to
    /// whatever channel order the model declares (e.g. `ct.colorlayout.RGB`), so no manual
    /// channel reordering is required here.
    ///
    /// Conversions applied automatically:
    ///  - **Bit depth** — 16-bit / 32-bit images are reduced to 8-bit using a fixed ÷256
    ///    scale, matching the scaling `tile_extractor` applies when writing tiles.
    ///  - **BGR → BGRA** (3-channel OpenCV) — B, G, R channels copied directly into the
    ///    first three bytes; alpha set to 255.
    ///  - **Grayscale → BGRA** (1 channel) — value replicated to B, G, R; alpha = 255.
    ///  - **BGRA** (4 channels) — copied as-is.
    ///
    /// Row padding from OpenCV (`mat.step`) and from CoreVideo are both handled
    /// correctly, so the method is safe for images of any width.
    ///
    /// - Returns: A `CVPixelBuffer`, or `nil` if the image is empty or allocation fails.
    public func toPixelBuffer() -> CVPixelBuffer? {
        // Ensure 8-bit.  No-op when already 8-bit; ÷256 fixed scale for 16-bit.
        let src: PixelatedImage
        if mat.is8Bits {
            src = self
        } else {
            guard let converted = PixelatedImage(mat: mat.ensure8Bits()) else { return nil }
            src = converted
        }

        let w  = src.width
        let h  = src.height
        let ch = src.componentsPerPixel

        // Allocate a 32-bit BGRA pixel buffer — the format most reliably accepted by CoreML.
        var pb: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault,
                                  w, h,
                                  kCVPixelFormatType_32BGRA,
                                  nil,
                                  &pb) == kCVReturnSuccess,
              let pb
        else { return nil }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let dstBase = CVPixelBufferGetBaseAddress(pb) else { return nil }

        // Source: raw mat bytes. Use mat.step as row stride — it may include
        // OpenCV alignment padding that mat.lengthInBytes does NOT account for.
        let srcBytes  = src.mat.dataPtr!.assumingMemoryBound(to: UInt8.self)
        let srcStride = Int(src.mat.step)

        // Destination: CoreVideo may also add per-row padding for its own alignment.
        let dstBytes  = dstBase.assumingMemoryBound(to: UInt8.self)
        let dstStride = CVPixelBufferGetBytesPerRow(pb)

        for row in 0 ..< h {
            let srcRow = srcBytes + row * srcStride
            let dstRow = dstBytes + row * dstStride
            for col in 0 ..< w {
                let s = srcRow + col * ch   // UnsafePointer<UInt8>
                let d = dstRow + col * 4    // UnsafeMutablePointer<UInt8>  (4 bytes: B G R A)
                switch ch {
                case 1:          // grayscale → BGRA (replicate, alpha = 255)
                    d[0] = s[0]; d[1] = s[0]; d[2] = s[0]; d[3] = 255
                case 3:          // BGR (OpenCV) → BGRA (copy directly, alpha = 255)
                    d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = 255
                case 4:          // BGRA → BGRA (copy as-is)
                    d[0] = s[0]; d[1] = s[1]; d[2] = s[2]; d[3] = s[3]
                default:         // unexpected channel count — replicate first channel
                    d[0] = s[0]; d[1] = s[0]; d[2] = s[0]; d[3] = 255
                }
            }
        }

        return pb
    }
}
#endif

// MARK: - MatWrapper

// MatWrapper is already @unchecked Sendable in StarCppBridge
// UnsafeBufferPointer is already Sendable in the Swift stdlib

extension MatWrapper: @retroactive CustomStringConvertible {
    func buffer<T>(of type: T.Type) -> UnsafeBufferPointer<T> {
        let count = self.lengthInBytes / MemoryLayout<T>.stride
        return UnsafeBufferPointer(start: dataPtr!.assumingMemoryBound(to: T.self),
                                   count: count)
    }

    func mutableBuffer<T>(of type: T.Type) -> UnsafeMutableBufferPointer<T> {
        let count = self.lengthInBytes / MemoryLayout<T>.stride
        return UnsafeMutableBufferPointer(start: UnsafeMutableRawPointer(mutating: dataPtr!)
                                            .assumingMemoryBound(to: T.self),
                                          count: count)
    }

    public var description: String {
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

