import Foundation
import CoreGraphics
import Cocoa

@available(macOS 10.15, *) 
actor PixelatedImage {
    let image: CGImage
    let filename: String
    let width: Int
    let height: Int
    let data: CFData
    
    let bitsPerPixel: Int
    let bytesPerRow: Int
    let bitsPerComponent: Int
    let bytesPerPixel: Int
    let image_buffer_ptr: UnsafePointer<UInt8>
    
    var pixels = [[Pixel]]()
    
    init?(_ image: CGImage, filename: String) {
        self.filename = filename
        self.image = image
        assert(self.image.colorSpace?.model == .rgb)
        self.width = image.width
        self.height = image.height
        self.bitsPerPixel = self.image.bitsPerPixel
        self.bytesPerRow = self.image.bytesPerRow
        self.bitsPerComponent = self.image.bitsPerComponent
        self.bytesPerPixel = self.bitsPerPixel / 8

        if let data = image.dataProvider?.data {
            self.data = data
        } else {
            Log.e("DOH")
            return nil
        }
        guard let _bytes = CFDataGetBytePtr(self.data) else { // XXX maybe move this out of here
            fatalError("Couldn't access image data")
        }
        self.image_buffer_ptr = _bytes
    }

    private func readPixels() {
        let start_time = NSDate().timeIntervalSince1970
        Log.d("reading pixels for \(filename)")
        for x in 0 ..< self.width {
            var row: [Pixel] = []
            for y in 0 ..< self.height {
                row.append(self.readPixel(atX: x, andY: y))
            }
            pixels.append(row)
        }
        let end_time = NSDate().timeIntervalSince1970
        Log.d("reading pixels for \(filename) took \(end_time-start_time) seconds")
    }

    private func readPixel(atX x: Int, andY y: Int) -> Pixel {
        var pixel = Pixel()
        let offset = (y * bytesPerRow) + (x * bytesPerPixel)
        // XXX this could be cleaner
        let r1 = UInt16(image_buffer_ptr[offset]) // lower bits
        let r2 = UInt16(image_buffer_ptr[offset + 1]) << 8 // higher bits
        pixel.red = r1 + r2
        let g1 = UInt16(image_buffer_ptr[offset+bitsPerComponent/8])
        let g2 = UInt16(image_buffer_ptr[offset+bitsPerComponent/8 + 1]) << 8
        pixel.green = g1 + g2
        let b1 = UInt16(image_buffer_ptr[offset+(bitsPerComponent/8)*2])
        let b2 = UInt16(image_buffer_ptr[offset+(bitsPerComponent/8)*2 + 1]) << 8
        pixel.blue = b1 + b2

        return pixel
    }
    
    func pixel(atX x: Int, andY y: Int) -> Pixel {
        if x < 0 || y < 0 || x >= self.width || y >= self.height {
            Log.e("FUCK")
            fatalError("FUCK")
        }
        // lazy load the entire pixel set upon first access
        if pixels.count == 0 { 
            readPixels()
        }
        return pixels[x][y]
    }

    // write out the given image data as a 16 bit tiff file to the given filename
    // used when modifying the invariant original image data, and saying the edits to a file
    nonisolated func writeTIFFEncoding(ofData image_data: Data, toFilename image_filename: String) {
        // create a CGImage from the data we just changed
        if let dataProvider = CGDataProvider(data: image_data as CFData) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            if let new_image =  CGImage(width: width,
                                        height: height,
                                        bitsPerComponent: bitsPerComponent,
                                        bitsPerPixel: bytesPerPixel*8,
                                        bytesPerRow: width*bytesPerPixel,
                                        space: colorSpace,
                                        bitmapInfo: self.image.bitmapInfo, // byte order
                                        provider: dataProvider,
                                        decode: nil,
                                        shouldInterpolate: false,
                                        intent: .defaultIntent) {

                // save it
                Log.d("new_image \(new_image)")
                do {
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
                    } else {
                        Log.d("FUCK")
                    }
                } catch {
                    Log.e("doh! \(error)")
                }
            }
        }
    }
}

