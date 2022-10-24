import Foundation
import CoreGraphics
import Cocoa

// this class holds the logic for removing airplanes from a single frame

// XXX here are some random global constants that maybe should be exposed somehow
let min_group_size = 50         // groups smaller than this are ignored
let min_line_count = 80         // lines with counts smaller than this are ignored
let max_theta_diff: Double = 5   // degrees of difference allowe between lines
let max_rho_dif: Double = 8      // pixels of line displacement allowed
let max_number_of_lines = 80     // don't process more lines than this per image

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

    // one dimentional arrays indexed by y*width + x
    var outlier_amounts: [UInt32]  // amount difference of each outlier
    var outlier_groups: [String?]  // named outlier group for each outlier
    
    // populated by pruning
    var neighbor_groups: [String: UInt64] = [:]
    
    var test_paint_filename: String = ""
    var test_paint = false

    let houghTransform: HoughTransform
    
    init?(fromImage image: PixelatedImage,
          atIndex frame_index: Int,
          otherFrames: [PixelatedImage],
          filename: String,
          test_paint_filename tpfo: String?,
          max_pixel_distance: UInt16
         )
    {
        self.frame_index = frame_index // frame index in the image sequence
        self.image = image
        self.otherFrames = otherFrames
        if let tp_filename = tpfo {
            self.test_paint = true
            self.test_paint_filename = tp_filename
        }
        self.width = image.width
        self.height = image.height

        self.houghTransform = HoughTransform(data_width: width, data_height: height)
        
        self.bytesPerPixel = image.bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel
        self.max_pixel_distance = max_pixel_distance
        self.outlier_amounts = [UInt32](repeating: 0, count: width*height)
        self.outlier_groups = [String?](repeating: nil, count: width*height)
    
        let _data = image.raw_image_data
        
        // copy the original image data as adjecent frames need
        // to access the original unmodified version
        guard let _mut_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                      CFDataGetLength(_data as CFData),
                                                      _data as CFData) as? Data else { return nil }

        self.data = _mut_data
              
        if test_paint {
            guard var test_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                          CFDataGetLength(_data as CFData),
                                                          _data as CFData) as? Data else { return nil }

            let paint_it_black = false      

            if paint_it_black { // gets rid of the other image data
                for i in 0 ..< CFDataGetLength(_data as CFData)/8 {
                    var nextValue: UInt64 = 0x0000000000000000
                    test_data.replaceSubrange(i*8 ..< (i*8)+8, with: &nextValue, count: 8)
                }
            }
            self.test_paint_data = test_data
        }
        Log.d("frame \(frame_index) got image data")
    }

    // this is still the slowest part of the process, but is now about 10x faster than before
    func populateOutlierMap() {
        let start_time = NSDate().timeIntervalSince1970
        // compare pixels at the same image location in adjecent frames
        // detect Outliers which are much more brighter than the adject frames
        let orig_data = image.raw_image_data

        let other_data_1 = otherFrames[0].raw_image_data
        var other_data_2 = Data() // dummy backup 
        var have_two_other_frames = false
        if otherFrames.count > 1 {
            other_data_2 = otherFrames[1].raw_image_data
            have_two_other_frames = true
        }
        let time_1 = NSDate().timeIntervalSince1970
        let interval1 = String(format: "%0.1f", time_1 - start_time)

        // most of the time is in this loop, although it's a lot faster now
        // ugly, but a lot faster
        orig_data.withUnsafeBytes { unsafeRawPointer in 
            let orig_image_pixels: UnsafeBufferPointer<UInt16> =
                unsafeRawPointer.bindMemory(to: UInt16.self)

            other_data_1.withUnsafeBytes { unsafeRawPointer_1  in 
                let other_image_1_pixels: UnsafeBufferPointer<UInt16> =
                    unsafeRawPointer_1.bindMemory(to: UInt16.self)

                other_data_2.withUnsafeBytes { unsafeRawPointer_2 in 
                    let other_image_2_pixels: UnsafeBufferPointer<UInt16> =
                        unsafeRawPointer_2.bindMemory(to: UInt16.self)

                    for y in 0 ..< height {
                        if y != 0 && y % 1000 == 0 {
                            Log.d("frame \(frame_index) detected outliers in \(y) rows")
                        }
                        for x in 0 ..< width {
                            let offset = (y * width*3) + (x * 3) // XXX hardcoded 3's

                            // rgb values of the image we're modifying at this x,y
                            let orig_red = orig_image_pixels[offset]
                            let orig_green = orig_image_pixels[offset+1]
                            let orig_blue = orig_image_pixels[offset+2]
            
                            // rgb values of an adjecent image at this x,y
                            let other_1_red = other_image_1_pixels[offset]
                            let other_1_green = other_image_1_pixels[offset+1]
                            let other_1_blue = other_image_1_pixels[offset+2]

                            // how much brighter in each channel was the image we're modifying?
                            let other_1_red_diff = (Int32(orig_red) - Int32(other_1_red))
                            let other_1_green_diff = (Int32(orig_green) - Int32(other_1_green))
                            let other_1_blue_diff = (Int32(orig_blue) - Int32(other_1_blue))

                            // take a max based upon overal brightness, or just one channel
                            let other_1_max = max(other_1_red_diff +
                                                    other_1_green_diff +
                                                    other_1_blue_diff / 3,
                                                  max(other_1_red_diff,
                                                      max(other_1_green_diff,
                                                          other_1_blue_diff)))
                            
                            var total_difference: Int32 = other_1_max
                            
                            if have_two_other_frames {
                                // rgb values of another adjecent image at this x,y
                                let other_2_red = other_image_2_pixels[offset]
                                let other_2_green = other_image_2_pixels[offset+1]
                                let other_2_blue = other_image_2_pixels[offset+2]
                                
                                // how much brighter in each channel was the image we're modifying?
                                let other_2_red_diff = (Int32(orig_red) - Int32(other_2_red))
                                let other_2_green_diff = (Int32(orig_green) - Int32(other_2_green))
                                let other_2_blue_diff = (Int32(orig_blue) - Int32(other_2_blue))
            
                                // take a max based upon overal brightness, or just one channel
                                let other_2_max = max(other_2_red_diff +
                                                        other_2_green_diff +
                                                        other_2_blue_diff / 3,
                                                      max(other_2_red_diff,
                                                          max(other_2_green_diff,
                                                              other_2_blue_diff)))

                                // average the two differences of the two adjecent frames
                                total_difference += other_2_max
                                total_difference /= 2
                            }

                            let amount_index = Int(y*width+x)
                            // mark this spot as an outlier if it's too bright
                            if total_difference > 0  {
                                outlier_amounts[amount_index] = UInt32(total_difference)
                            }
                        }
                    }
                }
            }
        }
        let end_time = NSDate().timeIntervalSince1970
        let end_interval = String(format: "%0.1f", end_time - start_time)
        Log.d("frame \(frame_index) took \(end_interval)s to populate the outlier map, \(interval1)s of which was getting the other frames")
    }

    func prune() {
        Log.i("frame \(frame_index) pruning outliers")
        
        // go through the outliers and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size
        
        var individual_group_counts: [String: UInt64] = [:]

        var pending_outliers: [Int]
        var pending_outlier_insert_index = 0;
        var pending_outlier_access_index = 0;
       
        let array = [Int](repeating: -1, count: width*height) 
        pending_outliers = array

        Log.d("frame \(frame_index) labeling adjecent outliers")

        // then label all adject outliers
        for (index, outlier_amount) in outlier_amounts.enumerated() {
            if outlier_amount > max_pixel_distance {
                let outlier_groupname = outlier_groups[index]
                if outlier_groupname == nil { // not part of a group yet
                    var group_size: UInt64 = 0
                    // tag this virgin outlier with its own key
                    
                    let outlier_key = "\(index % width),\(index / width)"; // arbitrary but needs to be unique
                    //Log.d("initial index = \(index)")
                    outlier_groups[index] = outlier_key
                    pending_outliers[pending_outlier_insert_index] = index;
                    pending_outlier_insert_index += 1
                    
                    var loop_count: UInt64 = 0
                                    
                    while pending_outlier_insert_index != pending_outlier_access_index {
                        //Log.d("pending_outlier_insert_index \(pending_outlier_insert_index) pending_outlier_access_index \(pending_outlier_access_index)")
                        loop_count += 1
                        if loop_count % 1000 == 0 {
                            Log.d("frame \(frame_index) looping \(loop_count) times \(pending_outliers.count) pending outliers group_size \(group_size)")
                        }
    
                        let next_outlier_index = pending_outliers[pending_outlier_access_index]
                        //Log.d("next_outlier_index \(next_outlier_index)")
                        
                        pending_outlier_access_index += 1
                        if let _ = outlier_groups[next_outlier_index] {
                            group_size += 1
                            
                            let outlier_x = next_outlier_index % width;
                            let outlier_y = next_outlier_index / width;
                            
                            if outlier_x > 0 { // add left neighbor
                                let left_neighbor_index = outlier_y * width + outlier_x - 1
                                if outlier_amounts[left_neighbor_index] > max_pixel_distance,
                                   outlier_groups[left_neighbor_index] == nil
                                {
                                    pending_outliers[pending_outlier_insert_index] = left_neighbor_index
                                    outlier_groups[left_neighbor_index] = outlier_key
                                    pending_outlier_insert_index += 1
                                }
                            }
                            
                            if outlier_x < width - 1 { // add right neighbor
                                let right_neighbor_index = outlier_y * width + outlier_x + 1
                                if outlier_amounts[right_neighbor_index] > max_pixel_distance,
                                   outlier_groups[right_neighbor_index] == nil
                                {
                                    pending_outliers[pending_outlier_insert_index] = right_neighbor_index
                                    outlier_groups[right_neighbor_index] = outlier_key
                                    pending_outlier_insert_index += 1
                                }
                            }
                            
                            if outlier_y < 0 { // add top neighbor
                                let top_neighbor_index = (outlier_y - 1) * width + outlier_x
                                if outlier_amounts[top_neighbor_index] > max_pixel_distance,
                                   outlier_groups[top_neighbor_index] == nil
                                {
                                    pending_outliers[pending_outlier_insert_index] = top_neighbor_index
                                    outlier_groups[top_neighbor_index] = outlier_key
                                    pending_outlier_insert_index += 1
                                }
                            }
                            
                            if outlier_y < height - 1 { // add bottom neighbor
                                let bottom_neighbor_index = (outlier_y + 1) * width + outlier_x
                                if outlier_amounts[bottom_neighbor_index] > max_pixel_distance,
                                   outlier_groups[bottom_neighbor_index] == nil
                                {
                                    pending_outliers[pending_outlier_insert_index] = bottom_neighbor_index
                                    outlier_groups[bottom_neighbor_index] = outlier_key
                                    pending_outlier_insert_index += 1
                                }
                            }
                        } else {
                            //Log.w("next outlier has groupName \(String(describing: next_outlier.groupName))")
                            // shouldn't end up here with a group named outlier
                            fatalError("FUCK")
                        }
                    }
                    //Log.d("group \(outlier_key) has \(group_size) members")
                    individual_group_counts[outlier_key] = group_size
                }
            }
        }
        self.neighbor_groups = individual_group_counts
    }    
                  
    func testPaintOutliers() {
        Log.d("frame \(frame_index) painting outliers green")

        for (index, outlier_amount) in outlier_amounts.enumerated() {
            let x = index % width;
            let y = index / width;

            if outlier_amount > max_pixel_distance,
               let group_name = outlier_groups[index],
               let group_size = neighbor_groups[group_name],
               group_size > min_group_size
            {
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
        // rewrite this
                  /*
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
                        padding.groupName = bigTag
                        outliers[x][y] = padding
                        outlier_list.append(padding)
                    }
                }
            }
        }
*/
    }

    // this method first analyzises the outlier groups and then paints over them
    func paintOverAirplanes() {
        let start_time = NSDate().timeIntervalSince1970

        var should_paint: [String:Bool] = [:]
        Log.i("frame \(frame_index) calculating outlier group bounds")

        // XXX use a typealias to simplify this to one map
        var group_min_x: [String:Int] = [:]
        var group_min_y: [String:Int] = [:]
        var group_max_x: [String:Int] = [:]
        var group_max_y: [String:Int] = [:]

        // calculate the outer bounds of each outlier group
        for x in 0 ..< width {
            for y in 0 ..< height { // XXX heap corruption :(
                if let group = outlier_groups[y*width+x] {
                    if let min_x = group_min_x[group] {
                        if(x < min_x) {
                            group_min_x[group] = x
                        }
                    } else {
                        group_min_x[group] = x
                    }
                    if let min_y = group_min_y[group] {
                        if(y < min_y) {
                            group_min_y[group] = y
                        }
                    } else {
                        group_min_y[group] = y
                    }
                    if let max_x = group_max_x[group] {
                        if(x > max_x) {
                            group_max_x[group] = x
                        }
                    } else {
                        group_max_x[group] = x
                    }
                    if let max_y = group_max_y[group] {
                        if(y > max_y) {
                            group_max_y[group] = y
                        }
                    } else {
                        group_max_y[group] = y
                    }
                }
            }
        }

        let time_1 = NSDate().timeIntervalSince1970
        let interval1 = String(format: "%0.1f", time_1 - start_time)
        
        Log.i("frame \(frame_index) deciding paintability of outlier groups")

        // do a hough transform and compare leading outlier groups to lines in the image
        
        //var hough_data = [Bool](repeating: false, count: width*height)

        // mark potential lines in the hough_data by groups larger than some size
        for (index, group_name) in outlier_groups.enumerated() {
            if let group_name = group_name,
               let group_size = neighbor_groups[group_name]
            {
                if group_size > min_group_size { 
                    houghTransform.input_data[index] = true
                }
            }
        }

        let time_2 = NSDate().timeIntervalSince1970
        let interval2 = String(format: "%0.1f", time_2 - time_1)

        let lines = houghTransform.lines(min_count: min_line_count,
                                     number_of_lines_returned: max_number_of_lines)

        //Log.d("got \(lines.count) lines from the hough transform")


        let time_3 = NSDate().timeIntervalSince1970
        let interval3 = String(format: "%0.1f", time_3 - time_2)

        // re-use the hough_data above for each group (make all false)
        for i in 0 ..< width*height { houghTransform.input_data[i] = false }

        let time_4 = NSDate().timeIntervalSince1970
        let interval4 = String(format: "%0.1f", time_4 - time_3)

        var processed_group_count = 0
        
        // look through all neighber groups greater than min_group_size
        for (name, size) in neighbor_groups {
            if size > min_group_size,
               let min_x = group_min_x[name],
               let min_y = group_min_y[name],
               let max_x = group_max_x[name],
               let max_y = group_max_y[name]
            {
//        let group_start_time = NSDate().timeIntervalSince1970
                
                // first do a hough transform on just this outlier group
                processed_group_count += 1
                // set all pixels of this group to true in the hough data
                // use min_x, etc to speed this up
                for (index, group_name) in outlier_groups.enumerated() {
                    if let group_name = group_name,
                       name == group_name
                    {
                        houghTransform.input_data[index] = true
                    }
                }

//        let group_time_1 = NSDate().timeIntervalSince1970
//        let group_interval1 = String(format: "%0.1f", group_time_1 - group_start_time)
        
                // get the theta and rho of just this outlier group
                houghTransform.resetCounts()
                
                let group_lines = houghTransform.lines(min_count: 10,
                                                  number_of_lines_returned: 1,
                                                  x_start: min_x,
                                                  y_start: min_y,
                                                  x_limit: max_x+1,
                                                  y_limit: max_y+1)

                // this is the most likely line from the outlier group
                let (group_theta, group_rho, group_count) = group_lines[0]
                
//        let group_time_2 = NSDate().timeIntervalSince1970
//        let group_interval2 = String(format: "%0.1f", group_time_2 - group_time_1)

        //Log.d("got \(name) has theta \(group_theta) rho \(group_rho) count \(group_count)")
                
                // set all pixels of this group to false in the hough data for reuse
                for (index, group_name) in outlier_groups.enumerated() {
                    if let group_name = group_name,
                       name == group_name
                    {
                        houghTransform.input_data[index] = false
                    }
                }
            
//        let group_time_3 = NSDate().timeIntervalSince1970
//        let group_interval3 = String(format: "%0.1f", group_time_3 - group_time_2)

                var should_paint_this_one = should_paint[name]
                for line in lines {
                    if line.count > min_line_count {
                        // make final decision based upon how close these values are
                        if theta_rho_comparison(theta1: line.theta, rho1: line.rho,
                                             theta2: group_theta, rho2: group_rho)
                        {
                            Log.i("frame \(frame_index) will paint group \(name) with \(line.count) lines (theta, rho) - line (\(line.theta), \(line.rho)) group (\(group_theta), \(group_rho))")
                            should_paint_this_one = true
                        } else {
                            should_paint[name] = false // overwrite any previous true
                        }
                    }
                }
                should_paint[name] = should_paint_this_one
//        let group_time_4 = NSDate().timeIntervalSince1970
//        let group_interval4 = String(format: "%0.1f", group_time_4 - group_time_3)

//        Log.i("frame \(frame_index) done painting - \(group_interval4)s - \(group_interval3)s - \(group_interval2)s - \(group_interval1)s")
        
            }
        }
        Log.d("frame \(frame_index) processed \(processed_group_count) groups")
        let time_5 = NSDate().timeIntervalSince1970
        let interval5 = String(format: "%0.1f", time_5 - time_4)
        
        Log.i("frame \(frame_index) painting airplane outlier groups")

        // paint over every outlier in the paint list with pixels from the adjecent frames
        for (index, group_name) in outlier_groups.enumerated() {
            if let group_name = group_name,
               let will_paint = should_paint[group_name],
               will_paint
            {
                let x = index % width;
                let y = index / width;
                paint(x: x, y: y, amount: outlier_amounts[index])
            }
        }

        let time_6 = NSDate().timeIntervalSince1970
        let interval6 = String(format: "%0.1f", time_6 - time_5)
        
        Log.i("frame \(frame_index) done painting \(interval6)s - \(interval5)s - \(interval4)s - \(interval3)s - \(interval2)s - \(interval1)s")
    }

    func writeTestFile() {
        if test_paint,
           let test_paint_data = test_paint_data
        {
            image.writeTIFFEncoding(ofData: test_paint_data, toFilename: test_paint_filename)
        }
    }

    // paint over a selected outlier with data from pixels from adjecent frames
    func paint(x: Int, y: Int, amount: UInt32) {
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
        if test_paint { // XXX
            if amount == 0 {
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
                  /*
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
               let groupName = outlier.groupName,
               let group_size = neighbor_groups[groupName],
               group_size > min_group_trail_length // XXX this may be wrong now
            {
                return outlier.groupName
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
*/

func theta_rho_comparison(theta1: Double, rho1: Double, theta2: Double, rho2: Double) -> Bool {
    let theta_diff = abs(theta1-theta2) // degrees
    let rho_diff = abs(rho1-rho2)       // pixels

    return theta_diff < max_theta_diff && rho_diff < max_rho_dif
}
                  
