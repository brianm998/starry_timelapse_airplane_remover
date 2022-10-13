import Foundation
import CoreGraphics
import Cocoa


if CommandLine.arguments.count < 1 {
    Log.d("need more args!")    // XXX make this better
} else {
    let path = FileManager.default.currentDirectoryPath
    let input_image_sequence_dirname = CommandLine.arguments[1]
    Log.d("will process \(input_image_sequence_dirname)")
    Log.d("on path \(path)")
    var image_files = list_image_files(atPath: "\(path)/\(input_image_sequence_dirname)")
    image_files.sort { (lhs: String, rhs: String) -> Bool in
        let lh = remove_suffix(fromString: lhs)
        let rh = remove_suffix(fromString: rhs)
        return lh < rh
    }
    Log.d("image_files \(image_files)")

    let images = try load(imageFiles: image_files)
    Log.d("loaded images \(images)")

    let output_dirname = "\(path)/\(input_image_sequence_dirname)-no-planes"
    
    do {
        try FileManager.default.createDirectory(atPath: output_dirname, withIntermediateDirectories: false, attributes: nil)
    } catch let error as NSError {
        fatalError("Unable to create directory \(error.debugDescription)")
    }
    
    for (index, image) in images.enumerated() {
        var otherFrames: [CGImage] = []
        if(index > 0) {
            otherFrames.append(images[index-1])
        }
        if(index < images.count - 1) {
            otherFrames.append(images[index+1])
        }
        // XXX muti thread these
        // XXX running time on anything but tiny images is _really_ long
        if let new_image = removeAirplanes(fromImage: image,
                                           otherFrames: otherFrames,
                                           minNeighbors: 500,
                                           withPadding: 0)
        {
            Log.d("new_image \(new_image)")
            let filename_base = remove_suffix(fromString: image_files[index])
            let filename = "\(output_dirname)/\(filename_base)-no-airplanes.tif"
            do {
                try save(image: new_image, toFile: filename)
            } catch {
                Log.d("doh! \(error)")
            }
        }
    }
}

func save(image cgImage: CGImage, toFile filename: String) throws {
    let context = CIContext()
    let fileURL = NSURL(fileURLWithPath: filename, isDirectory: false) as URL
    let options: [CIImageRepresentationOption: CGFloat] = [:]
    if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) {
        let imgFormat = CIFormat.RGBA16

        if #available(macOS 10.12, *) {
            try context.writeTIFFRepresentation(
                of: CIImage(cgImage: cgImage),
                to: fileURL,
                format: imgFormat,
                colorSpace: colorSpace,
                options: options
            )
        } else {
            fatalError("Must use macOS 10.12 or higher")
        }
    } else {
        Log.d("FUCK")
    }
}

func removeAirplanes(fromImage image: CGImage,
                     otherFrames: [CGImage],

                     // size of a group of outliers that is considered an airplane streak
                     minNeighbors min_neighbors: UInt16 = 1000,

                     // difference between same pixels on different frames to consider an outlier
                     minPixelDifference max_pixel_distance: UInt16 = 10000,

                     // add some padding
                     withPadding padding_value: UInt16 = 2) -> CGImage?
{
    Log.d("removing airplanes from image with \(otherFrames.count) other frames")

    var outlier_map: [String: Outlier] = [:] // keyed by "\(x),\(y)"
    var neighbor_groups: [String: UInt16] = [:] // keyed by above 

    let width = image.width
    let height = image.height
    let bytesPerPixel = image.bitsPerPixel/8
    let bitsPerComponent = image.bitsPerComponent
    let bytesPerRow = width*bytesPerPixel

    guard var data = image.dataProvider?.data as? Data else { return nil }

    var otherData: [CFData] = []
    otherFrames.forEach { frame in
        if let data = frame.dataProvider?.data {
            otherData.append(data)
        } else {
            fatalError("fuck")
        }
    }
    
    for y: UInt16 in 0 ..< UInt16(height) {
        //Log.d("y \(y)")
        for x: UInt16 in 0 ..< UInt16(width) {
            //Log.d ("x1 \(x)")

            let origPixel = pixel(fromData: data as CFData, atX: x, andY: y,
                                  bitsPerPixel: image.bitsPerPixel,
                                  bytesPerRow: image.bytesPerRow,
                                  bitsPerComponent: image.bitsPerComponent)
            //Log.d ("(\(x), \(y)) \(origPixel.description)")
            var otherPixels: [Pixel] = []
            //Log.d ("x1.1 \(x)")
            for p in 0 ..< otherFrames.count {
                let otherFrame = otherFrames[p]
                let newPixel = pixel(fromData: otherData[p], atX: x, andY: y,
                                     bitsPerPixel: otherFrame.bitsPerPixel,
                                     bytesPerRow: otherFrame.bytesPerRow,
                                     bitsPerComponent: otherFrame.bitsPerComponent)
                //Log.d("newPixel \(newPixel.description)")
                otherPixels.append(newPixel)
            }
            var total_difference: Int32 = 0
            //Log.d ("x2 \(x)")
            otherPixels.forEach { pixel in
                total_difference += Int32(origPixel.difference(from: pixel))
            }
            total_difference /= Int32(otherPixels.count)

            if total_difference > max_pixel_distance {
                //Log.d("at (\(x), \(y)) we have difference \(total_difference) otherPixels \(otherPixels.count)")
                outlier_map["\(x),\(y)"] = Outlier(x: x, y: y, amount: total_difference)
            }
            //Log.d ("x3 \(x)")
        }
    }

    Log.i("processing the outlier map")
    
    // go through the outlier_map 
    prune(width: UInt16(width),
          height: UInt16(height),
          outlierMap: outlier_map,
          neighborGroups: &neighbor_groups)

    Log.i("done processing the outlier map")
    
    // paint green on the outliers above the threshold for testing
    let paint_green = false
    if(paint_green) {
        Log.d("painting outliers green")
        for y: UInt16 in 0 ..< UInt16(height) {
            for x: UInt16 in 0 ..< UInt16(width) {
                if let outlier = outlier_map["\(x),\(y)"] {
                    if outlier.amount > max_pixel_distance { // XXX global variable
                        //Log.d("found \(outlier.neighbors.count) neighbors")

                        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)

                        var nextPixel = Pixel()
                        nextPixel.green = 0xFFFF

                        var nextValue = nextPixel.value
                        data.replaceSubrange(offset ..< offset+bytesPerPixel, with: &nextValue, count: 6)
                    }
                }
            }
        }
    }

    // add padding when desired
    // XXX this is slower than the other steps here :(
    // also not sure it's really needed
    if(padding_value > 0) {
        Log.d("adding padding")
        for y: UInt16 in 0 ..< UInt16(height) {
            //Log.d("y \(y)")
            for x: UInt16 in 0 ..< UInt16(width) {
                let outlier_tag = "\(x),\(y)"
                let outlier = outlier_map[outlier_tag]
                var should_try = false
                if outlier == nil {
                    should_try = true
                } else if let outlier = outlier,
                          outlier.amount > max_pixel_distance
                {
                    should_try = true
                }
                
                if should_try,
                   let bigTag = tag(within: padding_value,
                                    ofX: x, andY: y,
                                    outlierMap: outlier_map,
                                    neighborGroups: neighbor_groups,
                                    minNeighbors: min_neighbors)
                {
                    let padding = Outlier(x: x, y: y, amount: 0)
                    padding.tag = bigTag
                    outlier_map[outlier_tag] = padding
                }
            }
        }
    }

    Log.d("painting over airplane streaks")
    
    // paint on the large groups of outliers with values from the other frames
    for y: UInt16 in 0 ..< UInt16(height) {
        for x: UInt16 in 0 ..< UInt16(width) {
            if let outlier = outlier_map["\(x),\(y)"] {

                if let tag = outlier.tag,
                   let group_size = neighbor_groups[tag] {                    
                    if group_size > min_neighbors { // XXX global variable
                        //Log.d("found \(group_size) neighbors")

                        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)

                        var otherPixels: [Pixel] = []

                        // XXX uncomment to use more than one frame
                        for p in 0 ..< 1/*otherFrames.count*/ {
                            let otherFrame = otherFrames[p]
                            let newPixel = pixel(fromData: otherData[p], atX: x, andY: y,
                                                 bitsPerPixel: otherFrame.bitsPerPixel,
                                                 bytesPerRow: otherFrame.bytesPerRow,
                                                 bitsPerComponent: otherFrame.bitsPerComponent)
                            
                            otherPixels.append(newPixel)
                        }
                        var nextPixel = Pixel(merging: otherPixels)
                        /*
                        // for testing
                        if outlier.amount == 0 {
                            nextPixel.green = 0xFFFF
                        } else {
                            nextPixel.red = 0xFFFF
                        }
                        */                      
                        var nextValue = nextPixel.value
                        data.replaceSubrange(offset ..< offset+bytesPerPixel, with: &nextValue, count: 6)
                    }
                }
            }
        }
    }

    if let dataProvider = CGDataProvider(data: data as CFData) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        return CGImage(width: width,
                       height: height,
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

func pixel(fromData data: CFData,
           atX x: UInt16,
           andY y: UInt16,
           bitsPerPixel: Int,
           bytesPerRow: Int,
           bitsPerComponent: Int) -> Pixel
{
    //Log.d("woo")
    guard let bytes = CFDataGetBytePtr(data) else {
        fatalError("Couldn't access image data")
    }

    let bytesPerPixel = bitsPerPixel / 8
    
//    assert(image.colorSpace?.model == .rgb)
    
    var pixel = Pixel()
    let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
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
    //Log.d("wooo")

    return pixel
}

// XXX removes suffix and path
func remove_suffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
}

func load(imageFiles: [String]) throws -> [CGImage] {
    var ret: [CGImage] = [];
    try imageFiles.forEach { file in
        Log.d("loading \(file)")
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
                Log.d("going to read \(file)")
            }
        }
    } catch {
        Log.d("OH FUCK \(error)")
    }
    return image_files
}


func prune(outlier: Outlier, tag: String, outlierMap outlier_map: [String: Outlier]) -> Set<Outlier> {
    // look for neighbors
    let x = outlier.x
    let y = outlier.y

    var neighbors: Set<Outlier> = []
    
    if y > 0,
       let neighbor = outlier_map["\(x),\(y-1)"],
       neighbor.tag == nil
    {
        neighbor.tag = tag
        neighbors.insert(neighbor)
        neighbors.formUnion(prune(outlier: neighbor, tag: tag, outlierMap: outlier_map))
    }
    if x > 0,
       let neighbor = outlier_map["\(x-1),\(y)"],
       neighbor.tag == nil
      {
        neighbor.tag = tag
        neighbors.insert(neighbor)
        neighbors.formUnion(prune(outlier: neighbor, tag: tag, outlierMap: outlier_map))
     }
     if let neighbor = outlier_map["\(x+1),\(y)"],
        neighbor.tag == nil
       {
         neighbor.tag = tag
         neighbors.insert(neighbor)
         neighbors.formUnion(prune(outlier: neighbor, tag: tag, outlierMap: outlier_map))
     }
     if let neighbor = outlier_map["\(x),\(y+1)"],
        neighbor.tag == nil
     {
         neighbor.tag = tag
         neighbors.insert(neighbor)
         neighbors.formUnion(prune(outlier: neighbor, tag: tag, outlierMap: outlier_map))
     }
     return neighbors
}

func prune(width: UInt16, height: UInt16,
           outlierMap outlier_map: [String: Outlier],
           neighborGroups neighbor_groups: inout [String: UInt16])
  {
      Log.d("top level prune started");
      for y: UInt16 in 0 ..< height {
          for x: UInt16 in 0 ..< width {
              let tag = "\(x),\(y)"
              if let outlier = outlier_map[tag],
                 outlier.tag == nil // not part of any group
              {
                  outlier.tag = tag // start a new group
                  let neighbors = prune(outlier: outlier, tag: tag, outlierMap: outlier_map) // look for neighbors
                  //Log.d ("got \(neighbors.count) neighbors")
                  neighbor_groups[tag] = UInt16(neighbors.count)
              }
          }
      }
      Log.d("top level prune completed");
  }

func tag(within distance: UInt16, ofX x: UInt16, andY y: UInt16,
         outlierMap outlier_map: [String: Outlier],
         neighborGroups neighbor_groups: [String: UInt16],
         minNeighbors min_neighbors: UInt16) -> String?
{
    var x_start:UInt16 = 0;
    var y_start:UInt16 = 0;
    if x < distance {
        x_start = 0
    } else {
        x_start = x - distance
    }
    if y < distance {
        y_start = 0
    } else {
        y_start = y - distance
    }
    for y_idx: UInt16 in y_start ..< y+distance {
        for x_idx: UInt16 in x_start ..< x+distance {
            if let outlier = outlier_map["\(x_idx),\(y_idx)"],
               hypotenuse(x1: x, y1: y, x2: x_idx, y2: y_idx) <= distance,
               outlier.amount != 0,
               let tag = outlier.tag,
               let group_size = neighbor_groups[tag],
               group_size > min_neighbors
            {
                return outlier.tag
            }
        }
   }
   return nil
}

func hypotenuse(x1: UInt16, y1: UInt16, x2: UInt16, y2: UInt16) -> UInt16 {
    let x_dist = UInt16(abs(Int32(x2)-Int32(x1)))
    let y_dist = UInt16(abs(Int32(y2)-Int32(y1)))
    return UInt16(sqrt(Float(x_dist*x_dist+y_dist*y_dist)))
}
