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

    var should_paint_group: ((Int, Int, Int, Int, String, UInt64, Int) -> Bool)?

    var loop_forever = false
    
    init?(fromImage image: PixelatedImage,
          atIndex frame_index: Int,
          otherFrames: [PixelatedImage],
          filename: String,
          test_paint_filename tpfo: String?,
          max_pixel_distance: UInt16,
          should_paint_group: ((Int, Int, Int, Int, String, UInt64, Int) -> Bool)? = nil
         )
    {
        self.should_paint_group = should_paint_group
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
            for _ in 0 ..< height { // crash
                outliers[x].append(nil)
            }
        }
        Log.d("frame \(frame_index) got image data")
    }

    // this is still the slowest part of the process, but is now about 2-3x faster than before
    func populateOutlierMap() async {
        let start_time = NSDate().timeIntervalSince1970
        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        let orig_data = image.image_buffer_ptr

        let bitsPerComponent = image.bitsPerComponent
        
        let other_data_1 = otherFrames[0].image_buffer_ptr
        var other_data_2: UnsafePointer<UInt8>?
        if otherFrames.count > 1 {
            other_data_2 = otherFrames[1].image_buffer_ptr
        }
        let time_1 = NSDate().timeIntervalSince1970
        let interval1 = String(format: "%0.1f", time_1 - start_time)

        // most of the time is in this loop

        // instead of iterating over Pixel objects, perhaps take a more
        // brute force bit based approach of looking at the data more directly
        // make it so not heap allocation / deallocation happens within the loop,
        // except for appending to the outlier list
        for y in 0 ..< height {
            if y != 0 && y % 1000 == 0 {
                Log.d("frame \(frame_index) detected outliers in \(y) rows")
            }
            for x in 0 ..< width {
                let offset = (y * bytesPerRow) + (x * bytesPerPixel)

                // XXX this could be cleaner
                let orig_r1 = UInt16(orig_data[offset]) // lower bits
                let orig_r2 = UInt16(orig_data[offset + 1]) << 8 // higher bits
                let orig_red = orig_r1 + orig_r2
                let orig_g1 = UInt16(orig_data[offset+bitsPerComponent/8])
                let orig_g2 = UInt16(orig_data[offset+bitsPerComponent/8 + 1]) << 8
                let orig_green = orig_g1 + orig_g2
                let orig_b1 = UInt16(orig_data[offset+(bitsPerComponent/8)*2])
                let orig_b2 = UInt16(orig_data[offset+(bitsPerComponent/8)*2 + 1]) << 8
                let orig_blue = orig_b1 + orig_b2
                
                // XXX this could be cleaner
                let other_1_r1 = UInt16(other_data_1[offset]) // lower bits
                let other_1_r2 = UInt16(other_data_1[offset + 1]) << 8 // higher bits
                let other_1_red = other_1_r1 + other_1_r2
                let other_1_g1 = UInt16(other_data_1[offset+bitsPerComponent/8])
                let other_1_g2 = UInt16(other_data_1[offset+bitsPerComponent/8 + 1]) << 8
                let other_1_green = other_1_g1 + other_1_g2
                let other_1_b1 = UInt16(other_data_1[offset+(bitsPerComponent/8)*2])
                let other_1_b2 = UInt16(other_data_1[offset+(bitsPerComponent/8)*2 + 1]) << 8
                let other_1_blue = other_1_b1 + other_1_b2

                let other_1_red_diff = (Int32(orig_red) - Int32(other_1_red))
                let other_1_green_diff = (Int32(orig_green) - Int32(other_1_green))
                let other_1_blue_diff = (Int32(orig_blue) - Int32(other_1_blue))

                let other_1_max = max(other_1_red_diff + other_1_green_diff + other_1_blue_diff / 3,
                                      max(other_1_red_diff, max(other_1_green_diff,
                                                                other_1_blue_diff)))
                
                var total_difference: Int32 = other_1_max
                
                if let other_data_2 = other_data_2 {
                    // XXX this could be cleaner
                    let other_2_r1 = UInt16(other_data_2[offset]) // lower bits
                    let other_2_r2 = UInt16(other_data_2[offset + 1]) << 8 // higher bits
                    let other_2_red = other_2_r1 + other_2_r2
                    let other_2_g1 = UInt16(other_data_2[offset+bitsPerComponent/8])
                    let other_2_g2 = UInt16(other_data_2[offset+bitsPerComponent/8 + 1]) << 8
                    let other_2_green = other_2_g1 + other_2_g2
                    let other_2_b1 = UInt16(other_data_2[offset+(bitsPerComponent/8)*2])
                    let other_2_b2 = UInt16(other_data_2[offset+(bitsPerComponent/8)*2 + 1]) << 8
                    let other_2_blue = other_2_b1 + other_2_b2

                    let other_2_red_diff = (Int32(orig_red) - Int32(other_2_red))
                    let other_2_green_diff = (Int32(orig_green) - Int32(other_2_green))
                    let other_2_blue_diff = (Int32(orig_blue) - Int32(other_2_blue))

                    let other_2_max = max(other_2_red_diff +
                                            other_2_green_diff +
                                            other_2_blue_diff / 3,
                                          max(other_2_red_diff,
                                              max(other_2_green_diff,
                                                  other_2_blue_diff)))
                    total_difference += other_2_max

                    total_difference /= 2
                }
                
                if total_difference > max_pixel_distance {
                    let new_outlier = Outlier(x: x, y: y, amount: total_difference)
                    outliers[x][y] = new_outlier
                    outlier_list.append(new_outlier)
                }
            }
        }
        let end_time = NSDate().timeIntervalSince1970
        let end_interval = String(format: "%0.1f", end_time - start_time)
        Log.d("frame \(frame_index) took \(end_interval)s to populate the outlier map, \(interval1)s of which was getting the other frames")
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
                //Log.d("creating virgin outlier key \(outlier_key)")
                outlier.tag = outlier_key
                group_size += 1
                
                var pending_outliers = outlier.taglessNeighbors
                // tag all neighbers as part of this same Outlier group
                pending_outliers.forEach { pending_outlier in
                    pending_outlier.tag = outlier_key
                }

                //Log.d("pending_outliers \(pending_outliers)")
                
                // there is a non-linear running time problem when pending_outliers gets too big
                // not sure exactly why yet, but max_loop_count is necessary to keep things
                // from taking a _really_ long time.  Same result, just more than one outlier group.
                // keeping max_loop_count big enough means that they still get painted on.
                // this is really an edge case with car headlights.

                // XXX figure this out, it's causing problems :(
                // specifically each large group needs to not be separate
                
                let max_loop_count = 2000//min_group_trail_length*min_group_trail_length*20

                var loop_count: UInt64 = 0
                                
                while pending_outliers.count > 0 {
                    //Log.d("pending_outliers \(pending_outliers)")
                    loop_count += 1
                    if loop_count % 1000 == 0 {
                        Log.d("frame \(frame_index) looping \(loop_count) times \(pending_outliers.count) pending outliers group_size \(group_size)")
                    }

                    if !loop_forever && loop_count > max_loop_count {
                        Log.w("frame \(frame_index) bailing out after \(loop_count) loops")
                        break
                    }                    
                    //let next_outlier = pending_outliers.removeFirst()
                    let next_outlier = pending_outliers.removeLast() // XXX does this help?
                    if next_outlier.tag != nil {
                        group_size += 1

                        let more_pending_outliers = next_outlier.taglessNeighbors
                        more_pending_outliers.forEach { pending_outlier in
                            pending_outlier.tag = outlier_key
                        }

                        //Log.d("more_pending_outliers \(more_pending_outliers)")
                        pending_outliers += more_pending_outliers
                    } else {
                        Log.w("next outlier has tag \(next_outlier.tag)")
                        fatalError("FUCK")
                    }
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
            
            if outlier.amount > max_pixel_distance {
                let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
                
                var nextPixel = Pixel()
                nextPixel.green = 0xFFFF
                        
                var nextValue = nextPixel.value

                test_paint_data?.replaceSubrange(offset ..< offset+raw_pixel_size_bytes, // XXX error here sometimes
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
                                        // XXX refactor this
                                        minNeighbors: 20 /*min_group_trail_length*/)
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

    // this method first analyzises the outlier groups and then paints over them
    func paintOverAirplanes() async {

        var names_of_groups_to_paint: [String] = []
        var should_paint: [String:Bool] = [:]
        var paint_list: [Outlier] = []
        Log.i("frame \(frame_index) painting")

        var group_min_x: [String:Int] = [:]
        var group_min_y: [String:Int] = [:]
        var group_max_x: [String:Int] = [:]
        var group_max_y: [String:Int] = [:]

        // calculate the outer bounds of each outlier group
        for x in 0 ..< width {
            for y in 0 ..< height { // XXX heap corruption :(
                if let outlier = outliers[x][y],
                   let group = outlier.tag
                {
                    if let min_x = group_min_x[group] {
                        if(outlier.x < min_x) {
                            group_min_x[group] = outlier.x
                        }
                    } else {
                        group_min_x[group] = outlier.x
                    }
                    if let min_y = group_min_y[group] {
                        if(outlier.y < min_y) {
                            group_min_y[group] = outlier.y
                        }
                    } else {
                        group_min_y[group] = outlier.y
                    }
                    if let max_x = group_max_x[group] {
                        if(outlier.x > max_x) {
                            group_max_x[group] = outlier.x
                        }
                    } else {
                        group_max_x[group] = outlier.x
                    }
                    if let max_y = group_max_y[group] {
                        if(outlier.y > max_y) {
                            group_max_y[group] = outlier.y
                        }
                    } else {
                        group_max_y[group] = outlier.y
                    }
                }
            }
        }

        // sort by group size, process largest first
        let sorted_groups = neighbor_groups.sorted(by: { $0.value > $1.value })
        for(group, group_size) in sorted_groups {
            if let min_x = group_min_x[group],
               let min_y = group_min_y[group],
               let max_x = group_max_x[group],
               let max_y = group_max_y[group]
            {
//                Log.d("frame \(frame_index) examining group \(group) of size \(group_size) [\(min_x), \(min_y)] => [\(max_x), \(max_y)]")
                if let should_paint_group = should_paint_group {
                    if should_paint_group(min_x, min_y,
                                          max_x, max_y,
                                          group, group_size, frame_index)
                    {
                        should_paint[group] = true
                        names_of_groups_to_paint.append(group)
                    }
                } else {
                    if shouldPaintGroup(min_x: min_x, min_y: min_y,
                                        max_x: max_x, max_y: max_y,
                                        group_name: group,
                                        group_size: group_size)
                    {
//                        Log.d("should paint \(group)")
                        should_paint[group] = true
                        names_of_groups_to_paint.append(group)
                    } else {
//                        Log.d("should NOT paint \(group)")
                    }
                }
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

        // paint over every outlier in the paint list with pixels from the adjecent frames
        for (outlier) in paint_list {
            paint(outlier: outlier)
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

    // paint over a selected outlier with data from pixels from adjecent frames
    func paint(outlier: Outlier) {
        let x = outlier.x
        let y = outlier.y
            
        var pixels_to_paint_with: [Pixel] = []
        
        // grab the pixels from the same image spot from adject frames
        for i in 0 ..< otherFrames.count {
            pixels_to_paint_with.append(otherFrames[i].readPixel(atX: x, andY: y))
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
        
        if test_paint {
            var test_paint_value = paint_pixel.value
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
         minNeighbors min_group_trail_length: UInt16) -> String?
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
               group_size > min_group_trail_length // XXX this may be wrong now
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

                  
