import Foundation
import CoreGraphics
import Cocoa

// this class holds the logic for removing airplanes from a single frame

@available(macOS 10.15, *)
class FrameAirplaneRemover {
    let width: Int
    let height: Int
    let bytesPerPixel: Int
    let bytesPerRow: Int
    let image: PixelatedImage
    let otherFrames: [PixelatedImage]
    let min_neighbors: UInt16
    let max_pixel_distance: UInt16
    let frame_index: Int
    
    // only 16 bit RGB images are supported
    let raw_pixel_size_bytes = 6
    
    var data: Data              // a mutable copy of the original data
    var test_paint_data: Data?
    
    var outliers: [[Outlier?]] = [[]] // indexed by [x][y]
    var outlier_list: [Outlier] = [] // all outliers
    
    // populated by pruning
    var neighbor_groups: [String: UInt64] = [:]
    
    var test_paint_filename: String = ""
    var test_paint = false

    init?(fromImage image: PixelatedImage,
          atIndex frame_index: Int,
          otherFrames: [PixelatedImage],
          filename: String,
          test_paint_filename tpfo: String?,
          max_pixel_distance: UInt16,
          min_neighbors: UInt16
         )
    {
        self.min_neighbors = min_neighbors
        self.frame_index = frame_index // frame index in the image sequence
        self.image = image
        self.otherFrames = otherFrames
        if let tp_filename = tpfo {
            self.test_paint = true
            self.test_paint_filename = tp_filename
        }
        self.width = image.width
        self.height = image.height
        self.bytesPerPixel = image.bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel
        self.max_pixel_distance = max_pixel_distance
        
        let _data = image.raw_image_data
        
        // copy the original image data as adjecent frames need
        // to access the original unmodified version
        guard let _mut_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                      CFDataGetLength(_data),
                                                      _data) as? Data else { return nil }

        self.data = _mut_data
              
        if test_paint {
            guard let test_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                          CFDataGetLength(_data),
                                                          _data) as? Data else { return nil }
            self.test_paint_data = test_data
        }
        for x in 0 ..< width {
            outliers.append([])
            for _ in 0 ..< height {
                outliers[x].append(nil)
            }
        }
        Log.d("frame \(frame_index) got image data")
    }

    // this method is by far the slowest part of the process    
    func populateOutlierMap() async {
        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        let orig_pixels = await image.pixels
        var other_pixels: [[[Pixel]]] = [[[]]]
        for i in 0 ..< otherFrames.count {
            other_pixels.append([[]]);
            other_pixels[i] = await otherFrames[i].pixels
        }
        for y in 0 ..< height {
            if y != 0 && y % 1000 == 0 {
                Log.d("frame \(frame_index) detected outliers in \(y) rows")
            }
            for x in 0 ..< width {
                
                let origPixel = orig_pixels[x][y]

                var otherPixels: [Pixel] = []
                for i in 0 ..< otherFrames.count {
                    otherPixels.append(other_pixels[i][x][y])
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
                    let new_outlier = Outlier(x: x, y: y, amount: total_difference)
                    outliers[x][y] = new_outlier
                    outlier_list.append(new_outlier)
                }
            }
        }
    }

    func prune() {
        Log.i("frame \(frame_index) pruning \(outlier_list.count) outliers")
        
        // go through the outlier_list and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size

        // first link all outliers to their direct neighbors
        for (outlier) in outlier_list {
            let x = outlier.x
            let y = outlier.y
            if y > 0,          let neighbor = outliers[x][y-1] { outlier.top    = neighbor }
            if x > 0,          let neighbor = outliers[x-1][y] { outlier.left   = neighbor }
            if x < width - 1,  let neighbor = outliers[x+1][y] { outlier.bottom = neighbor }
            if y < height - 1, let neighbor = outliers[x][y+1] { outlier.right  = neighbor }
        }
    
        var individual_group_counts: [String: UInt64] = [:]
    
        Log.d("frame \(frame_index) labeling adjecent outliers")

        // then label all adject outliers
        for (outlier) in outlier_list {
            if outlier.tag == nil {
                var group_size: UInt64 = 0
                // tag this virgin outlier with its own key
                let outlier_key = "\(outlier.x),\(outlier.y)"; // arbitrary but needs to be unique
                outlier.tag = outlier_key
                group_size += 1
                
                // these neighbor outliers now have the same tag as this outlier,
                // but are not set as done
                var pending_outliers = Set<Outlier>(outlier.taglessNeighbors)
                //Log.d("starting new outlier group \(outlier_key) and \(pending_outliers.count) pending neighbors \(outlier.directNeighbors.count) real neighbors")

                let max_loop_count = UInt64(UInt32.max)
                
                var loop_count: UInt64 = 0
                // should be bounded because of finite number of pixels in image
                // and the usage of a Set to keep out duplicates 
                while pending_outliers.count > 0 {
                    loop_count += 1
                    if loop_count % 10000 == 0 {
                        Log.d("frame \(frame_index) looping \(loop_count) times \(pending_outliers.count) pending outliers")
                    }

                    if loop_count > max_loop_count {
                        Log.w("frame \(frame_index) bailing out after \(loop_count) loops")
                        break
                    }                    
                    let next_outlier = pending_outliers.removeFirst()
                    if next_outlier.tag != nil {
                        Log.e("BAD OUTLIER")
                        fatalError("BAD OUTLIER")
                    }
                    next_outlier.tag = outlier_key
                    group_size += 1
                    
                    let more_pending_outliers = Set<Outlier>(next_outlier.taglessNeighbors)
                    pending_outliers = more_pending_outliers.union(pending_outliers)
                }

                if group_size > 100 {
                    Log.i("frame \(frame_index) group size for \(outlier_key) is \(group_size)")
                }

                individual_group_counts[outlier_key] = group_size
            }
        }
        self.neighbor_groups = individual_group_counts
    }    
                  
    func testPaintOutliers() {
        Log.d("frame \(frame_index) painting outliers green")

        for (outlier) in outlier_list {
            let x = outlier.x
            let y = outlier.y
            
            if outlier.amount > max_pixel_distance { // XXX global variable
                let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
                
                var nextPixel = Pixel()
                nextPixel.green = 0xFFFF
                        
                var nextValue = nextPixel.value

                test_paint_data?.replaceSubrange(offset ..< offset+raw_pixel_size_bytes,
                                                 with: &nextValue, count: raw_pixel_size_bytes)
            }
        }
    }

   func addPadding(padding_value: UInt) {
        // add padding when desired
        // XXX this is slower than the other steps here :(
        // also not sure it's really needed
        if(padding_value > 0) {
            Log.d("frame \(frame_index) adding padding")
            // XXX search the outlier map, looking for missing neighbors
            // when found, mark them as padding (amount 0) in padding_value direction
            // from the location of outliers without neighbors in some direction
            for y in 0 ..< height {
                //Log.d("y \(y)")
                for x in 0 ..< width {
                    let outlier = outliers[x][y]
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
                                        outliers: outliers,
                                        neighborGroups: neighbor_groups,
                                        minNeighbors: min_neighbors)
                    {
                        let padding = Outlier(x: x, y: y, amount: 0)
                        padding.tag = bigTag
                        outliers[x][y] = padding
                        outlier_list.append(padding)
                    }
                }
            }
        }
    }

    func paintOverAirplanes() async {

        var names_of_groups_to_paint: [String] = []
        var should_paint: [String:Bool] = [:]
        var paint_list: [Outlier] = []

        Log.i("frame \(frame_index) painting")

        // first look for neighbor groups with enough neighbors to add to group to paint
        // IMPROVEMENT: - do more than just count, like max distance bewteen points
        for(key, count) in neighbor_groups {
            if count > min_neighbors {
                names_of_groups_to_paint.append(key)
                should_paint[key] = true
                Log.i("frame \(frame_index) will paint group \(key) with \(count) pixels")
            }
        }

        // for each outlier, see if we should paint it, and if so, add it to the list
        for (outlier) in outlier_list {
            if let key = outlier.tag,
               let will_paint = should_paint[key],
               will_paint
            {
                paint_list.append(outlier)
            }
        }

        var other_pixels: [[[Pixel]]] = [[[]]]
        for i in 0 ..< otherFrames.count {
            other_pixels.append([[]]);
            other_pixels[i] = await otherFrames[i].pixels
        }
        
        // paint over every outlier in the paint list with pixels from the adjecent frames
        for (outlier) in paint_list {
            paint(outlier: outlier, with: other_pixels)
        }
        Log.i("frame \(frame_index) done painting")
    }

    func writeTestFile() {
        if test_paint,
           let test_paint_data = test_paint_data
        {
            image.writeTIFFEncoding(ofData: test_paint_data, toFilename: test_paint_filename)
        }
    }

    func paint(outlier: Outlier, with other_pixels: [[[Pixel]]]) {
        let x = outlier.x
        let y = outlier.y
            
        var pixels_to_paint_with: [Pixel] = []
        
        // grab the pixels from the same image spot from adject frames
        for i in 0 ..< otherFrames.count {
            pixels_to_paint_with.append(other_pixels[i][x][y])
        }
        
        // blend the pixels from the adjecent frames
        var paint_pixel = Pixel(merging: pixels_to_paint_with)
        
        // this is the numeric value we need to write out to paint over the airplane
        var paint_value = paint_pixel.value
        
        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
        
        // actually paint over that airplane like thing in the image data
        data.replaceSubrange(offset ..< offset+raw_pixel_size_bytes,
                             with: &paint_value, count: raw_pixel_size_bytes)
        
        // for testing, colors changed pixels
        if test_paint {
            if outlier.amount == 0 {
                paint_pixel.blue = 0xFFFF // for padding
            } else {
                paint_pixel.red = 0xFFFF // for unpadded changed area
            }
        }
        var test_paint_value = paint_pixel.value
        
        if test_paint {
            test_paint_data?.replaceSubrange(offset ..< offset+raw_pixel_size_bytes,
                                             with: &test_paint_value,
                                             count: raw_pixel_size_bytes)
        }
    }
}

                  
// used for padding          
func tag(within distance: UInt, ofX x: Int, andY y: Int,
         outliers: [[Outlier?]],
         neighborGroups neighbor_groups: [String: UInt64],
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
            if let outlier = outliers[x_idx][y_idx],
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

                  
