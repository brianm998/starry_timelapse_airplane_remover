import Foundation
import CoreGraphics
import Cocoa

/*
todo:

 - identify outliers that are in a line somehow, and apply a smaller threshold to those that are

*/

@available(macOS 10.15, *) 
class NighttimeAirplaneEraser {
    
    let image_sequence_dirname: String
    let output_dirname: String

    // the max number of frames to process at one time
    let max_concurrent_renders: UInt

    // the following properties get included into the output videoname
    
    // size of a group of outliers that is considered an airplane streak
    let min_neighbors: UInt16

    // difference between same pixels on different frames to consider an outlier
    let max_pixel_distance: UInt16

    // add some padding?
    let padding_value: UInt

    // paint green on the outliers above the threshold for testing, that are not overwritten
    let test_paint_outliers: Bool
    
    // paint red on changed pixels, with blue on padding border
    let test_paint_changed_pixels: Bool

    // concurrent dispatch queue so we can process frames in parallel
    let dispatchQueue = DispatchQueue(label: "ntar",
                                      qos: .unspecified,
                                      attributes: [.concurrent],
                                      autoreleaseFrequency: .inherit,
                                      target: nil)

    init(imageSequenceDirname: String,
         maxConcurrent max_concurrent: UInt = 5,
         minNeighbors min_neighbors: UInt16 = 100,
         maxPixelDistance max_pixel_distance: UInt16 = 10000,
         padding: UInt = 0,
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

        if !FileManager.default.fileExists(atPath: output_dirname) {
            do {
                try FileManager.default.createDirectory(atPath: output_dirname,
                                                        withIntermediateDirectories: false,
                                                        attributes: nil)
            } catch let error as NSError {
                fatalError("Unable to create directory \(error.debugDescription)")
            }
        }
        
        // each of these methods removes the airplanes from a particular frame
        var methods: [Int : () async -> Void] = [:]
        
        let dispatchGroup = DispatchGroup()
        let number_running = NumberRunning()
    
        for (index, image_filename) in image_sequence.filenames.enumerated() {
            let filename_base = remove_suffix(fromString: image_sequence.filenames[index])
            // XXX why remove and add diff? 
            let filename = "\(self.output_dirname)/\(filename_base).tif"

            if FileManager.default.fileExists(atPath: filename) {
                Log.i("skipping already existing file \(filename)")
            } else {
                methods[index] = {
                    dispatchGroup.enter() 
                    // load images outside the main thread
                    if let image = await image_sequence.getImage(withName: image_filename) {
                        var otherFrames: [PixelatedImage] = []
                        
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
                        if let new_image = await self.removeAirplanes(fromImage: image,
                                                                      otherFrames: otherFrames)
                        {
                            // relinquish images here
                            Log.d("new_image \(new_image)")
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
            // atually run it
            await runner()
            dispatchGroup.leave()
        }
        dispatchGroup.wait()
        Log.d("done")
    }

    func removeAirplanes(fromImage image: PixelatedImage,
                         otherFrames: [PixelatedImage]) async -> CGImage?
    {
        Log.d("removing airplanes from image with \(otherFrames.count) other frames")

        let width = image.width
        let height = image.height
        let bytesPerPixel = image.bytesPerPixel
        let bitsPerComponent = image.bitsPerComponent
        let bytesPerRow = width*bytesPerPixel
        
        guard let orig_data = image.image.dataProvider?.data  else { return nil }

        // copy the original image data as adjecent frames need
        // to access the original unmodified version
        guard var data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                 CFDataGetLength(orig_data),
                                                 orig_data) as? Data else { return nil }
          
              
        Log.d("got image data, detecting outlying pixels")

        var outlier_map: [String: Outlier] = [:] // keyed by "\(x),\(y)"

        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        for y in 0 ..< height {
            for x in 0 ..< width {
                
                let origPixel = await image.pixel(atX: x, andY: y)
                var otherPixels: [Pixel] = []

                // XXX this could be better
                if otherFrames.count > 0 {
                    let pixel = await otherFrames[0].pixel(atX: x, andY: y)
                    otherPixels.append(pixel)
                }
                if otherFrames.count > 1 {
                    let pixel = await otherFrames[1].pixel(atX: x, andY: y)
                    otherPixels.append(pixel)
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
                    outlier_map["\(x),\(y)"] = Outlier(x: x, y: y,
                                                       amount: total_difference)
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
            for y in 0 ..< height {
                //Log.d("y \(y)")
                for x in 0 ..< width {
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
            // figure out if this outlier is next to enough other outliers
            if let tag = outlier.tag,
               let total_size = neighbor_groups[tag] {
                if total_size > min_neighbors { 
                    // we've found a spot to paint over
                            
                    var otherPixels: [Pixel] = []

                    // XXX this could be better
                    // grab the pixels from the same image spot from adject frames
                    if otherFrames.count > 0 {
                        let pixel = await otherFrames[0].pixel(atX: x, andY: y)
                        otherPixels.append(pixel)
                    }
                    if otherFrames.count > 1 {
                        let pixel = await otherFrames[1].pixel(atX: x, andY: y)
                        otherPixels.append(pixel)
                    }

                    // blend the pixels from the adjecent frames
                    var nextPixel = Pixel(merging: otherPixels)
                    
                    // for testing, colors changed pixels
                    if test_paint_changed_pixels {
                        if outlier.amount == 0 {
                            nextPixel.blue = 0xFFFF // for padding
                        } else {
                            nextPixel.red = 0xFFFF // for unpadded changed area
                        }
                    }

                    // this is the numeric value we need to write out to paint over the airplane
                    var nextValue = nextPixel.value

                    // the is the place in the image data to write to
                    let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)

                    // actually paint over that airplane like thing in the image data
                    data.replaceSubrange(offset ..< offset+bytesPerPixel, with: &nextValue, count: 6)
                }
            }
        }
        
        Log.d("creating final image")

        // create a CGImage from the data we just changed
        if let dataProvider = CGDataProvider(data: data as CFData) {
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            return CGImage(width: width,
                           height: height,
                           bitsPerComponent: bitsPerComponent,
                           bitsPerPixel: bytesPerPixel*8,
                           bytesPerRow: width*bytesPerPixel,
                           space: colorSpace,
                           bitmapInfo: image.image.bitmapInfo, // byte order
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

// this method identifies neighoring outliers,
// outputting a dict of Outlier tag to number with that tag
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
            var pending_outliers = outlier.taglessUndoneNeighbors
            // these outliers have a tag, but are set as done
            while pending_outliers.count > 0 {
                let next_outlier = pending_outliers.removeFirst()
                next_outlier.tag = outlier_key
                let more_pending_outliers = next_outlier.taglessUndoneNeighbors
                pending_outliers = more_pending_outliers + pending_outliers
            }
        }
    }

    var individual_group_counts: [String: UInt16] = [:]

    // finally collect counts by outlier tag name
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

// used for padding          
func tag(within distance: UInt, ofX x: Int, andY y: Int,
         outlierMap outlier_map: [String: Outlier],
         neighborGroups neighbor_groups: [String: UInt16],
         minNeighbors min_neighbors: UInt16) -> String?
{
    var x_start = 0;
    var y_start = 0;
    if x < distance {
        x_start = 0
    } else {
        x_start = x - Int(distance)
    }
    if y < distance {
        y_start = 0
    } else {
        y_start = y - Int(distance)
    }
    for y_idx in y_start ..< y+Int(distance) {
        for x_idx in x_start ..< x+Int(distance) {
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

func hypotenuse(x1: Int, y1: Int, x2: Int, y2: Int) -> Int {
    let x_dist = Int(abs(Int32(x2)-Int32(x1)))
    let y_dist = Int(abs(Int32(y2)-Int32(y1)))
    return Int(sqrt(Float(x_dist*x_dist+y_dist*y_dist)))
}

