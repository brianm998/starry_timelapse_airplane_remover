import Foundation
import CoreGraphics
import Cocoa

if CommandLine.arguments.count < 1 {
    print("need more args!")    // XXX make this better
} else {
    let path = FileManager.default.currentDirectoryPath
    let input_image_sequence_dirname = CommandLine.arguments[1]
    print("will process \(input_image_sequence_dirname)")
    print("on path \(path)")
    var image_files = list_image_files(atPath: "\(path)/\(input_image_sequence_dirname)")
    image_files.sort { (lhs: String, rhs: String) -> Bool in
        let lh = remove_suffix(fromString: lhs)
        let rh = remove_suffix(fromString: rhs)
        return lh < rh
    }
    print("image_files \(image_files)")

    let images = try load(imageFiles: image_files)
    print("loaded images \(images)")

//    images.forEach { image in
//    dump_pixels(fromImage: images[0]) { pixel, x, y in
//        print("[\(x), \(y)] - r: '\(pixel.red)' g: '\(pixel.green)' b: '\(pixel.blue)")
//    }

    if let foo = copy(image: images[0]) {
        print("foo \(foo)")

        do {
            try save(image: foo, toFile: "foobar2.tif")
        } catch {
            print("doh! \(error)")
        }
    }
    // XXX next figure out how to save this poo as a tiff file

    // XXX then update applyFilter logic to do what I want
}

func save2(image cgImage: CGImage, toFile filename: String) {
    // maybe try using ImageIO to get rid of alpha channel?
}

func save(image cgImage: CGImage, toFile filename: String) throws {
    let context = CIContext()
    let fileURL = NSURL(fileURLWithPath: filename, isDirectory: false) as URL
    let options: [CIImageRepresentationOption: CGFloat] = [:]
    if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
        let imgFormat = CIFormat.RGBA16
//      let imgFormat = CIFormat.RGB16 XXX alpha?


        if #available(macOS 10.12, *) {
            try context.writeTIFFRepresentation(
                of: CIImage(cgImage: cgImage),
                to: fileURL,
                format: imgFormat,
                colorSpace: colorSpace,
                options: options
            )

        }        
    } else {
        print("FUCK")
    }
}


public struct Pixel {
    public var value: UInt64

    public init() {
        self.value = 0
    }

    public var description: String {
        return "Pixel: r: '\(self.red)' g: '\(self.green)' b: '\(self.blue)"
    }
    
    public var red: UInt16 {
        get {
            return UInt16(value & 0xFFFF)
        } set {
            value = UInt64(newValue) | (value & 0xFFFFFFFFFFFF0000)
        }
    }
    
    public var green: UInt16 {
        get {
            return UInt16((value >> 16) & 0xFFFF)
        } set {
            value = (UInt64(newValue) << 16) | (value & 0xFFFFFFFF0000FFFF)
        }
    }
    
    public var blue: UInt16 {
        get {
            return UInt16((value >> 32) & 0xFFFF)
        } set {
            value = (UInt64(newValue) << 32) | (value & 0xFFFF0000FFFFFFFF)
        }
    }
    
    public var alpha: UInt16 {
        get {
            return UInt16((value >> 48) & 0xFFFF)
        } set {
            value = (UInt64(newValue) << 48) | (value & 0x0000FFFFFFFFFFFF)
        }
    }
}

func createImage() -> CGImage? {

    let width = 4
    let height = 4
    let bytesPerPixel = 6
    let bitsPerComponent = 16
    let bytesPerRow = width*bytesPerPixel

    var data = Data(count: width * height * bytesPerPixel)

    for y in 0 ..< height {
        for x in 0 ..< width {
            let offset = (y * bytesPerRow) + (x * bytesPerPixel)
            //var nextPixel: UInt64 = 0xFFFFFFFFFFFFFFFF // white
            //var nextPixel: UInt64 = 0x00FFFFFFFFFFFFFF // white
            //var nextPixel: UInt64 = 0x0000FFFFFFFFFFFF // white
            //var nextPixel: UInt64 = 0x000000FFFFFFFFFF // white
            //var nextPixel: UInt64 = 0x00000000FFFFFFFF // yellow
            //var nextPixel: UInt64 = 0x0000000000FFFFFF // yellow
            //var nextPixel: UInt64 = 0x000000000000FFFF // red
            //var nextPixel: UInt64 = 0x00000000000000FF // red
            //var nextPixel: UInt64 = 0x0000000000FF0000 // green
            //var nextPixel: UInt64 = 0x000000FF00000000 // blue

            var nextPixel = Pixel()
            if(y % 3 == 0) {
                nextPixel.red = 0xFFFF
            } else if(y % 3 == 1) {
                nextPixel.blue = 0xFFFF
            } else {
                nextPixel.green = 0xFFFF
            }
            
            if(x % 3 == 0) {
                nextPixel.blue = 0xFFFF
            } else if(x % 3 == 1) {
                nextPixel.green = 0xFFFF
            } else {
                nextPixel.red = 0xFFFF
            }
            
            print("setting pixel at offset \(offset)")
            data.replaceSubrange(offset ..< offset+bytesPerPixel, with: &nextPixel.value, count: 8)
        }
    }
    
    if let dataProvider = CGDataProvider(data: data as CFData) {
        var colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height,
                       bitsPerComponent: bitsPerComponent,
                       bitsPerPixel: bytesPerPixel*8,
                       bytesPerRow: width*bytesPerPixel,
                       space: colorSpace,
                       bitmapInfo: CGBitmapInfo.byteOrder16Big,
                       provider: dataProvider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
    return nil
}

func copy(image: CGImage) -> CGImage? {

    let width = image.width
    let height = image.height
    let bytesPerPixel = image.bitsPerPixel/8
    let bitsPerComponent = image.bitsPerComponent
    let bytesPerRow = width*bytesPerPixel

    var data = Data(count: width * height * bytesPerPixel)

    guard var data = image.dataProvider?.data as? Data
/*          let bytes = CFDataGetBytePtr(data)*/ else { return nil }

// XXX __really__ slow
    for y in 0 ..< height {
        print ("y \(y)")
        for x in 0 ..< width {
            if x == 100 {       // write a red vertical line at 100 pixels into the image
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)

                var nextPixel = Pixel()
                nextPixel.red = 0xFFFF
                //var nextPixel = pixel(fromImage: image, atX: x, andY: y)
                var nextValue = nextPixel.value
                data.replaceSubrange(offset ..< offset+bytesPerPixel, with: &nextValue, count: 6)
            }
        }
    }

    if let dataProvider = CGDataProvider(data: data as CFData) {
        var colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width, height: height,
                       bitsPerComponent: bitsPerComponent,
                       bitsPerPixel: bytesPerPixel*8,
                       bytesPerRow: width*bytesPerPixel,
                       space: colorSpace,
                       bitmapInfo: image.bitmapInfo, // byte order
                       provider: dataProvider,
                       decode: nil,
                       shouldInterpolate: false,
                       intent: .defaultIntent)
    }
    return nil
}

func dump_pixels(fromImage image: CGImage, closure: (Pixel, Int, Int) -> ()) {
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else {
                          fatalError("Couldn't access image data")
    }
    print("image is [\(image.width), \(image.height)] with image.bitsPerPixel \(image.bitsPerPixel) and image.bitsPerComponent \(image.bitsPerComponent) image.bytesPerRow \(image.bytesPerRow)")

    let numberComponents = image.bitsPerPixel / image.bitsPerComponent
    let bytesPerPixel = image.bitsPerPixel / 8
    
    assert(image.colorSpace?.model == .rgb)
    print("bytesPerPixel \(bytesPerPixel)")
    print("numberComponents \(numberComponents)")
    
//    for fuck in 0 ..< image.height * image.width * bytesPerPixel {
//        let r = bytes[fuck]
//        print ("\(fuck) \(r)")
//    }
    for y in 0 ..< image.height {
        for x in 0 ..< image.width {
            var pixel = Pixel()
            let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
            // XXX this could be cleaner
            let r1 = UInt16(bytes[offset]) // lower bits
            let r2 = UInt16(bytes[offset + 1]) << 8 // higher bits
            pixel.red = r1 + r2
            let g1 = UInt16(bytes[offset+image.bitsPerComponent/8])
            let g2 = UInt16(bytes[offset+image.bitsPerComponent/8 + 1]) << 8
            pixel.green = g1 + g2
            let b1 = UInt16(bytes[offset+(image.bitsPerComponent/8)*2])
            let b2 = UInt16(bytes[offset+(image.bitsPerComponent/8)*2 + 1]) << 8
            pixel.blue = b1 + b2

            closure(pixel, x, y)
        }
        print("---")
    }
}

func pixel(fromImage image: CGImage, atX x: Int, andY y: Int) -> Pixel {
    guard let data = image.dataProvider?.data,
          let bytes = CFDataGetBytePtr(data) else {
                          fatalError("Couldn't access image data")
    }

    let numberComponents = image.bitsPerPixel / image.bitsPerComponent
    let bytesPerPixel = image.bitsPerPixel / 8
    
    assert(image.colorSpace?.model == .rgb)
    
    var pixel = Pixel()
    let offset = (y * image.bytesPerRow) + (x * bytesPerPixel)
    // XXX this could be cleaner
    let r1 = UInt16(bytes[offset]) // lower bits
    let r2 = UInt16(bytes[offset + 1]) << 8 // higher bits
    pixel.red = r1 + r2
    let g1 = UInt16(bytes[offset+image.bitsPerComponent/8])
    let g2 = UInt16(bytes[offset+image.bitsPerComponent/8 + 1]) << 8
    pixel.green = g1 + g2
    let b1 = UInt16(bytes[offset+(image.bitsPerComponent/8)*2])
    let b2 = UInt16(bytes[offset+(image.bitsPerComponent/8)*2 + 1]) << 8
    pixel.blue = b1 + b2

    return pixel
}

// XXX removes suffix and path
func remove_suffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    var components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}

func load(imageFiles: [String]) throws -> [CGImage] {
    var ret: [CGImage] = [];
    try imageFiles.forEach { file in
        let imageURL = NSURL(fileURLWithPath: file, isDirectory: false)
        let data = try Data(contentsOf: imageURL as URL)
        if let image = NSImage(data: data),
           let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        {
            ret.append(cgImage)
        }
    }
    return ret;
}

func list_image_files(atPath path: String) -> [String] {
    var image_files: [String] = []
    
    do {
        let contents = try FileManager.default.contentsOfDirectory(atPath: path)
        contents.forEach { file in
            if file.hasSuffix(".tif") || file.hasSuffix(".tiff") {
                image_files.append("\(path)/\(file)")
            }
        }
    } catch {
        print("OH FUCK \(error)")
    }
    return image_files
}

