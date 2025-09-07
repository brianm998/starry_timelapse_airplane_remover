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

    let colorSpace: CGColorSpace // XXX why both space and name?
    let ciFormat: CIFormat    // used to write tiff formats properly
    
    // enum to bridge between Data and direct individual component access
    // do we have 8 bits per component, or 16?
    // pixels could have multiple components, or just one.
    public enum DataFormat: Sendable {

        // the number of bits per pixel, not per component
        case eightBit([UInt8])
        case sixteenBit([UInt16])
        case thirtyTwoBit([UInt32])
        // XXX add another for more bit depth
        
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
            case .eightBit(let arr):
                return arr.data
            case .sixteenBit(let arr):
                return arr.data
            case .thirtyTwoBit(let arr):
                return arr.data
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
                  colorSpace: CGColorSpaceCreateDeviceGray(),
                  ciFormat: .Af)
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
                  colorSpace: CGColorSpaceCreateDeviceGray(),
                  ciFormat: .L16)
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
                  colorSpace: CGColorSpaceCreateDeviceGray(),
                  ciFormat: .L8)
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
                ciFormat: CIFormat,
                file: String = #file,
                function: String = #function,
                line: Int = #line)    
    {
        self.file = file
        self.function = function
        self.line = line
        self.width = width
        self.height = height
        self.imageData = imageData
        self.bitsPerPixel = bitsPerPixel
        self.bytesPerRow = bytesPerRow
        self.bitsPerComponent = bitsPerComponent
        self.bytesPerPixel = bytesPerPixel
        self.bitmapInfo = bitmapInfo
        self.componentsPerPixel = componentsPerPixel
        self.colorSpace = colorSpace
        self.ciFormat = ciFormat
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
                              colorSpace: self.colorSpace,
                              ciFormat: self.ciFormat)
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

        let numComponentsPerPixel = image.bitsPerPixel / image.bitsPerComponent
        if numComponentsPerPixel == 1 {
            if bitsPerPixel == 8 {
                self.ciFormat = CIFormat.L8
            } else if bitsPerPixel == 16 {
                self.ciFormat = CIFormat.L16
            } else {
                self.ciFormat = CIFormat.RGBA16
            }
        } else if numComponentsPerPixel == 4 {
            if bitsPerPixel == 8 {
                self.ciFormat = CIFormat.RGBA8
            } else if bitsPerPixel == 16 {
                self.ciFormat = CIFormat.RGBA16
            } else {
                self.ciFormat = CIFormat.RGBA16
            }
        } else {
            self.ciFormat = CIFormat.RGBA16
        }

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
    func isZero(atX x: Int, andY y: Int) -> Bool {
        switch imageData {
        case .thirtyTwoBit(_):
            fatalError("not supported yet")
            break
            
        case .sixteenBit(let arr):
            let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
            let red = arr[offset]

            if red != 0 { return false }
            if self.componentsPerPixel >= 2 {
                let green = arr[offset+1]
                if green != 0 { return false }
            }
            if self.componentsPerPixel >= 3 {
                let blue = arr[offset+2]
                if blue != 0 { return false }
            }
            return true

        case .eightBit(let arr):
            let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
            let red = arr[offset]

            if red != 0 { return false }
            if self.componentsPerPixel >= 2 {
                let green = arr[offset+1]
                if green != 0 { return false }
            }
            if self.componentsPerPixel >= 3 {
                let blue = arr[offset+2]
                if blue != 0 { return false }
            }
            return true
        }
    }
    
    public func readPixel(atX x: Int, andY y: Int) -> Pixel {
        switch imageData {
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
        case .thirtyTwoBit(let arr):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if arr[offset] != 0 {
                        ret.append(SortablePixel(x: x + baseX,
                                                 y: y + baseY,
                                                 value: .thirtyTwoBit(arr[offset]))) // XXX numerical overflow was happening here :(
                    }
                }
            }
            
        case .sixteenBit(let arr):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if arr[offset] != 0 {
                        ret.append(SortablePixel(x: x + baseX,
                                                 y: y + baseY,
                                                 value: .sixteenBit(arr[offset])))
                    }
                }
            }
            
        case .eightBit(let arr):
            for x in 0..<width {
                for y in 0..<height {
                    let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
                    if arr[offset] != 0 {
                        ret.append(SortablePixel(x: x + baseX,
                                                 y: y + baseY,
                                                 value: .eightBit(arr[offset])))
                    }
                }
            }
        }
        return ret
    }
    
    func intensity(at pixel: SortablePixel) -> UInt {
        intensity(atX: pixel.x, andY: pixel.y)
    }

    func intensity(atX x: Int, andY y: Int) -> UInt {
        switch imageData {
        case .thirtyTwoBit(let arr):
            let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
            var intensity: UInt = 0
            if offset < arr.count {
                intensity += UInt(arr[offset])
                if self.componentsPerPixel >= 2 {
                    intensity += UInt(arr[offset+1])
                }
                if self.componentsPerPixel >= 3 {
                    intensity += UInt(arr[offset+2])
                }
                if self.componentsPerPixel == 4 {
                    intensity += UInt(arr[offset+3])
                }
            }
            return intensity

        case .sixteenBit(let arr):
            let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
            var intensity: UInt = 0
            if offset < arr.count {
                intensity += UInt(arr[offset])
                if self.componentsPerPixel >= 2 {
                    intensity += UInt(arr[offset+1])
                }
                if self.componentsPerPixel >= 3 {
                    intensity += UInt(arr[offset+2])
                }
                if self.componentsPerPixel == 4 {
                    intensity += UInt(arr[offset+3])
                }
            }
            return intensity

        case .eightBit(_):
            fatalError("not supported yet")
            break
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
        var pixelData = imageData

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

        let context = CIContext()
        let fileURL = NSURL(fileURLWithPath: imageFilename, isDirectory: false) as URL

        let options: [CIImageRepresentationOption: Any] = [:]
        var ciFormat: CIFormat = self.ciFormat

        if let newColorSpace = newImage.colorSpace,
           newColorSpace != self.colorSpace
        {
            if newColorSpace == CGColorSpaceCreateDeviceGray() {
                ciFormat = .L16 // XXX should handle other depths too
            }
        }
        
        try context.writeTIFFRepresentation(
          of: CIImage(cgImage: newImage),
          to: fileURL,
          format: ciFormat,
          colorSpace: newImage.colorSpace ?? self.colorSpace,
          options: options
        )
        Log.i("image written to \(imageFilename)")
    }
    
    // linearly merges all images together
    public func mergeWith(_ otherImages: [PixelatedImage]) throws -> PixelatedImage {
        Log.d("mergeWith \(otherImages.count) other images")
        switch self.imageData {
        case .eightBit(_):
            fatalError("cannot merge eight bit images")
        case .thirtyTwoBit(_):
            fatalError("cannot merge thirty two bit images")
        case .sixteenBit(let origImagePixels):
            var otherImagePixelList: [[UInt16]] = []
            for otherImage in otherImages {
                guard self.width == otherImage.width,
                      self.height == otherImage.height,
                      self.bitsPerPixel == otherImage.bitsPerPixel,
                      self.bytesPerRow == otherImage.bytesPerRow,
                      self.bitsPerComponent == otherImage.bitsPerComponent,
                      self.bytesPerPixel == otherImage.bytesPerPixel
                else {
                    fatalError("cannot merge images with different params")
                }
                switch otherImage.imageData {
                case .eightBit(_):
                    fatalError("cannot merge eight bit images")
                case .thirtyTwoBit(_):
                    fatalError("cannot merge thirty two bit images")
                case .sixteenBit(let otherImagePixels):
                    otherImagePixelList.append(otherImagePixels)
                }
            }


            Log.d("merge creating pointers")
            let pointers: [UnsafePointer<UInt16>] = otherImagePixelList.map { arr in
                arr.withUnsafeBufferPointer { buf in
                    guard let base = buf.baseAddress else {
                        fatalError("Buffer was empty!")
                    }
                    return base
                }
            }
            
            Log.d("merge about to create image data")
            let imageData = averageBuffersAccelerate(pointers, count: origImagePixels.count)

            /*
            var imageData = [UInt16](repeating: 0, count: origImagePixels.count)

            for i in 0..<imageData.count {
                if i % 1000 == 0 { Log.d("merging pixel \(i)") }

                var newValue: UInt32 = 0

                newValue += UInt32(origImagePixels[i])
                for otherImagePixels in otherImagePixelList {
                    newValue += UInt32(otherImagePixels[i])
                }
                newValue /= UInt32(otherImages.count + 1)
                if newValue >= UInt16.max {
                    newValue == UInt16.max
                }
                imageData[i] = UInt16(newValue)
            }
            */
            Log.d("mergeWith creating image")
            
            return .init(width: self.width,
                         height: self.height,
                         imageData: DataFormat(from: imageData),
                         bitsPerPixel: self.bitsPerPixel,
                         bytesPerRow: self.bytesPerRow,
                         bitsPerComponent: self.bitsPerComponent,
                         bytesPerPixel: self.bytesPerPixel,
                         bitmapInfo: .byteOrder16Little, 
                         componentsPerPixel: self.componentsPerPixel,
                         colorSpace: self.colorSpace,
                         ciFormat: self.ciFormat)
        }
    }
    
    // returns a 16 bit grayscale image that results from subtrating
    // the given frame from this frame, done in c++ opencv2 land for speed
    public func subtract(_ otherFrame: PixelatedImage) -> PixelatedImage {

        // convert images to cv::Mat
        let selfMat = self.cvMat
        let otherMat = otherFrame.cvMat

        // jump into c++ land for the actual subtraction
        let resultMat = PixelatedImageBridge.subtractImage(otherMat, fromImage: selfMat)

        // reconstruct a PixelatedImage from the returned cv::Mat
        let ret = self.newImage(from: resultMat)

        // free the c++ cv::Mat images
        PixelatedImageBridge.freeCvMat(resultMat)
        PixelatedImageBridge.freeCvMat(selfMat)
        PixelatedImageBridge.freeCvMat(otherMat)

        return ret
    }

    // returns a 16 bit grayscale image that results from subtrating
    // the given frame from this frame
    public func apply(
      mask: PixelatedImage,
      closure: (UInt16, UInt16, UInt16, Bool) -> (UInt16, UInt16, UInt16)
    ) -> PixelatedImage {
        switch self.imageData {
        case .eightBit(_):
            fatalError("NOT SUPPORTED YET")
        case .thirtyTwoBit(_):
            fatalError("NOT SUPPORTED YET")
        case .sixteenBit(let origImagePixels):
            
            switch mask.imageData {
                
            case .thirtyTwoBit(_):
                fatalError("NOT SUPPORTED YET")
            case .sixteenBit(_):
                fatalError("NOT SUPPORTED YET")
            case .eightBit(let maskPixels):
                let numPixels = width*height
                var outputData = [UInt16](repeating: 0, count: origImagePixels.count)
                
                for i in 0 ..< numPixels {
                    let origOffset = i*self.componentsPerPixel
                    let otherOffset = i*mask.componentsPerPixel
                    
                    // rgb values of the image we're modifying at this index
                    let origRed   = origImagePixels[origOffset]
                    let origGreen = origImagePixels[origOffset+1]
                    let origBlue  = origImagePixels[origOffset+2]
                    
                    // rgb values of an adjecent image at this index
                    let isInMask = maskPixels[otherOffset] != 0

                    let (newRed, newGreen, newBlue) = closure(origRed, origGreen, origBlue, isInMask)
                    
                    outputData[origOffset] = newRed
                    outputData[origOffset+1] = newGreen
                    outputData[origOffset+2] = newBlue
                }
                
                return PixelatedImage(
                  width: width,
                  height: height,
                  imageData: DataFormat(from: outputData),
                  bitsPerPixel: self.bitsPerPixel,
                  bytesPerRow: self.bytesPerRow,
                  bitsPerComponent: self.bitsPerComponent,
                  bytesPerPixel: self.bytesPerPixel,
                  bitmapInfo: self.bitmapInfo,
                  componentsPerPixel: self.componentsPerPixel,
                  colorSpace: self.colorSpace,
                  ciFormat: self.ciFormat
                )
            }
        }
    }

    public func flipSky(with mask: PixelatedImage) -> PixelatedImage {
        self.apply(mask: mask) { r, g, b, inMask in
            if inMask {
                return (
                  UInt16.max - r,
                  UInt16.max - g,
                  UInt16.max - b
                )
            } else {
                return (r, g, b)
            }
        }
    }
    
    public func flipGround(with mask: PixelatedImage) -> PixelatedImage {
        self.apply(mask: mask) { r, g, b, inMask in
            if inMask {
                return (r, g, b)
            } else {
                return (
                  UInt16.max - r,
                  UInt16.max - g,
                  UInt16.max - b
                )
            }
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
                Log.i("matrix height \(matrixHeight)")
                if matrixWidth > 0,
                   matrixHeight > 0
                {
                    switch imageData {
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
                              colorSpace: self.colorSpace,
                              ciFormat: self.ciFormat
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
              colorSpace: self.colorSpace,
              ciFormat: self.ciFormat
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
              colorSpace: self.colorSpace,
              ciFormat: self.ciFormat
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
              colorSpace: self.colorSpace,
              ciFormat: self.ciFormat
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
                      colorSpace: first.colorSpace,
                      ciFormat: first.ciFormat)

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
                      colorSpace: first.colorSpace,
                      ciFormat: first.ciFormat)

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
                      colorSpace: first.colorSpace,
                      ciFormat: first.ciFormat)
        }
    }
}

extension PixelatedImage {

    public func align(
      frames: [PixelatedImage],
      masked mask: PixelatedImage? = nil,
      invertMask: Bool = false, // use zero values instead of non zero values for the mask
      invertBrightness: Bool = false, // flip the brightness before finding keypoints
      maxKeypoints: Int32 = 500
    ) -> [PixelatedImage] {
        let baseMat = self.cvMat
        let frameMats = frames.map { $0.cvMat }
        var maskMat: Mat? = nil
        if let mask {
            maskMat = mask.cvMat
        }

        let wrappedFrames = frameMats.map { NSValue(pointer: $0) }

        var ret: [PixelatedImage] = []
        if let aligned = ImageAligner.alignFrames(
             baseMat,
             frames: wrappedFrames,
             mask: maskMat,
             invertMask: invertMask,
             invertBrightness: invertBrightness,
             maxKeypoints: maxKeypoints
           )
        {
            if let aligned = aligned as? String {
                Log.e("error: \(aligned)")
            } else if let aligned = aligned as? [NSValue] {
                // Unwrap results
                for wrapped in aligned {
                    if let matPtr = wrapped.pointerValue {
                        // assumes self and processedMat have same bits per pixel, num components, etc.
                        ret.append(self.newImage(from: matPtr))
                        PixelatedImageBridge.freeCvMat(matPtr)
                    }
                }
            } else {
                Log.e("cannot handle aligned \(aligned)")
            }
        }

        PixelatedImageBridge.freeCvMat(baseMat)

        for frameMat in frameMats {
            PixelatedImageBridge.freeCvMat(frameMat)
        }

        if let maskMat {
            PixelatedImageBridge.freeCvMat(maskMat)
        }

        return ret
    }
    
    public var horizonBounds: HorizonBounds {
        // first convert images to cv::Mat
        let baseMat = self.cvMat
        
        let bounds = PixelatedImageBridge.horizonExtents(fromImage: baseMat)

        PixelatedImageBridge.freeCvMat(baseMat)
        
        return HorizonBounds(
          topY: bounds.horizonTopY,
          bottomY: bounds.horizonBottomY
        )
    }

    // slow, but it works
    public func maskRaisedBy(borderAmount: Int, mask: PixelatedImage) -> PixelatedImage {
        switch self.imageData {
        case .eightBit(_):
            fatalError("NOT SUPPORTED YET")
        case .thirtyTwoBit(_):
            fatalError("NOT SUPPORTED YET")
        case .sixteenBit(let origImagePixels):
            
            switch mask.imageData {
                
            case .thirtyTwoBit(_):
                fatalError("NOT SUPPORTED YET")
            case .sixteenBit(_):
                fatalError("NOT SUPPORTED YET")
            case .eightBit(let maskPixels):
                let numPixels = width*height
                var outputData = origImagePixels

                for y in 0 ..< self.height {
                    for x in 0 ..< self.width {
                        let origOffset = (y*self.width+x)*self.componentsPerPixel

                        if y+borderAmount < self.height {
                            let otherOffset = ((y+borderAmount)*self.width+x)*mask.componentsPerPixel
                            if maskPixels[otherOffset] != 0 {
                                outputData[origOffset] = UInt16.max  
                                outputData[origOffset+1] = UInt16.max  
                                outputData[origOffset+2] = UInt16.max  
                            }
                        }
                    }
                }

                return PixelatedImage(
                  width: width,
                  height: height,
                  imageData: DataFormat(from: outputData),
                  bitsPerPixel: self.bitsPerPixel,
                  bytesPerRow: self.bytesPerRow,
                  bitsPerComponent: self.bitsPerComponent,
                  bytesPerPixel: self.bytesPerPixel,
                  bitmapInfo: self.bitmapInfo,
                  componentsPerPixel: self.componentsPerPixel,
                  colorSpace: self.colorSpace,
                  ciFormat: self.ciFormat
                )
            }
        }
    }

    // a whole lot faster than the one above
    public func maskRaisedBy_SOMETIMES_CRASHES(borderAmount: Int, mask: PixelatedImage) -> PixelatedImage {
        let baseMat = self.cvMat
        let maskMat = mask.cvMat

        let processedMat = PixelatedImageBridge.maskRaised(
          by: baseMat,
          mask: maskMat,
          border: Int32(borderAmount)
        )
        
        // then convert back in to PixelatedImage
        return self.newImage(from: processedMat)
    }

    
    public func maxBrightnessScale(in darksMask: PixelatedImage) -> Double {
        // first convert images to cv::Mat
        let baseMat = self.cvMat
        let maskMat = darksMask.cvMat

        let ret = PixelatedImageBridge.maxBrightnessScale(
          forImage: baseMat,
          maskImage: maskMat
        )
        
        // finally free the cv::Mat pointers
        PixelatedImageBridge.freeCvMat(baseMat)
        PixelatedImageBridge.freeCvMat(maskMat)

        return ret
    }

    public func brightenDarks(with darksMask: PixelatedImage, by amount: Double) -> PixelatedImage {
        // first convert images to cv::Mat

        
        let baseMat = self.cvMat
        let maskMat = darksMask.cvMat

        // then process in cv world
        let processedMat = PixelatedImageBridge.brightenDarks(
          baseMat,
          mask: maskMat,
          amount: amount
        )

        // then convert back in to PixelatedImage
        let ret = self.newImage(from: processedMat)

        // finally free the cv::Mat pointers
        PixelatedImageBridge.freeCvMat(baseMat)
        PixelatedImageBridge.freeCvMat(maskMat)
        PixelatedImageBridge.freeCvMat(processedMat)
        
        return ret
    }

    public func darkenDarks(with darksMask: PixelatedImage, by amount: Double) -> PixelatedImage {

        // first convert images to cv::Mat
        let baseMat = self.cvMat
        let maskMat = darksMask.cvMat
        
        // then process in cv world
        let processedMat = PixelatedImageBridge.darkenDarks(
          baseMat,
          mask: maskMat,
          amount: amount
        )

        // then convert back in to PixelatedImage
        let ret = self.newImage(from: processedMat)

        // finally free the cv::Mat pointers
        PixelatedImageBridge.freeCvMat(baseMat)
        PixelatedImageBridge.freeCvMat(maskMat)
        PixelatedImageBridge.freeCvMat(processedMat)
        
        return ret
    }

    public func apply(
      mask: PixelatedImage,
      with background: PixelatedImage
    ) -> PixelatedImage {
        let selfMat = self.cvMat
        let backgroundMat = background.cvMat
        let maskMat = mask.cvMat
            
        let combinedMat =
          PixelatedImageBridge.combineImage(
            selfMat,
            mask: maskMat,
            background: backgroundMat
          )

        let combinedImage = self.newImage(from: combinedMat)
        
        PixelatedImageBridge.freeCvMat(selfMat)
        PixelatedImageBridge.freeCvMat(backgroundMat)
        PixelatedImageBridge.freeCvMat(maskMat)
        PixelatedImageBridge.freeCvMat(combinedMat)

        return combinedImage
    }
}

// simple swift wrappers over the ObjC -> OpenCV bridge
extension PixelatedImage {
    // convert any PixelatedImage directly into a cv::Mat for opencv2 processing
    // need to be freed (c++ delete) after opencv2 is done by PixelatedImageBridge.freeCvMat(_)
    public var cvMat: Mat { PixelatedImageBridge.cvMat(from: self) }

    // convert a mat back into a PixelatedImage, using an the self image
    // for image bitmapInfo, colorSpace, and ciFormat
    public func newImage(
      from mat: Mat
    ) -> PixelatedImage {
        PixelatedImageBridge.pixelatedImage(
          from: mat,
          bitmapInfo: self.bitmapInfo,
          colorSpace: self.colorSpace,
          ciFormat: self.ciFormat
        )
    }
}
    
// swift extesion to objc code that bridges between cv::Mat and PixleatedImage
extension PixelatedImageBridge {
    
    static func cvMat(from image: PixelatedImage) -> Mat {
        var data = image.imageData.data
        return data.withUnsafeMutableBytes { buf in
            Self.cvMat(
              fromBuffer: buf.baseAddress!,
              width: Int32(image.width),
              height: Int32(image.height),
              channels: Int32(image.componentsPerPixel),
              bitsPerChannel: Int32(image.bitsPerComponent),
              bytesPerRow: Int32(image.bytesPerRow)
            )
        }
    }

    static func pixelatedImage(
      from mat: Mat,
      bitmapInfo: CGBitmapInfo,
      colorSpace: CGColorSpace,
      ciFormat: CIFormat) -> PixelatedImage
    {
        let nsdata = Self.data(fromCvMat: mat)
        let bytes = [UInt8](nsdata)

        let channels = Int(Self.matChannels(mat))
        let bytesPerPixel = Int(Self.matElemSize(mat))
        let step = Int(Self.matStep(mat))
        Log.d("channels \(channels) bytesPerPixel \(bytesPerPixel)")
        let bitsPerComponent = bytesPerPixel / channels * 8

        let df: PixelatedImage.DataFormat
        switch bitsPerComponent {
        case 8: df = .eightBit(bytes)
        case 16: df = .sixteenBit(nsdata.uInt16Array)
        case 32: df = .thirtyTwoBit(nsdata.uInt32Array)
        default: fatalError("Unsupported depth \(bitsPerComponent)")
        }

        let width = step/bytesPerPixel
        let height = nsdata.count / (width*bytesPerPixel)

        return PixelatedImage(
          width: width,
          height: height,
          imageData: df,
          bitsPerPixel: bytesPerPixel*8,
          bytesPerRow: step,
          bitsPerComponent: bytesPerPixel/channels*8,
          bytesPerPixel: bytesPerPixel,
          bitmapInfo: bitmapInfo,
          componentsPerPixel: channels,
          colorSpace: colorSpace,
          ciFormat: ciFormat
        )
    }
}
