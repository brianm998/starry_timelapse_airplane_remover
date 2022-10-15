import Foundation
import CoreGraphics

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
    }

    private func readPixels() {
        Log.d("reading pixels for \(filename)")
        for x in 0 ..< self.width {
            var row: [Pixel] = []
            for y in 0 ..< self.height {
                row.append(self.readPixel(atX: x, andY: y))
            }
            pixels.append(row)
        }
    }

    private func readPixel(atX x: Int, andY y: Int) -> Pixel {
        guard let bytes = CFDataGetBytePtr(self.data) else { // XXX maybe move this out of here
            fatalError("Couldn't access image data")
        }
        
        var pixel = Pixel()
        let offset = (y * bytesPerRow) + (x * bytesPerPixel)
        // XXX this could be cleaner
        let r1 = UInt16(bytes[offset]) // lower bits
        let r2 = UInt16(bytes[offset + 1]) << 8 // higher bits
        pixel.red = r1 + r2
        let g1 = UInt16(bytes[offset+bitsPerComponent/8])
        let g2 = UInt16(bytes[offset+bitsPerComponent/8 + 1]) << 8
        pixel.green = g1 + g2
        let b1 = UInt16(bytes[offset+(bitsPerComponent/8)*2])
        let b2 = UInt16(bytes[offset+(bitsPerComponent/8)*2 + 1]) << 8
        pixel.blue = b1 + b2

        return pixel
    }
    
    func pixel(atX x: Int, andY y: Int) -> Pixel {
        if x < 0 || y < 0 || x >= self.width || y >= self.height {
            Log.e("FUCK")
            fatalError("FUCK")
        }
        if pixels.count == 0 {
            readPixels()
        }
        return pixels[x][y]
    }
}


