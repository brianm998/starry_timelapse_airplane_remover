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

public struct ImageMatrixElement {
    public let x: Int                  // offset in original image
    public let y: Int
    public let image: PixelatedImage
}

public struct PixelatedImage {
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
    public enum DataFormat {

        // the number of bits per pixel, not per component
        case eightBit([UInt8])
        case sixteenBit([UInt16])

        init(from array: [UInt8]) {
            self = .eightBit(array)
        }

        init(from array: [UInt16]) {
            self = .sixteenBit(array)
        }

        var data: Data {
            switch self {
            case .eightBit(let arr):
                return arr.data
            case .sixteenBit(let arr):
                return arr.data
            }
        }
    }

    public init?(fromFile filename: String) async throws {
        //Log.d("Loading image from \(filename)")
        if let nsImage = try await loadImage(fromFile: filename) {
            if let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                self.init(cgImage)
            } else {
                return nil
            }
        } else {
            return nil
        }
    }
    
    public init(width: Int,
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

    public init(width: Int,
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
               ciFormat: CIFormat)    
    {
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
    
    init?(_ image: CGImage) {
        //Log.w("START")
        // assert(image.colorSpace?.model == .rgb)
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
        } else {
            Log.e("DOH")
            return nil
        }
    }

    func readPixel(atX x: Int, andY y: Int) -> Pixel {
        switch imageData {
        case .sixteenBit(let arr):
            let offset = (y * width*self.componentsPerPixel) + (x * self.componentsPerPixel)
            var pixel = Pixel()
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

    // splits image into a matrix of chunked elements of a max size
    public func splitIntoMatrix(maxWidth: Int, maxHeight: Int) -> [ImageMatrixElement] {

        // XXX only works on grayscale
        // XXX add a check for this
        
        let matrixMaxWidth = Int(Double(width)/Double(maxWidth))
        let matrixMaxHeight = Int(Double(height)/Double(maxHeight))

        var matrix: [ImageMatrixElement] = []
        for matrixY in 0...matrixMaxHeight {
            for matrixX in 0...matrixMaxWidth {
                let xOffset = matrixX*maxWidth
                let yOffset = matrixY*maxHeight
                var matrixWidth = maxWidth
                if xOffset + matrixWidth > width {
                    matrixWidth = width - xOffset
                }
                var matrixHeight = maxHeight
                if yOffset + matrixHeight > height {
                    matrixHeight = height - yOffset
                }

                switch imageData {
                case .sixteenBit(let arr):
                    
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
                    Log.i("matrix width \(matrixWidth) matrix height \(matrixHeight)")
                    let element = ImageMatrixElement(x: xOffset,
                                                     y: yOffset,
                                                     image: matrixImage)
                    matrix.append(element)
                    
                case .eightBit(_):
                    Log.e("eight bit not yet implemented")
                    break       // XXX do this too
                
                }
            }
        }
        Log.d("matrix  has \(matrix.count) rows")
        return matrix
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
        if let dataProvider = CGDataProvider(data: imageData as CFData) {
            if let image = CGImage(width: width, 
                                   height: height,
                                   bitsPerComponent: bitsPerComponent,
                                   bitsPerPixel: bytesPerPixel*8,
                                   bytesPerRow: width*bytesPerPixel,
                                   space: colorSpace,
                                   bitmapInfo: bitmapInfo,
                                   provider: dataProvider,
                                   decode: nil,
                                   shouldInterpolate: false,
                                   intent: .defaultIntent)
            {
                return image
            } else {
                let message = "could not create CGImage from data"
                Log.e(message)
                throw message
            }
        } else {
            let message = "could not create CGImage with no data provider"
            Log.e(message)
            throw message
        }
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
    
    public func kernelHoughTransform(clusterMinSize: Int32 = 10,
                                     clusterMinDeviation: Double = 2.0,
                                     delta: Double = 0.5,
                                     kernelMinHeight: Double = 0.002,
                                     nSigmas: Double = 2.0,
                                     maxThetaDiff: Double = 5,
                                     maxRhoDiff: Double = 4,
                                     minCount: Int = 20) -> [Line]
    {
        if let image = self.nsImage {
            return KHTSwift.kernelHoughTransform(image: image,
                                                 clusterMinSize: clusterMinSize,
                                                 clusterMinDeviation: clusterMinDeviation,
	                                         delta: delta,
                                                 kernelMinHeight: kernelMinHeight,
                                                 nSigmas: nSigmas,
                                                 maxThetaDiff: maxThetaDiff,
                                                 maxRhoDiff: maxRhoDiff,
                                                 minCount: minCount)
        }
        return []
    }

    // write out the base image data
    public func writeTIFFEncoding(toFilename imageFilename: String) throws {
        try self.writeTIFFEncoding(ofData: self.imageData.data,
                                   toFilename: imageFilename)
    }

    // write out the given image data as a 16 bit tiff file to the given filename
    // used when modifying the invariant original image data, and saying the edits to a file
    // XXX make this async
    func writeTIFFEncoding(ofData imageData: Data,
                           toFilename imageFilename: String) throws
    {
        if fileManager.fileExists(atPath: imageFilename) {
            Log.i("overwriting already existing filename \(imageFilename)")
            try fileManager.removeItem(atPath: imageFilename)
        }
        
        // create a CGImage from the data we just changed
        let newImage = try image(fromData: imageData) 
        // save it
        //Log.d("newImage \(newImage)")

        let context = CIContext()
        let fileURL = NSURL(fileURLWithPath: imageFilename, isDirectory: false) as URL
        let options: [CIImageRepresentationOption: CGFloat] = [:]

        try context.writeTIFFRepresentation(
          of: CIImage(cgImage: newImage),
          to: fileURL,
          format: ciFormat,
          colorSpace: colorSpace,
          options: options
        )
        Log.i("image written to \(imageFilename)")
    }

    // returns a 16 bit grayscale image that results from subtrating
    // the given frame from this frame
    public func subtract(_ otherFrame: PixelatedImage) -> PixelatedImage {
        switch self.imageData {
        case .eightBit(_):
            fatalError("NOT SUPPORTED YET")
        case .sixteenBit(let origImagePixels):
            
            switch otherFrame.imageData {
                
            case .eightBit(_):
                fatalError("NOT SUPPORTED YET")
            case .sixteenBit(let otherImagePixels):
                // the grayscale image pixel array to return when we've calculated it
                let numPixels = width*height
                var subtractionArray = [UInt16](repeating: 0, count: numPixels)
                
                // compare pixels at the same image location in adjecent frames
                // detect Outliers which are much more brighter than the adject frames

                for i in 0 ..< numPixels {
                    let origOffset = i*self.componentsPerPixel
                    let otherOffset = i*otherFrame.componentsPerPixel

                    var maxBrightness: Int32 = 0
                    
                    if otherFrame.componentsPerPixel == 4,
                       otherImagePixels[otherOffset+3] != 0xFFFF
                    {
                        // ignore any partially or fully transparent pixels
                        // these crop up in the star alignment images
                        // there is nothing to copy from these pixels
                    } else {
                        // rgb values of the image we're modifying at this index
                        let origRed   = Int32(origImagePixels[origOffset])
                        let origGreen = Int32(origImagePixels[origOffset+1])
                        let origBlue  = Int32(origImagePixels[origOffset+2])
                        
                        // rgb values of an adjecent image at this index
                        let otherRed   = Int32(otherImagePixels[otherOffset])
                        let otherGreen = Int32(otherImagePixels[otherOffset+1])
                        let otherBlue  = Int32(otherImagePixels[otherOffset+2])

                        maxBrightness += origRed  + origGreen  + origBlue
                        maxBrightness -= otherRed + otherGreen + otherBlue
                    }
                    // record the brightness change if it is brighter
                    if maxBrightness > 0 {
                        subtractionArray[i] = UInt16(maxBrightness/3)
                    }
                }
                
                return PixelatedImage(width: width,
                                      height: height,
                                      grayscale16BitImageData: subtractionArray)
                
            }
        }
    }
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

    // convert Data to [UInt16]
    var uInt16Array: [UInt16] { objects() }

    // convert Data to [UInt8]
    var uInt8Array: [UInt8] { objects() }
}

// convert a [UInt16] array to Data
extension Array<UInt16> {
    var data: Data {
        let data = self.withUnsafeBufferPointer { Data(buffer: $0) }
        return data
    }
}

// convert a [UInt8] array to Data
extension Array<UInt8> {
    var data: Data {
        let data = self.withUnsafeBufferPointer { Data(buffer: $0) }
        return data
    }
}

fileprivate func loadImage(fromFile filename: String) async throws -> NSImage? {
    //Log.d("Loading image from \(filename)")
    let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
    //Log.d("loaded image url \(imageURL)")

    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))
    //Log.d("got data for url \(imageURL)")
    if let image = NSImage(data: data) {
        Log.d("got image for url \(imageURL)")
        return image
    } else {
        return nil
    }
}

fileprivate let fileManager = FileManager.default

