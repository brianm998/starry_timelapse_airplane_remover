/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import Cocoa

public func loadImage(fromFile filename: String) async throws -> NSImage? {
    Log.d("Loading image from \(filename)")
    let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)
    Log.d("loaded image url \(imageURL)")

    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))
    Log.d("got data for url \(imageURL)")
    if let image = NSImage(data: data) {
        Log.d("got image for url \(imageURL)")
        return image
    } else {
        return nil
    }
}

public struct PixelatedImage {
    let width: Int
    let height: Int
    
    let rawImageData: Data
    
    let bitsPerPixel: Int
    let bytesPerRow: Int
    let bitsPerComponent: Int
    let bytesPerPixel: Int
    let bitmapInfo: CGBitmapInfo

    let pixelOffset: Int

    let colorSpace: CGColorSpace // XXX why both space and name?
    let ciFormat: CIFormat    // used to write tiff formats properly
    
    init?(fromFile filename: String) async throws {
        Log.d("Loading image from \(filename)")
        if let nsImage = try await loadImage(fromFile: filename) {
            if let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                Log.d("F-Int init from \(filename) with cgImage \(cgImage)")
                self.init(cgImage)
                //Log.w("WTF")
            } else {
                //Log.w("SHIT")
                return nil
            }
        } else {
            //Log.w("CAKES")
            return nil
        }
    }
    
    init(width: Int,
         height: Int,
         rawImageData: Data,
         bitsPerPixel: Int,
         bytesPerRow: Int,
         bitsPerComponent: Int,
         bytesPerPixel: Int,
         bitmapInfo: CGBitmapInfo,
         pixelOffset: Int,
         colorSpace: CGColorSpace,
         ciFormat: CIFormat)    
    {
        self.width = width
        self.height = height
        self.rawImageData = rawImageData
        self.bitsPerPixel = bitsPerPixel
        self.bytesPerRow = bytesPerRow
        self.bitsPerComponent = bitsPerComponent
        self.bytesPerPixel = bytesPerPixel
        self.bitmapInfo = bitmapInfo
        self.pixelOffset = pixelOffset
        self.colorSpace = colorSpace
        self.ciFormat = ciFormat
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
        self.pixelOffset = image.bitsPerPixel/image.bitsPerComponent
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
            self.rawImageData = data
        } else {
            Log.e("DOH")
            return nil
        }
    }

    func read(_ closure: (UnsafeBufferPointer<UInt16>) throws -> Void) throws {
        try rawImageData.withUnsafeBytes { unsafeRawPointer in 
            let typedPointer: UnsafeBufferPointer<UInt16> = unsafeRawPointer.bindMemory(to: UInt16.self)
            try closure(typedPointer)
        }        
    }
    
    func readPixel(atX x: Int, andY y: Int) -> Pixel {
        let offset = (y * width*self.pixelOffset) + (x * self.pixelOffset)
        let pixel = rawImageData.withUnsafeBytes { unsafeRawPointer -> Pixel in 
            let typedPointer: UnsafeBufferPointer<UInt16> = unsafeRawPointer.bindMemory(to: UInt16.self)
            var pixel = Pixel()
            pixel.red = typedPointer[offset]
            pixel.green = typedPointer[offset+1]
            pixel.blue = typedPointer[offset+2]
            return pixel
        }
        return pixel
    }
    
    public func baseImage(ofSize size: NSSize) -> NSImage? {
        return self.baseImage?.resized(to: size)
    }

    public var baseImage: NSImage? {
        do {
            let base = try image(fromData: rawImageData) 
            return NSImage(cgImage: base, size: .zero)
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

    func baseImage(ofSize size: NSSize, fromData imageData: Data) -> NSImage? {
        do {
            let newImage = try image(fromData: imageData) 
            return NSImage(cgImage: newImage, size: size).resized(to: size)
        } catch {
            Log.e("\(error)")
        }
        return nil
    }
    
    // write out the base image data
    func writeTIFFEncoding(toFilename imageFilename: String) throws {
        try self.writeTIFFEncoding(ofData: self.rawImageData,
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

    static func loadUInt16Array(from imageFilename: String) async throws -> (PixelatedImage, [UInt16]) {
        // for some reason, these values are all one less from what was initially saved
        if let image = try await PixelatedImage(fromFile: imageFilename) {
            return (image, image.rawImageData.uInt16Array)
        }
        throw "could not load image for \(imageFilename)"
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
        let cgImage = self.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let bitmapRep = NSBitmapImageRep(cgImage: cgImage)
        if let data = bitmapRep.representation(using: NSBitmapImageRep.FileType.jpeg, properties: [:]) {
            return data
        }
        return nil
    }
}

extension ContiguousBytes {
    func objects<T>() -> [T] { withUnsafeBytes { .init($0.bindMemory(to: T.self)) } }
    var uInt16Array: [UInt16] { objects() }
}

fileprivate let fileManager = FileManager.default
