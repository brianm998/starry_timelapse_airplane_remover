/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

/*

 XXX
 write a unit test that tests splitIntoMatrix on an image,
 comparing the input image with the returned matrix.
 make sure it works for both 16 and 32 bit images, 32 bit may be broken
 XXX
 
 */



import Foundation
import CoreGraphics
import KHTSwift
import logging
import Cocoa
import kht_bridge
import ImageIO

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
    let bitmapInfo: CGBitmapInfo

    public let componentsPerPixel: Int

    // if instantiated with a cv::Mat, keep its wrapper here so the
    // image buffer stays allocated while this object does
    public let mat: MatWrapper?
    
    let colorSpace: CGColorSpace // XXX why both space and name?
    
    // enum to bridge between Data and direct individual component access
    // do we have 8 bits per component, or 16?
    // pixels could have multiple components, or just one.
    public enum DataFormat: Sendable {

        // the number of bits per component, not per pixel
        case eightBit([UInt8])
        case unsafeEightBit(UnsafeBufferPointer<UInt8>)
        case sixteenBit([UInt16])
        case unsafeSixteenBit(UnsafeBufferPointer<UInt16>)
        case thirtyTwoBit([UInt32])
        //case unsafeThirtyTwoBit(UnsafeBufferPointer<UInt32>)
        
        init(from array: [UInt8]) {
            self = .eightBit(array)
        }

        init(from array: [UInt16]) {
            self = .sixteenBit(array)
        }

        init(from array: [UInt32]) {
            self = .thirtyTwoBit(array)
        }
        
        var data: Data {
            switch self {
            case .unsafeSixteenBit(let buffer):
                Data(buffer: buffer)
            case .unsafeEightBit(let buffer):
                Data(buffer: buffer)
            //case .unsafeThirtyTwoBit(let buffer):
            //    Data(buffer: buffer)
            case .eightBit(let arr):
                arr.data
            case .sixteenBit(let arr):
                arr.data
            case .thirtyTwoBit(let arr):
                arr.data
            }
        }
    }
    
    public convenience init(width: Int,
                            height: Int,
                            grayscale32BitImageData imageData: [UInt32])
    {
        self.init(width: width,
                  height: height,
                  imageData: DataFormat(from: imageData),
                  bitsPerPixel: 32,
                  bytesPerRow: 4*width,
                  bitsPerComponent: 32,
                  bytesPerPixel: 4,
                  bitmapInfo: .byteOrder32Little, 
                  componentsPerPixel: 1,
                  colorSpace: CGColorSpaceCreateDeviceGray())
    }

    public convenience init(width: Int,
                            height: Int,
                            grayscale16BitImageData imageData: [UInt16])
    {
        self.init(width: width,
                  height: height,
                  imageData: DataFormat(from: imageData),
                  bitsPerPixel: 16,
                  bytesPerRow: 2*width,
                  bitsPerComponent: 16,
                  bytesPerPixel: 2,
                  bitmapInfo: .byteOrder16Little, 
                  componentsPerPixel: 1,
                  colorSpace: CGColorSpaceCreateDeviceGray())
    }

    public convenience init(width: Int,
                            height: Int,
                            grayscale8BitImageData imageData: [UInt8])
    {
        self.init(width: width,
                  height: height,
                  imageData: DataFormat(from: imageData),
                  bitsPerPixel: 8,
                  bytesPerRow: width,
                  bitsPerComponent: 8,
                  bytesPerPixel: 1,
                  bitmapInfo: .byteOrderDefault, 
                  componentsPerPixel: 1,
                  colorSpace: CGColorSpaceCreateDeviceGray())
    }

    public init?(mat: MatWrapper,
                 file: String = #file,
                 function: String = #function,
                 line: Int = #line)
    {
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
        self.bitmapInfo = mat.bitmapInfo
        self.componentsPerPixel = mat.channels
        self.colorSpace = mat.colorSpace
        if mat.bitsPerComponent == 16 {
            self.imageData = .unsafeSixteenBit(mat.buffer(of: UInt16.self))
        } else if mat.bitsPerComponent == 8 {
            self.imageData = .unsafeEightBit(mat.buffer(of: UInt8.self))
        } else {
            Log.w("unsupported bitsPerComponent \(mat.bitsPerComponent)")
            return nil
        }
    }
    
    public init(width: Int,
                height: Int,
                imageData: DataFormat,
                bitsPerPixel: Int,
                bytesPerRow: Int,
                bitsPerComponent: Int,
                bytesPerPixel: Int,
                bitmapInfo: CGBitmapInfo,
                componentsPerPixel: Int,
                colorSpace: CGColorSpace,
                file: String = #file,
                function: String = #function,
                line: Int = #line)    
    {
        self.file = file
        self.function = function
        self.line = line
        self.width = width
        self.height = height
        self.mat = nil
        self.imageData = imageData
        self.bitsPerPixel = bitsPerPixel
        self.bytesPerRow = bytesPerRow
        self.bitsPerComponent = bitsPerComponent
        self.bytesPerPixel = bytesPerPixel
        self.bitmapInfo = bitmapInfo
        self.componentsPerPixel = componentsPerPixel
        self.colorSpace = colorSpace
        if doingMemoryTesting {
            Task { await activeImageCounter.add(for: file, and: function, at: line) }
        }
    }

    public func updated(with imageData: [UInt16]) -> PixelatedImage {
        return PixelatedImage(width: self.width,
                              height: self.height,
                              imageData: .sixteenBit(imageData),
                              bitsPerPixel: self.bitsPerPixel,
                              bytesPerRow: self.bytesPerRow,
                              bitsPerComponent: self.bitsPerComponent,
                              bytesPerPixel: self.bytesPerPixel,
                              bitmapInfo: self.bitmapInfo,
                              componentsPerPixel: self.componentsPerPixel,
                              colorSpace: self.colorSpace)
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
    
    init?(_ image: CGImage,
          file: String = #file,
          function: String = #function,
          line: Int = #line)
    {
        //Log.w("START")
        // assert(image.colorSpace?.model == .rgb)

        self.file = file
        self.function = function
        self.line = line
        self.mat = nil
        if Thread.isMainThread { Log.w("ON MAIN THREAD") }
        
        self.width = image.width
        self.height = image.height
        self.bitsPerPixel = image.bitsPerPixel
        self.bytesPerRow = image.bytesPerRow
        self.bitsPerComponent = image.bitsPerComponent
        self.bytesPerPixel = self.bitsPerPixel / 8
        self.bitmapInfo = image.bitmapInfo
        self.componentsPerPixel = image.bitsPerPixel/image.bitsPerComponent
        self.colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()


        if let data = image.dataProvider?.data as? Data {
            if bytesPerPixel == 1 {
                self.imageData = .eightBit(data.uInt8Array)
            } else {
                self.imageData = .sixteenBit(data.uInt16Array)
            }
            if doingMemoryTesting {
                Task { await activeImageCounter.add(for: file, and: function, at: line) }
            }
        } else {
            Log.e("DOH")
            return nil
        }
    }
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
        case .unsafeSixteenBit(let buffer):
            return bufferIsZero(buffer, atX: x, andY: y)

        case .unsafeEightBit(let buffer):
            return bufferIsZero(buffer, atX: x, andY: y)

        case .thirtyTwoBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIsZero(buffer, atX: x, andY: y)
            }
            
        case .sixteenBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIsZero(buffer, atX: x, andY: y)
            }

        case .eightBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIsZero(buffer, atX: x, andY: y)
            }
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

        case .unsafeSixteenBit(let buffer):
            return bufferIsMax(buffer, atX: x, andY: y)

        case .unsafeEightBit(let buffer):
            return bufferIsMax(buffer, atX: x, andY: y)

        case .thirtyTwoBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIsMax(buffer, atX: x, andY: y)
            }
            
        case .sixteenBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIsMax(buffer, atX: x, andY: y)
            }

        case .eightBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIsMax(buffer, atX: x, andY: y)
            }
        }
    }
    
    public func readPixel(atX x: Int, andY y: Int) -> Pixel {
        switch imageData {
        case .unsafeSixteenBit(let buffer):
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
            
        case .unsafeEightBit(let buffer):
            fatalError("not implemented")
        case .thirtyTwoBit(_):
            fatalError("not supported yet")
            break
            
        case .sixteenBit(let arr):
            let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
            var pixel = Pixel(numberOfComponents: self.componentsPerPixel)
            pixel.red = arr[offset]
            if self.componentsPerPixel >= 2 {
                pixel.green = arr[offset+1]
            }
            if self.componentsPerPixel >= 3 {
                pixel.blue = arr[offset+2]
            }
            if self.componentsPerPixel == 4 {
                pixel.alpha = arr[offset+3]
            }
            return pixel

        case .eightBit(_):
            fatalError("not supported yet")
            break
        }
    }

    func sortablePixels(baseX: Int, baseY: Int) -> [SortablePixel] {
        var ret: [SortablePixel] = []
        switch imageData {
        case .unsafeSixteenBit(let buffer):
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
            
        case .unsafeEightBit(let buffer):
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

        case .thirtyTwoBit(let arr):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if arr[offset] != 0 {
                        ret.append(
                          SortablePixel(
                            x: x + baseX,
                            y: y + baseY,
                            value: .thirtyTwoBit(arr[offset]
                            )
                          )
                        ) // XXX numerical overflow was happening here :(
                    }
                }
            }
            
        case .sixteenBit(let arr):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if arr[offset] != 0 {
                        ret.append(
                          SortablePixel(
                            x: x + baseX,
                            y: y + baseY,
                            value: .sixteenBit(arr[offset]
                            )
                          )
                        )
                    }
                }
            }
            
        case .eightBit(let arr):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if arr[offset] != 0 {
                        ret.append(
                          SortablePixel(
                            x: x + baseX,
                            y: y + baseY,
                            value: .eightBit(arr[offset]
                            )
                          )
                        )
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
        case .thirtyTwoBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIntensity(buffer, atX: x, andY: y)
            }

        case .sixteenBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIntensity(buffer, atX: x, andY: y)
            }

        case .eightBit(let arr):
            return arr.withUnsafeBufferPointer { buffer in
                return bufferIntensity(buffer, atX: x, andY: y)
            }
            
        case .unsafeSixteenBit(let buffer):
            return bufferIntensity(buffer, atX: x, andY: y)

        case .unsafeEightBit(let buffer):
            return bufferIntensity(buffer, atX: x, andY: y)
        }
    }

    public func nsImage(ofSize size: NSSize) -> NSImage? {
        return self.nsImage?.resized(to: size)
    }

    public var nsImage: NSImage? {
        do {
            let cgImage = try image(fromData: imageData.data)
            return NSImage(cgImage: cgImage, size: .zero)
        } catch {
            Log.e("error \(error)")
        }
        return nil
    }

    func image(fromData imageData: Data) throws -> CGImage {
        Log.d("self bitsPerPixel \(self.bitsPerPixel) bitsPerComponent \(self.bitsPerComponent) bytesPerPixel \(self.bytesPerPixel) componentsPerPixel \(self.componentsPerPixel)")
        guard width > 0 && height > 0 else {
            let message = "invalid dimensions"
            Log.e(message)
            throw message
        }

        let expectedBytes = width * height * bytesPerPixel
        guard imageData.count >= expectedBytes else {
            let message = "image data too small (\(imageData.count) < \(expectedBytes))"
            Log.e(message)
            throw message
        }

        // Make a mutable copy when we might need to rewrite channel order (BGR->RGB)
        let pixelData = imageData

        let colorSpace: CGColorSpace
        var bitmapInfo: CGBitmapInfo

        if componentsPerPixel == 4 {
            Log.d("FUCKING ALPHA self.bitmapInfo \(self.bitmapInfo)")
            // 4-channel: assume OpenCV BGRA layout in memory (B G R A)
            colorSpace = CGColorSpaceCreateDeviceRGB()
            // Combine byte order and alpha info by OR'ing rawValues
            // Using premultipliedFirst is common for BGRA (little-endian)

            let raw = CGBitmapInfo.byteOrder16Little.rawValue |
              UInt32(CGImageAlphaInfo.last.rawValue)

            bitmapInfo = CGBitmapInfo(rawValue: raw)
            
            Log.d("FUCKING NEW ALPHA bitmapInfo \(bitmapInfo)")
        } else if componentsPerPixel == 3 {
            Log.d("FUCKING NO ALPHA")
            // 3-channel: OpenCV gives BGR — convert to RGB to avoid color swap
            colorSpace = CGColorSpaceCreateDeviceRGB()
            // No alpha
            bitmapInfo = self.bitmapInfo
        } else {
            Log.d("FUCKING GRAYSCALE")
            // Grayscale / 1-channel
            colorSpace = CGColorSpaceCreateDeviceGray()
            bitmapInfo = self.bitmapInfo
        }

        guard let provider = CGDataProvider(data: pixelData as CFData) else {
            let message = "could not create CGDataProvider"
            Log.e(message)
            throw message
        }

        guard let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: bitsPerComponent,
                bitsPerPixel: bytesPerPixel * 8,
                bytesPerRow: width * bytesPerPixel,
                space: colorSpace,
                bitmapInfo: bitmapInfo,
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) 
        else {
            let message = "could not create CGImage from data"
            Log.e(message)
            throw message
        }

        return cgImage
    }

    func nsImage(ofSize size: NSSize, fromData imageData: Data) -> NSImage? {
        do {
            let newImage = try image(fromData: imageData) 
            return NSImage(cgImage: newImage, size: size).resized(to: size)
        } catch {
            Log.e("\(error)")
        }
        return nil
    }
    
    // write out the base image data
    public func writeTIFFEncoding(toFilename imageFilename: String) throws {
        try self.writeTIFFEncoding(ofData: self.imageData.data,
                                   toFilename: imageFilename)
    }

    // write out the given image data as a 16 bit tiff file to the given filename
    // used when modifying the invariant original image data, and saying the edits to a file
    // uses BackBits image compression
    // XXX make this async
    func writeTIFFEncoding(ofData imageData: Data,
                           toFilename imageFilename: String) throws
    {
        Log.d("writeTIFFEncoding of imageData \(imageData.count)")
        Log.d("self bitsPerPixel \(self.bitsPerPixel) bitsPerComponent \(self.bitsPerComponent) bytesPerPixel \(self.bytesPerPixel) componentsPerPixel \(self.componentsPerPixel)")
        if FileManager.default.fileExists(atPath: imageFilename) {
            Log.i("overwriting already existing filename \(imageFilename)")
            try FileManager.default.removeItem(atPath: imageFilename)
        }
        
        // create a CGImage from the data we just changed

        let newImage = try self.image(fromData: imageData) 
        // save it
        //Log.d("newImage \(newImage)")


        let fileURL = NSURL(fileURLWithPath: imageFilename, isDirectory: false) as URL

        guard let dest = CGImageDestinationCreateWithURL(fileURL as CFURL, kUTTypeTIFF, 1, nil) else {
            throw NSError(domain: "SaveTIFF", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create image destination"])
        }
    
        CGImageDestinationAddImage(dest, newImage, nil)
    
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "SaveTIFF", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to write image"])
        }        
        Log.i("image written to \(imageFilename)")
    }
    
    // returns a 16 bit grayscale image that results from subtrating
    // the given frame from this frame, done in c++ opencv2 land for speed
    public func subtract(_ otherFrame: PixelatedImage) throws -> PixelatedImage {
        // convert images to cv::Mat
        if let selfMat = self.asMatWrapper,
           let otherMat = otherFrame.asMatWrapper
        {
            // jump into c++ land for the actual subtraction
            let resultMat = PixelatedImageBridge.subtractImage(otherMat, fromImage: selfMat)

            // reconstruct a PixelatedImage from the returned cv::Mat
            if let ret = PixelatedImage(mat: resultMat) {

                return ret
            } else {
                throw "cannot create PixelatedImage from resulting mat during image subtraction"
            }
        } else {
            throw "cannot subtract images without mat wrappers"
        }
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
        // XXX 32 bit only works on grayscale
        // XXX 16 bit works for all
        // XXX 8 bit doesn't work at all
        // XXX add checks for this

        // move x and y by overlapPercent of maxWidth and maxHeight every time

        // keep the overlap between 0...90 percent
        var realOverlap = overlapPercent
        if overlapPercent < 0 { realOverlap = 0 } 
        if overlapPercent >= 90 { realOverlap = 90 } // at least 10 percent move

        // how far apart the starting point for each matrix element is from neighbors
        let xAdjust = Int(Double(maxWidth)*(100-realOverlap)/100)
        let yAdjust = Int(Double(maxHeight)*(100-realOverlap)/100)

        Log.i("matrix xAdjust \(xAdjust) yAdjust \(yAdjust)")

        // starting point for each matrix element
        var xOffset = 0
        var yOffset = 0
        
        var matrix: [ImageMatrixElement] = []
        while xOffset < width {
            yOffset = 0
            while yOffset < height {
                var matrixWidth = maxWidth
                if xOffset + matrixWidth > width {
                    matrixWidth = width - xOffset
                }
                var matrixHeight = maxHeight
                if yOffset + matrixHeight > height {
                    matrixHeight = height - yOffset
                }
                //Log.i("matrix height \(matrixHeight)")
                if matrixWidth > 0,
                   matrixHeight > 0
                {
                    switch imageData {
                    case .unsafeSixteenBit(let buffer):
                        fatalError("not implemented")
                    case .unsafeEightBit(let buffer):
                        fatalError("not implemented")
                    case .thirtyTwoBit(let arr):
                        //fatalError("THIS MIGHT BE BROKEN")
                        var matrixImageData = [UInt32](repeating: 0, count: matrixWidth*matrixHeight)
                        for y in 0..<matrixHeight {
                            arr.withUnsafeBufferPointer { sourcePtr in
                                if let baseAddress = sourcePtr.baseAddress {
                                    memmove(&matrixImageData[y*matrixWidth],
                                            baseAddress + (y+yOffset)*width+xOffset,
                                            matrixWidth*4)
                                } else {
                                    Log.w("cannot memmove")
                                }
                            }
                        }

                        let matrixImage = PixelatedImage(width: matrixWidth,
                                                         height: matrixHeight,
                                                         grayscale32BitImageData: matrixImageData)

                        let element = ImageMatrixElement(x: xOffset,
                                                         y: yOffset,
                                                         image: matrixImage)
                        
                        //Log.i("matrix element [\(xOffset), \(yOffset)] image width \(matrixWidth) matrix height \(matrixHeight)")
                        matrix.append(element)
                        
                    case .sixteenBit(let arr):
                        if componentsPerPixel == 1 {
                            var matrixImageData = [UInt16](repeating: 0, count: matrixWidth*matrixHeight)
                            for y in 0..<matrixHeight {
                                arr.withUnsafeBufferPointer { sourcePtr in
                                    if let baseAddress = sourcePtr.baseAddress {
                                        memmove(&matrixImageData[y*matrixWidth],
                                                baseAddress + (y+yOffset)*width+xOffset,
                                                matrixWidth*2)
                                    } else {
                                        Log.w("cannot memmove")
                                    }
                                }
                            }

                            let matrixImage = PixelatedImage(width: matrixWidth,
                                                             height: matrixHeight,
                                                             grayscale16BitImageData: matrixImageData)

                            let element = ImageMatrixElement(x: xOffset,
                                                             y: yOffset,
                                                             image: matrixImage)
                            
                            //Log.i("matrix element [\(xOffset), \(yOffset)] image width \(matrixWidth) matrix height \(matrixHeight)")
                            matrix.append(element)
                        } else {
                            // XXX this might work for components per pixel 1 too, check
                            Log.i("matrix element [\(xOffset), \(yOffset)] image width \(matrixWidth) matrix height \(matrixHeight)")
                            var matrixImageData = [UInt16](repeating: 0, count: matrixWidth*matrixHeight*bytesPerPixel)
                            for y in 0..<matrixHeight {
                                arr.withUnsafeBufferPointer { sourcePtr in
                                    if let baseAddress = sourcePtr.baseAddress {
                                        memmove(&matrixImageData[y*matrixWidth*bytesPerPixel/2],
                                                baseAddress + (y+yOffset)*width*bytesPerPixel/2+xOffset*bytesPerPixel/2,
                                                matrixWidth*bytesPerPixel)
                                    } else {
                                        Log.w("cannot memmove")
                                    }
                                }
                            }

                            let matrixImage = PixelatedImage(
                              width: matrixWidth,
                              height: matrixHeight,
                              imageData: DataFormat(from: matrixImageData),
                              bitsPerPixel: self.bitsPerPixel,
                              bytesPerRow: self.bytesPerRow,
                              bitsPerComponent: self.bitsPerComponent,
                              bytesPerPixel: self.bytesPerPixel,
                              bitmapInfo: self.bitmapInfo,
                              componentsPerPixel: self.componentsPerPixel,
                              colorSpace: self.colorSpace
                            )
                            
                            let element = ImageMatrixElement(x: xOffset,
                                                             y: yOffset,
                                                             image: matrixImage)
                            
                            //Log.i("matrix element [\(xOffset), \(yOffset)] image width \(matrixWidth) matrix height \(matrixHeight)")
                            matrix.append(element)
                        }
                    case .eightBit(_):
                        Log.e("eight bit not yet implemented")
                        break       // XXX do this too
                        
                    }
                }
                yOffset += yAdjust
            }
            xOffset += xAdjust
        }
        Log.i("matrix  has \(matrix.count) rows")
        return matrix
    }    

    // an element of the whole image, for testing
    var imageMatrixElement: ImageMatrixElement {
        ImageMatrixElement(x: 0, y: 0, image: self)
    }

    /// Returns a binary (black/white) image using Otsu's thresholding.
    /// - Ignores alpha channel, but combines RGB channels into grayscale.
    public var binaryOtsuImage: PixelatedImage {
        // Step 1: Build grayscale intensities (average of RGB, ignoring alpha if present)
        let (intensities, maxValue): ([UInt], UInt) = {
            switch self.imageData {
            case .unsafeSixteenBit(let buffer):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: buffer.count, by: comps).map { i -> UInt in
                    let rgb = buffer[i ..< i + comps].prefix(3) // drop alpha if present
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(UInt8.max))

            case .unsafeEightBit(let buffer):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: buffer.count, by: comps).map { i -> UInt in
                    let rgb = buffer[i ..< i + comps].prefix(3)
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(UInt16.max))
                
            case .eightBit(let arr):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: arr.count, by: comps).map { i -> UInt in
                    let rgb = arr[i ..< i + comps].prefix(3) // drop alpha if present
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(UInt8.max))

            case .sixteenBit(let arr):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: arr.count, by: comps).map { i -> UInt in
                    let rgb = arr[i ..< i + comps].prefix(3)
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(UInt16.max))

            case .thirtyTwoBit(let arr):
                let comps = componentsPerPixel
                let vals = stride(from: 0, to: arr.count, by: comps).map { i -> UInt in
                    let rgb = arr[i ..< i + comps].prefix(3)
                    return UInt(rgb.reduce(0) { $0 + UInt($1) }) / UInt(rgb.count)
                }
                return (vals, UInt(UInt32.max))
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
        return PixelatedImage(width: width,
                              height: height,
                              grayscale8BitImageData: out)
    }


}



public extension PixelatedImage {
    
    func bottomCrop(by numberOfPixels: Int) -> PixelatedImage {
        // Clamp the number of pixels to the image height
        let cropHeight = min(numberOfPixels, self.height)
        let startRow = self.height - cropHeight
        
        switch self.imageData {
        case .unsafeSixteenBit(let buffer):
            let bytesPerRow = self.bytesPerPixel * self.width
            let startIndex = startRow * bytesPerRow
            let endIndex = startIndex + cropHeight * bytesPerRow
            let croppedData = Array(buffer[startIndex..<endIndex])
            
            return PixelatedImage(
              width: self.width,
              height: cropHeight,
              imageData: .sixteenBit(croppedData),
              bitsPerPixel: self.bitsPerPixel,
              bytesPerRow: self.bytesPerRow,
              bitsPerComponent: self.bitsPerComponent,
              bytesPerPixel: self.bytesPerPixel,
              bitmapInfo: self.bitmapInfo,
              componentsPerPixel: self.componentsPerPixel,
              colorSpace: self.colorSpace
            )
            
        case .unsafeEightBit(let buffer):
            let bytesPerRow = self.bytesPerPixel * self.width
            let startIndex = startRow * bytesPerRow
            let endIndex = startIndex + cropHeight * bytesPerRow
            let croppedData = Array(buffer[startIndex..<endIndex])
            
            return PixelatedImage(
              width: self.width,
              height: cropHeight,
              imageData: .eightBit(croppedData),
              bitsPerPixel: self.bitsPerPixel,
              bytesPerRow: self.bytesPerRow,
              bitsPerComponent: self.bitsPerComponent,
              bytesPerPixel: self.bytesPerPixel,
              bitmapInfo: self.bitmapInfo,
              componentsPerPixel: self.componentsPerPixel,
              colorSpace: self.colorSpace
            )

        case .eightBit(let arr):
            let bytesPerRow = self.bytesPerPixel * self.width
            let startIndex = startRow * bytesPerRow
            let endIndex = startIndex + cropHeight * bytesPerRow
            let croppedData = Array(arr[startIndex..<endIndex])
            
            return PixelatedImage(
              width: self.width,
              height: cropHeight,
              imageData: .eightBit(croppedData),
              bitsPerPixel: self.bitsPerPixel,
              bytesPerRow: self.bytesPerRow,
              bitsPerComponent: self.bitsPerComponent,
              bytesPerPixel: self.bytesPerPixel,
              bitmapInfo: self.bitmapInfo,
              componentsPerPixel: self.componentsPerPixel,
              colorSpace: self.colorSpace
            )
            
        case .sixteenBit(let arr):
            let pixelsPerRow = self.width * self.componentsPerPixel
            let startIndex = startRow * pixelsPerRow
            let endIndex = startIndex + cropHeight * pixelsPerRow
            let croppedData = Array(arr[startIndex..<endIndex])
            
            return PixelatedImage(
              width: self.width,
              height: cropHeight,
              imageData: .sixteenBit(croppedData),
              bitsPerPixel: self.bitsPerPixel,
              bytesPerRow: self.bytesPerRow,
              bitsPerComponent: self.bitsPerComponent,
              bytesPerPixel: self.bytesPerPixel,
              bitmapInfo: self.bitmapInfo,
              componentsPerPixel: self.componentsPerPixel,
              colorSpace: self.colorSpace
            )
            
        case .thirtyTwoBit(let arr):
            let pixelsPerRow = self.width * self.componentsPerPixel
            let startIndex = startRow * pixelsPerRow
            let endIndex = startIndex + cropHeight * pixelsPerRow
            let croppedData = Array(arr[startIndex..<endIndex])
            
            return PixelatedImage(
              width: self.width,
              height: cropHeight,
              imageData: .thirtyTwoBit(croppedData),
              bitsPerPixel: self.bitsPerPixel,
              bytesPerRow: self.bytesPerRow,
              bitsPerComponent: self.bitsPerComponent,
              bytesPerPixel: self.bytesPerPixel,
              bitmapInfo: self.bitmapInfo,
              componentsPerPixel: self.componentsPerPixel,
              colorSpace: self.colorSpace
            )
        }
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

extension NSImage {
    
    public func resized(to newSize: NSSize) -> NSImage? {
        if let bitmapRep = NSBitmapImageRep(
             bitmapDataPlanes: nil,
             pixelsWide: Int(newSize.width),
             pixelsHigh: Int(newSize.height),
             bitsPerSample: 8,
             samplesPerPixel: 4,
             hasAlpha: true,
             isPlanar: false,
             colorSpaceName: .calibratedRGB,
             bytesPerRow: 0, bitsPerPixel: 0
        ) {
            bitmapRep.size = newSize
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
            draw(in: NSRect(x: 0, y: 0, width: newSize.width, height: newSize.height), from: .zero, operation: .copy, fraction: 1.0)
            NSGraphicsContext.restoreGraphicsState()

            let resizedImage = NSImage(size: newSize)
            resizedImage.addRepresentation(bitmapRep)
            return resizedImage
        }

        return nil
    }
}

public extension NSImage {
    var jpegData: Data? {
        if let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
            if let data = bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [:]) {
                return data
            }
        }
        return nil
    }
}

extension ContiguousBytes {
    func objects<T>() -> [T] { withUnsafeBytes { .init($0.bindMemory(to: T.self)) } }

    // convert Data to [UInt32]
    public var uInt32Array: [UInt32] { objects() }

    // convert Data to [UInt16]
    public var uInt16Array: [UInt16] { objects() }

    // convert Data to [UInt8]
    public var uInt8Array: [UInt8] { objects() }
}

// convert a [UInt32] array to Data
extension Array<UInt32> {
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


import Accelerate

/// Averages N UInt16 buffers into one UInt16 buffer of the same length.
/// - Parameters:
///   - buffers: an array of pointers to UInt16 data (each length “count”)
///   - count: number of pixels per buffer
/// - Returns: a new [UInt16] where each element = sum(buffers[i][j]) / N
func averageBuffersAccelerate(
  _ buffers: [UnsafePointer<UInt16>],
  count: Int) -> [UInt16]
{
  // 1) Accumulate in Float
  var sum = [Float](repeating: 0, count: count)
  for ptr in buffers {
    // Convert UInt16 → Float
    var floatBuf = [Float](repeating: 0, count: count)
    vDSP.convertElements(
      of: UnsafeBufferPointer(start: ptr, count: count),
      to: &floatBuf
    )
    // sum += floatBuf
    vDSP.add(floatBuf, sum, result: &sum)
  }

  // 2) Divide each element by N
  let invN = Float(1) / Float(buffers.count)
  var avg = [Float](repeating: 0, count: count)
  vDSP.multiply(invN, sum, result: &avg)

  // 3) Clamp & convert back to UInt16
  var out = [UInt16](repeating: 0, count: count)
  for i in 0..<count {
      // clamp to valid UInt16 range just in case
      let v = avg[i]
      let floatValue = min(max(v, 0), Float(UInt16.max))
      if !floatValue.isNaN {
          out[i] = UInt16(floatValue)
      }
  }
  return out
}


func averageBuffersSwift(
  _ buffers: [[UInt16]]
) -> [UInt16] {
  guard let first = buffers.first else { return [] }
  let count = first.count
  let N = UInt64(buffers.count)
  var result = [UInt16](repeating: 0, count: count)

  // Perform the work in a single nested loop
  result.withUnsafeMutableBufferPointer { outPtr in
    for i in 0..<count {
      var sum: UInt64 = 0
      for buf in buffers {
        sum += UInt64(buf[i])
      }
      outPtr[i] = UInt16(sum / N)
    }
  }
  return result
}


extension PixelatedImage {
    // reassemble an image from matrix elements
    public convenience init(from matrixElements: [ImageMatrixElement]) {
        precondition(!matrixElements.isEmpty, "Matrix must contain at least one element")

        // Determine overall dimensions
        let maxX = matrixElements.map { $0.x + $0.width }.max() ?? 0
        let maxY = matrixElements.map { $0.y + $0.height }.max() ?? 0
        let width = maxX
        let height = maxY

        // Assume all tiles share the same pixel format
        let first = matrixElements[0].image

        let comps = first.componentsPerPixel
        let totalCount = width * height * comps

        switch first.imageData {
        case .unsafeSixteenBit:
            var buffer = [UInt16](repeating: 0, count: totalCount)
            for elem in matrixElements {
                guard case .unsafeSixteenBit(let subdata) = elem.image.imageData else { continue }
                for row in 0..<elem.height {
                    let destY = elem.y + row
                    let destBase = (destY * width + elem.x) * comps
                    let srcBase = row * elem.width * comps
                    let slice = subdata[srcBase ..< srcBase + elem.width * comps]
                    buffer.replaceSubrange(destBase ..< destBase + elem.width * comps, with: slice)
                }
            }
            self.init(width: width,
                      height: height,
                      imageData: .sixteenBit(buffer),
                      bitsPerPixel: first.bitsPerPixel,
                      bytesPerRow: width * first.bytesPerPixel,
                      bitsPerComponent: first.bitsPerComponent,
                      bytesPerPixel: first.bytesPerPixel,
                      bitmapInfo: first.bitmapInfo,
                      componentsPerPixel: comps,
                      colorSpace: first.colorSpace)
            
        case .unsafeEightBit(let buffer):
            var buffer = [UInt8](repeating: 0, count: totalCount)
            for elem in matrixElements {
                guard case .unsafeEightBit(let subdata) = elem.image.imageData else { continue }
                for row in 0..<elem.height {
                    let destY = elem.y + row
                    let destBase = (destY * width + elem.x) * comps
                    let srcBase = row * elem.width * comps
                    let slice = subdata[srcBase ..< srcBase + elem.width * comps]
                    buffer.replaceSubrange(destBase ..< destBase + elem.width * comps, with: slice)
                }
            }
            self.init(width: width,
                      height: height,
                      imageData: .eightBit(buffer),
                      bitsPerPixel: first.bitsPerPixel,
                      bytesPerRow: width * first.bytesPerPixel,
                      bitsPerComponent: first.bitsPerComponent,
                      bytesPerPixel: first.bytesPerPixel,
                      bitmapInfo: first.bitmapInfo,
                      componentsPerPixel: comps,
                      colorSpace: first.colorSpace)
            
        case .eightBit:
            var buffer = [UInt8](repeating: 0, count: totalCount)
            for elem in matrixElements {
                guard case .eightBit(let subdata) = elem.image.imageData else { continue }
                for row in 0..<elem.height {
                    let destY = elem.y + row
                    let destBase = (destY * width + elem.x) * comps
                    let srcBase = row * elem.width * comps
                    let slice = subdata[srcBase ..< srcBase + elem.width * comps]
                    buffer.replaceSubrange(destBase ..< destBase + elem.width * comps, with: slice)
                }
            }
            self.init(width: width,
                      height: height,
                      imageData: .eightBit(buffer),
                      bitsPerPixel: first.bitsPerPixel,
                      bytesPerRow: width * first.bytesPerPixel,
                      bitsPerComponent: first.bitsPerComponent,
                      bytesPerPixel: first.bytesPerPixel,
                      bitmapInfo: first.bitmapInfo,
                      componentsPerPixel: comps,
                      colorSpace: first.colorSpace)

        case .sixteenBit:
            var buffer = [UInt16](repeating: 0, count: totalCount)
            for elem in matrixElements {
                guard case .sixteenBit(let subdata) = elem.image.imageData else { continue }
                for row in 0..<elem.height {
                    let destY = elem.y + row
                    let destBase = (destY * width + elem.x) * comps
                    let srcBase = row * elem.width * comps
                    let slice = subdata[srcBase ..< srcBase + elem.width * comps]
                    buffer.replaceSubrange(destBase ..< destBase + elem.width * comps, with: slice)
                }
            }
            self.init(width: width,
                      height: height,
                      imageData: .sixteenBit(buffer),
                      bitsPerPixel: first.bitsPerPixel,
                      bytesPerRow: width * first.bytesPerPixel,
                      bitsPerComponent: first.bitsPerComponent,
                      bytesPerPixel: first.bytesPerPixel,
                      bitmapInfo: first.bitmapInfo,
                      componentsPerPixel: comps,
                      colorSpace: first.colorSpace)

        case .thirtyTwoBit:
            var buffer = [UInt32](repeating: 0, count: totalCount)
            for elem in matrixElements {
                guard case .thirtyTwoBit(let subdata) = elem.image.imageData else { continue }
                for row in 0..<elem.height {
                    let destY = elem.y + row
                    let destBase = (destY * width + elem.x) * comps
                    let srcBase = row * elem.width * comps
                    let slice = subdata[srcBase ..< srcBase + elem.width * comps]
                    buffer.replaceSubrange(destBase ..< destBase + elem.width * comps, with: slice)
                }
            }
            self.init(width: width,
                      height: height,
                      imageData: .thirtyTwoBit(buffer),
                      bitsPerPixel: first.bitsPerPixel,
                      bytesPerRow: width * first.bytesPerPixel,
                      bitsPerComponent: first.bitsPerComponent,
                      bytesPerPixel: first.bytesPerPixel,
                      bitmapInfo: first.bitmapInfo,
                      componentsPerPixel: comps,
                      colorSpace: first.colorSpace)
        }
    }
}

// holds the results of trying to align N number of frames with another base image
// aligned is a per pixel median of all properly aligned frames
// failed is a per pixel median of all frames which were not able to be aligned 
public struct AlignmentResult {
    public let aligned: PixelatedImage?
    public let failed: PixelatedImage?
    public let numAligned: Int
    public let numFailed: Int
}

extension PixelatedImage {

    public func align(
      frames: [PixelatedImage],
      masked mask: PixelatedImage? = nil,
      matchMethod: FeatureMatchMethod, // .knnLowes or .FLANN or .bruteForce
      maxDeviation: Double = 45, // maximum warping deviation from identity (GUESSED)
      maxCornerDeviation: Double = 70, // similar to max deviation, but for the corners
      invertMask: Bool = false, // use zero values instead of non zero values for the mask
      maxKeypoints: Int32 = 1000,       // XXX expose this and maxDeviation as parameters to user
      outlierThreshold: Double = 1.2
    ) -> AlignmentResult {
        let frameMats = frames.compactMap { $0.asMatWrapper }
        var maskMat: MatWrapper? = nil
        if let mask {
            maskMat = mask.asMatWrapper
        }

        var aligned: PixelatedImage? = nil
        var failed: PixelatedImage? = nil
        var numAligned: Int = 0
        var numFailed: Int = 0

        if let result = ImageAligner.alignFrames(
             self.asMatWrapper,
             frames: frameMats,
             matchMethod: matchMethod,//.knnLowes, // .knnLowes or .FLANN or .bruteForce
             mask: maskMat,
             maxDeviation: maxDeviation,
             maxCornerDeviation: maxCornerDeviation,
             invertMask: invertMask,
             maxKeypoints: maxKeypoints,
             outlierThreshold: outlierThreshold
           )
        {
            if let error = result as? String {
                Log.e("error: \(error)")
            } else if let result = result as? kht_bridge.AlignmentResult {

                if let mat = result.aligned {
                    // assumes self and processedMat have same bits per pixel, num components, etc.
                    if !mat.isEmpty {
                        aligned = PixelatedImage(mat: mat)
                    }
                }

                if let mat = result.failed {
                    // assumes self and processedMat have same bits per pixel, num components, etc.
                    if !mat.isEmpty {
                        failed = PixelatedImage(mat: mat)
                    }
                }
                numAligned = Int(result.numAligned)
                numFailed = Int(result.numFailed)
                
            } else {
                Log.e("cannot handle aligned result \(result)")
            }
        }

        return AlignmentResult(
          aligned: aligned,
          failed: failed,
          numAligned: numAligned,
          numFailed: numFailed
        )
    }
    
    // raises the mask by the given amount, creating a gradient
    // areas that were non zero and within borderAmount of the border
    // will be part of the gradient
    public func raiseMaskBy(_ borderAmount: Int) -> PixelatedImage? {
        if let matWrapper = self.asMatWrapper,
           let result = ImageAligner.createGradientMask(
             intoSky: matWrapper,
             gradientDistance: Int32(borderAmount))
        {
            return PixelatedImage(mat: result)
        } else {
            return nil
        }
    }
    
    // raises the mask by the given amount, creating a gradient
    // areas that were non zero and within borderAmount of the border
    // will be part of the gradient
    public func raiseLoweredBy(_ borderAmount: Int) -> PixelatedImage? {
        if let matWrapper = self.asMatWrapper,
           let result = ImageAligner.createGradientMask(
             intoGround: matWrapper,
             gradientDistance: Int32(borderAmount))
        {
            return PixelatedImage(mat: result)
        } else {
            return nil
        }
    }
    
    public func horizonBounds() throws -> HorizonBounds {
        // first convert images to cv::Mat
        if let baseMat = self.asMatWrapper {
            let bounds = PixelatedImageBridge.horizonExtents(fromImage: baseMat)

            return HorizonBounds(
              topY: bounds.horizonTopY,
              bottomY: bounds.horizonBottomY
            )
        }
        throw "cannot calculate horizon bounds without a mat wrapper"
    }

    public func maxBrightnessScale(in darksMask: PixelatedImage) throws -> Double {
        // first convert images to cv::Mat
        if let baseMat = self.asMatWrapper,
           let maskMat = darksMask.asMatWrapper
        {
            return PixelatedImageBridge.maxBrightnessScale(
              forImage: baseMat,
              maskImage: maskMat
            )
        }
        throw "cannot calculate max brightness scale without mat wrappers"
    }

    public func brightenDarks(with darksMask: PixelatedImage, by amount: Double) throws -> PixelatedImage {
        // first convert images to cv::Mat
        
        if let baseMat = self.asMatWrapper,
           let maskMat = darksMask.asMatWrapper
        {
            // then process in cv world
            let processedMat = PixelatedImageBridge.brightenDarks(
              baseMat,
              mask: maskMat,
              amount: amount
            )

            // then convert back in to PixelatedImage
            if let ret = PixelatedImage(mat: processedMat) { return ret }
        }
        throw "cannot brighten darks without a mat wrapper"
    }

    public func darkenDarks(with darksMask: PixelatedImage, by amount: Double) throws -> PixelatedImage {

        // first convert images to cv::Mat
        if let baseMat = self.asMatWrapper,
           let maskMat = darksMask.asMatWrapper
        {
            
            // then process in cv world
            let processedMat = PixelatedImageBridge.darkenDarks(
              baseMat,
              mask: maskMat,
              amount: amount
            )

            // then convert back in to PixelatedImage
            if let ret = PixelatedImage(mat: processedMat) { return ret }
        }
        throw "cannot darken darks without a mat wrapper"
    }

    public func apply(
      mask: PixelatedImage,
      with background: PixelatedImage
    ) throws -> PixelatedImage {

        if let selfMat = self.asMatWrapper,
           let backgroundMat = background.asMatWrapper,
           let maskMat = mask.asMatWrapper
        {
           let combinedMat =
             PixelatedImageBridge.combineImage(
               selfMat,
               mask: maskMat,
               background: backgroundMat
             )
           if let ret = PixelatedImage(mat: combinedMat) { return ret }
        }
        throw "Unable to apply mask to image without mask wrappers"
    }
}
    
extension MatWrapper: @unchecked Sendable {}
extension UnsafeBufferPointer: @unchecked Sendable {}

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
}

extension PixelatedImage {
    public var asMatWrapper: MatWrapper? {
        let cvType = MatWrapper.cvType(
          forBitsPerComponent: Int32(self.bitsPerComponent),
          componentsPerPixel: Int32(self.componentsPerPixel)
        )
        guard cvType != -1 else { return nil }

        switch self.imageData {
        case .unsafeSixteenBit(let buffer):
            if let baseAddress = buffer.baseAddress {
                return MatWrapper(
                  width: self.width,
                  height: self.height,
                  cvType: cvType,
                  bytesPerRow: self.bytesPerRow,
                  data: UnsafeMutableRawPointer(mutating: baseAddress),
                  takeOwnership: false
                )
            } else {
                return nil
            }

        case .unsafeEightBit(let buffer):
            if let baseAddress = buffer.baseAddress {
                return MatWrapper(
                  width: self.width,
                  height: self.height,
                  cvType: cvType,
                  bytesPerRow: self.bytesPerRow,
                  data: UnsafeMutableRawPointer(mutating: baseAddress),
                  takeOwnership: false
                )
            } else {
                return nil
            }
            
        case .eightBit(let arr):
            return arr.withUnsafeBufferPointer { buf in
                if let baseAddress = buf.baseAddress {
                    return MatWrapper(
                      width: self.width,
                      height: self.height,
                      cvType: cvType,
                      bytesPerRow: self.bytesPerRow,
                      data: UnsafeMutableRawPointer(mutating: baseAddress),
                      takeOwnership: false
                    )
                } else {
                    return nil
                }
            }
        case .sixteenBit(let arr):
            return arr.withUnsafeBufferPointer { buf in
                if let baseAddress = buf.baseAddress {
                    return MatWrapper(
                      width: self.width,
                      height: self.height,
                      cvType: cvType,
                      bytesPerRow: self.bytesPerRow,
                      data: UnsafeMutableRawPointer(mutating: baseAddress),
                      takeOwnership: false
                    )
                } else {
                    return nil
                }
            }
        case .thirtyTwoBit(let arr):
            return arr.withUnsafeBufferPointer { buf in
                if let baseAddress = buf.baseAddress {
                    return MatWrapper(
                      width: self.width,
                      height: self.height,
                      cvType: cvType,
                      bytesPerRow: self.bytesPerRow,
                      data: UnsafeMutableRawPointer(mutating: baseAddress),
                      takeOwnership: false
                    )
                } else {
                    return nil
                }
            }
        }
    }
}
