import Foundation
import CoreGraphics
import Cocoa

@available(macOS 10.15, *) 
class NighttimeAirplaneEraser {
    
    let image_sequence_dirname: String
    let output_dirname: String

    // the max number of frames to process at one time
    let max_concurrent_renders: UInt

    // XXX write the following things into the output videoname:
    
    // size of a group of outliers that is considered an airplane streak
    let min_neighbors: UInt16

    // difference between same pixels on different frames to consider an outlier
    //    let max_pixel_distance: UInt16 = 10000
    let max_pixel_distance: UInt16

    // add some padding?
    let padding_value: UInt16

    // paint green on the outliers above the threshold for testing, that are not overwritten
    let test_paint_outliers: Bool
    
    // paint red on changed pixels, with blue on padding border
    let test_paint_changed_pixels: Bool
    
    let dispatchQueue = DispatchQueue(label: "ntar",
                                      qos: .unspecified,
                                      attributes: [.concurrent],
                                      autoreleaseFrequency: .inherit,
                                      target: nil)

    init(imageSequenceDirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         minNeighbors min_neighbors: UInt16 = 200,
         maxPixelDistance max_pixel_distance: UInt16 = 9000,
         padding: UInt16 = 0,
         testPaint: Bool = false)
    {
        self.max_concurrent_renders = max_concurrent
        self.min_neighbors = min_neighbors
        self.max_pixel_distance = max_pixel_distance
        self.padding_value = padding
        self.test_paint_outliers = testPaint
        self.test_paint_changed_pixels = testPaint
        image_sequence_dirname = imageSequenceDirname
        var basename = "\(image_sequence_dirname)-no-planes-\(min_neighbors)-\(max_pixel_distance)"
        if padding != 0 {
            basename = basename + "-pad-\(padding)"
        }
        if testPaint {
            output_dirname = "\(basename)-test-paint"
        } else {
            output_dirname = basename
        }
    }
    
    func run() {
        var image_files = list_image_files(atPath: image_sequence_dirname)
        image_files.sort { (lhs: String, rhs: String) -> Bool in
            let lh = remove_suffix(fromString: lhs)
            let rh = remove_suffix(fromString: rhs)
            return lh < rh
        }

        let image_sequence = ImageSequence(filenames: image_files)
        //    Log.d("image_files \(image_files)")
        
        do {
            try FileManager.default.createDirectory(atPath: output_dirname, withIntermediateDirectories: false, attributes: nil)
        } catch let error as NSError {
            fatalError("Unable to create directory \(error.debugDescription)")
        }
        
        // each of these methods removes the airplanes from a particular frame
        var methods: [Int : () async -> Void] = [:]
        
        let dispatchGroup = DispatchGroup()
        let number_running = NumberRunning()
    
        for (index, image_filename) in image_sequence.filenames.enumerated() {
            methods[index] = {
                dispatchGroup.enter() 
                // load images outside the main thread
                if let image = await image_sequence.getImage(withName: image_filename) {
                    var otherFrames: [CGImage] = []
                    
                    if index > 0,
                       let image = await image_sequence.getImage(withName: image_sequence.filenames[index-1])
                    {
                        otherFrames.append(image)
                    }
                    if index < image_sequence.filenames.count - 1,
                       let image = await image_sequence.getImage(withName: image_sequence.filenames[index+1])
                    {
                        otherFrames.append(image)
                    }
                    
                    // the other frames that we use to detect outliers and repaint from
                    if let new_image = self.removeAirplanes(fromImage: image,
                                                                otherFrames: otherFrames)
                    {
                        // relinquish images here
                        Log.d("new_image \(new_image)")
                        let filename_base = remove_suffix(fromString: image_sequence.filenames[index])
                        let filename = "\(self.output_dirname)/\(filename_base).tif"
                        do {
                            try save(image: new_image, toFile: filename)
                        } catch {
                            Log.e("doh! \(error)")
                        }
                    }
                } else {
                    Log.d("FUCK")
                    fatalError("doh")
                }
                await number_running.decrement()
                dispatchGroup.leave()
            }
        }
        
        Log.d("we have \(methods.count) methods")
        let runner: () async -> Void = {
            while(methods.count > 0) {
                let current_running = await number_running.currentValue()
                if(current_running < self.max_concurrent_renders) {
                    Log.d("\(current_running) frames currently processing")
                    Log.d("we have \(methods.count) more frames to process")
                    Log.d("enquing new method")

                    // sort the keys and take the smallest one first
                    if let next_method_key = methods.sorted(by: { $0.key < $1.key}).first?.key,
                       let next_method = methods[next_method_key]
                    {
                        methods.removeValue(forKey: next_method_key)
                        await number_running.increment()
                        self.dispatchQueue.async {
                            Task {
                                await next_method()
                            }
                        }
                    } else {
                        Log.e("FUCK")
                        fatalError("FUCK")
                    }
                } else {
                    _ = dispatchGroup.wait(timeout: DispatchTime.now().advanced(by: .seconds(1)))
                }
            }
        }
        dispatchGroup.enter()
        Task {
            Log.d("running")
            await runner()
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
        Log.d("done")
    }

    func removeAirplanes(fromImage image: CGImage,
                         otherFrames: [CGImage]) -> CGImage?
    {
        Log.d("removing airplanes from image with \(otherFrames.count) other frames")

        var outlier_map: [String: Outlier] = [:] // keyed by "\(x),\(y)"
        
        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bitsPerPixel/8
        let bitsPerComponent = image.bitsPerComponent
        let bytesPerRow = width*bytesPerPixel
        
        guard let orig_data = image.dataProvider?.data  else { return nil }

        // copy the original image data as adjecent frames need
        // to access the original unmodified version
        guard var data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                 CFDataGetLength(orig_data),
                                                 orig_data) as? Data else { return nil }
          
    
        var otherData: [CFData] = []
        otherFrames.forEach { frame in
            if let data = frame.dataProvider?.data {
                otherData.append(data)
            } else {
                fatalError("fuck")
            }
        }
              
        Log.d("got image data, detecting outlying pixels")
              
        for y: UInt16 in 0 ..< UInt16(height) {
            for x: UInt16 in 0 ..< UInt16(width) {

                let origPixel = pixel(fromData: data as CFData, atX: x, andY: y,
                                      bitsPerPixel: image.bitsPerPixel,
                                      bytesPerRow: image.bytesPerRow,
                                      bitsPerComponent: image.bitsPerComponent)
                var otherPixels: [Pixel] = []
                
                for p in 0 ..< otherFrames.count {
                    let otherFrame = otherFrames[p]
                    let newPixel = pixel(fromData: otherData[p], atX: x, andY: y,
                                         bitsPerPixel: otherFrame.bitsPerPixel,
                                         bytesPerRow: otherFrame.bytesPerRow,
                                         bitsPerComponent: otherFrame.bitsPerComponent)
                    otherPixels.append(newPixel)
                }
                if otherPixels.count == 0 {
                    fatalError("need more than one image in the sequence")
                }
                
                var total_difference: Int32 = 0
                otherPixels.forEach { pixel in
                    total_difference += Int32(origPixel.difference(from: pixel))
                }
                
                total_difference /= Int32(otherPixels.count)
                
                if total_difference > max_pixel_distance {
                    outlier_map["\(x),\(y)"] = Outlier(x: x, y: y, amount: total_difference)
                }
            }
        }
           
        Log.i("processing the outlier map")
        
        // go through the outlier_map and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size
        let neighbor_groups = prune(outlierMap: outlier_map)
    
        Log.i("done processing the outlier map")
        // paint green on the outliers above the threshold for testing
        if(test_paint_outliers) { // XXX search the outlier map instead, it's faster
            Log.d("painting outliers green")

            for (_, outlier) in outlier_map {
                let x = outlier.x
                let y = outlier.y
                
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

        // add padding when desired
        // XXX this is slower than the other steps here :(
        // also not sure it's really needed
        if(padding_value > 0) {
            Log.d("adding padding") // XXX search the outlier map, looking for missing neighbors
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
        // iterate over the outlier_map instead
        for (_, outlier) in outlier_map {
            let x = outlier.x
            let y = outlier.y
            if let tag = outlier.tag,
               let total_size = neighbor_groups[tag] {
                if total_size > min_neighbors { 
                    //Log.d("found \(group_size) neighbors")
                            
                    let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
                    
                    var otherPixels: [Pixel] = []

                    // blend in the other frames
                    for p in 0 ..< otherFrames.count {
                        let otherFrame = otherFrames[p]
                        let newPixel = pixel(fromData: otherData[p], atX: x, andY: y,
                                             bitsPerPixel: otherFrame.bitsPerPixel,
                                             bytesPerRow: otherFrame.bytesPerRow,
                                             bitsPerComponent: otherFrame.bitsPerComponent)
                        
                        otherPixels.append(newPixel)
                    }
                    var nextPixel = Pixel(merging: otherPixels)
                    
                    if test_paint_changed_pixels {
                        // for testing, colors changed pixels
                        if outlier.amount == 0 {
                            nextPixel.blue = 0xFFFF // for padding
                        } else {
                            nextPixel.red = 0xFFFF // for unpadded changed area
                        }
                    }
                    
                    var nextValue = nextPixel.value
                    data.replaceSubrange(offset ..< offset+bytesPerPixel, with: &nextValue, count: 6)
                }
            }
        }
        
        Log.d("creating final image")

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

func pixel(fromData data: CFData,
           atX x: UInt16,
           andY y: UInt16,
           bitsPerPixel: Int,
           bytesPerRow: Int,
           bitsPerComponent: Int) -> Pixel
{
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

// removes suffix and path
func remove_suffix(fromString string: String) -> String {
    let imageURL = NSURL(fileURLWithPath: string, isDirectory: false) as URL
    let full_path = imageURL.deletingPathExtension().absoluteString
    let components = full_path.components(separatedBy: "/")
    return components[components.count-1]
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


func prune(outlierMap outlier_map: [String: Outlier]) -> [String: UInt16]
{
    // first link all outliers to their direct neighbors
    for (_, outlier) in outlier_map {
        let x = outlier.x
        let y = outlier.y
        if y > 0, let neighbor = outlier_map["\(x),\(y-1)"] {
            outlier.top = neighbor
        }
        if x > 0, let neighbor = outlier_map["\(x-1),\(y)"] {
            outlier.left = neighbor
        }
        if let neighbor = outlier_map["\(x+1),\(y)"] {
            outlier.bottom = neighbor
        }
        if let neighbor = outlier_map["\(x),\(y+1)"] {
            outlier.right = neighbor
        }
    }

    // then label all adject outliers
    for (outlier_key, outlier) in outlier_map {
        if outlier.tag == nil,
           !outlier.done
        {
            outlier.tag = outlier_key
            var pending_outliers = directNeighbors(for: outlier)
            // these outliers have a tag, but are set as done
            while pending_outliers.count > 0 {
                //Log.d("pending_outliers.count \(pending_outliers.count)")
                let next_outlier = pending_outliers.removeFirst()
                next_outlier.tag = outlier_key
                let more_pending_outliers = directNeighbors(for: next_outlier)
                pending_outliers = more_pending_outliers + pending_outliers
            }
        }
    }

    var individual_group_counts: [String: UInt16] = [:]

    for (_, outlier) in outlier_map {
        //Log.d("outlier \(outlier)")
        if let tag = outlier.tag {
            if let outlier_count = individual_group_counts[tag] {
                individual_group_counts[tag] = outlier_count + 1
            } else {
                individual_group_counts[tag] = 1
            }
        } else {
            Log.e("FUCK")       // all outliers should be tagged now
            fatalError("FUCKED")
        }
    }
    return individual_group_counts
}

func directNeighbors(for outlier: Outlier) -> [Outlier] {
    var ret: [Outlier] = []
    if let left = outlier.left,
       left.tag == nil,
       !left.done
    {
        ret.append(left)
    }
    if let right = outlier.right,
       right.tag == nil,
       !right.done
    {
        ret.append(right)
    }
    if let top = outlier.top,
       top.tag == nil,
       !top.done
    {
        ret.append(top)
    }
    if let bottom = outlier.bottom,
       bottom.tag == nil,
       !bottom.done
    {
        ret.append(bottom)
    }
    return ret
}

// used for padding          
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

