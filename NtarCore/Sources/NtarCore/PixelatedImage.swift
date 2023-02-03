/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import Cocoa

@available(macOS 10.15, *) 
public func loadImage(fromFile filename: String) async throws -> NSImage? {
    Log.d("Loading image from \(filename)")
    let imageURL = NSURL(fileURLWithPath: filename, isDirectory: false)

    let (data, _) = try await URLSession.shared.data(for: URLRequest(url: imageURL as URL))
    if let image = NSImage(data: data) {
        return image
    } else {
        return nil
    }
}

@available(macOS 10.15, *) 
public class PixelatedImage {
    let width: Int
    let height: Int
    //let image: CGImage
    
    let raw_image_data: Data
    
    let bitsPerPixel: Int
    let bytesPerRow: Int
    let bitsPerComponent: Int
    let bytesPerPixel: Int
    let bitmapInfo: CGBitmapInfo

    convenience init?(fromFile filename: String) async throws {
        Log.d("Loading image from \(filename)")
        if let nsImage = try await loadImage(fromFile: filename),
           let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            self.init(cgImage)
        } else {
            return nil
        }
    }
    
    init?(_ image: CGImage) {
        assert(image.colorSpace?.model == .rgb)
        //self.image = image // perhaps keeping the image around can help keep the raw data around?
        // doesn't seem so, still crashes :(
        self.width = image.width
        self.height = image.height
        self.bitsPerPixel = image.bitsPerPixel
        self.bytesPerRow = image.bytesPerRow
        self.bitsPerComponent = image.bitsPerComponent
        self.bytesPerPixel = self.bitsPerPixel / 8
        self.bitmapInfo = image.bitmapInfo

        if let data = image.dataProvider?.data as? Data {
            self.raw_image_data = data
        } else {
            Log.e("DOH")
            return nil
        }
    }

    func read(_ closure: (UnsafeBufferPointer<UInt16>) throws -> Void) throws {
        try raw_image_data.withUnsafeBytes { unsafeRawPointer in 
            let typedPointer: UnsafeBufferPointer<UInt16> = unsafeRawPointer.bindMemory(to: UInt16.self)
            try closure(typedPointer)
        }        
    }
    
    func readPixel(atX x: Int, andY y: Int) -> Pixel {
        let offset = (y * width*3) + (x * 3)
        let pixel = raw_image_data.withUnsafeBytes { unsafeRawPointer -> Pixel in 
            let typedPointer: UnsafeBufferPointer<UInt16> = unsafeRawPointer.bindMemory(to: UInt16.self)
            var pixel = Pixel()
            pixel.red = typedPointer[offset]
            pixel.green = typedPointer[offset+1]
            pixel.blue = typedPointer[offset+2]
            return pixel
        }
        return pixel
    }

    var baseImage: NSImage? {
        do {
            if let base = try image(fromData: raw_image_data) {
                return NSImage(cgImage: base, size: .zero)
            }
        } catch {
            Log.e("error \(error)")
        }
        return nil
    }
    
    func image(fromData image_data: Data) throws -> CGImage? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        if let dataProvider = CGDataProvider(data: image_data as CFData) {
           return CGImage(width: width,
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
        } else {
            return nil          // doh
        }
    }
    
    // write out the given image data as a 16 bit tiff file to the given filename
    // used when modifying the invariant original image data, and saying the edits to a file
    // XXX make this async
    func writeTIFFEncoding(ofData image_data: Data, toFilename image_filename: String) throws {

        if file_manager.fileExists(atPath: image_filename) {
            Log.w("not writing to already existing filename \(image_filename)")
            return
        }
        
        // create a CGImage from the data we just changed
        if let new_image = try image(fromData: image_data) {
            // save it
            //Log.d("new_image \(new_image)")

            let context = CIContext()
            let fileURL = NSURL(fileURLWithPath: image_filename, isDirectory: false) as URL
            let options: [CIImageRepresentationOption: CGFloat] = [:]
            if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
                let imgFormat = CIFormat.RGBA16

                try context.writeTIFFRepresentation(
                  of: CIImage(cgImage: new_image),
                  to: fileURL,
                  format: imgFormat,
                  colorSpace: colorSpace,
                  options: options
                )
                Log.i("image written to \(image_filename)")
            } else {
                Log.d("FUCK")
            }
        }
    }
}

fileprivate let file_manager = FileManager.default
