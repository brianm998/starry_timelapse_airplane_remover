import Foundation
import CoreGraphics
import Cocoa

// this class holds the logic for removing airplanes from a single frame

enum PaintReason: Equatable {
   case assumed
   case goodScore(Double)            // percent score
   case adjecentLine(Double, Double)     // theta and rho diffs

   case badScore(Double)        // percent score
   case adjecentOverlap(Double) // overlap distance
   case tooBlobby(Double, Double) // first_diff, lowest_diff  XXX more info here
        
   public static func == (lhs: PaintReason, rhs: PaintReason) -> Bool {
      switch lhs {
      case assumed:
          switch rhs {
          case assumed:
              return true
          default:
              return false
          }
      case goodScore:
          switch rhs {
          case goodScore:
              return true
          default:
              return false
          }
      case adjecentLine:
          switch rhs {
          case adjecentLine:
              return true
          default:
              return false
          }
      case badScore:
          switch rhs {
          case badScore:
              return true
          default:
              return false
          }
      case adjecentOverlap:
          switch rhs {
          case adjecentOverlap:
              return true
          default:
              return false
          }
      case tooBlobby: 
          switch rhs {
          case tooBlobby:
              return true
          default:
              return false
          }
      }
   }    
}

// polar coordinates for right angle intersection with line from origin
typealias WillPaint = (                 
    shouldPaint: Bool,          // paint over this group or not
    why: PaintReason            // why?
)
/*

test paint colors:

 red - painted over because of large size only
 yellow - painted over because of good frame-only score
 magenta - painted over because of inter-frame line alignment

 blue - not painted over because of inter-frame overlap
 cyan - not painted over because of bad frame-only score
 bright green - outlier group that was not painted over for some reason
 light green - outlier, but not part of a big enough group
*/
@available(macOS 10.15, *)
class FrameAirplaneRemover: Equatable {
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
    
    var test_paint_filename: String = "" // the filename to write out test paint data to
    var test_paint = false               // should we test paint?  helpful for debugging

    // one dimentional arrays indexed by y*width + x
    var outlier_amounts: [UInt32]  // amount difference of each outlier
    var outlier_groups: [String?]  // named outlier group for each outlier
    
    // populated by pruning
    var neighbor_groups: [String: UInt64] = [:] // keyed by group name, value is the size of each
                                           // group, only groups larger than min_group_size
    var lines_from_full_image: [Line] = [] // lines from all large enough outliers

    var should_paint: [String:WillPaint] = [:] // keyed by group name, should be paint it?
    var group_min_x: [String:Int] = [:]   // keyed by group name, image bounds of each group
    var group_min_y: [String:Int] = [:]
    var group_max_x: [String:Int] = [:]
    var group_max_y: [String:Int] = [:]

    var group_amounts: [String: UInt64] = [:] // keyed by group name, average brightness of each group

    var group_lines: [String:Line] = [:] // keyed by group name, the best line found for each group

    let output_filename: String
    
    init?(fromImage image: PixelatedImage,
          atIndex frame_index: Int,
          otherFrames: [PixelatedImage],
          output_filename: String,
          test_paint_filename tpfo: String?,
          max_pixel_distance: UInt16
         )
    {
        self.frame_index = frame_index // frame index in the image sequence
        self.image = image
        self.otherFrames = otherFrames
        self.output_filename = output_filename
        if let tp_filename = tpfo {
            self.test_paint = true
            self.test_paint_filename = tp_filename
        }
        self.width = image.width
        self.height = image.height

        self.bytesPerPixel = image.bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel
        self.max_pixel_distance = max_pixel_distance
        self.outlier_amounts = [UInt32](repeating: 0, count: width*height)
        self.outlier_groups = [String?](repeating: nil, count: width*height)


        // XXX maybe allocate these later
              
        Log.d("frame \(frame_index) got image data")
    }

    // this is still a slow part of the process, but is now about 10x faster than before
    func populateOutlierMap() {
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
    }

    // this method groups outliers into groups of direct neighbors
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
            
            if outlier_amount <= max_pixel_distance { continue }
            
            let outlier_groupname = outlier_groups[index]
            if outlier_groupname != nil { continue }
            
            // not part of a group yet
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
                    Log.d("frame \(frame_index) looping \(loop_count) times group_size \(group_size)")
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
            if group_size > min_group_size { 
                individual_group_counts[outlier_key] = group_size
            }
        }
        self.neighbor_groups = individual_group_counts
    }    
                  
    func testPaintOutliers(toData test_paint_data: inout Data) {
        Log.d("frame \(frame_index) painting outliers green")

        for (index, outlier_amount) in outlier_amounts.enumerated() {
            let x = index % width;
            let y = index / width;

            if outlier_amount > max_pixel_distance {
                let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
                
                var nextPixel = Pixel()
                if let group_name = outlier_groups[index] {
                    if let (will_paint, why) = should_paint[group_name] {
                        if !will_paint {
                            switch why {
                            case .badScore:
                                nextPixel.green = 0xFFFF // cyan
                                nextPixel.blue = 0xFFFF
                            case .adjecentOverlap:
                                nextPixel.blue = 0xFFFF // blue
                            case .tooBlobby:
                                nextPixel.blue = 0x8FFF // less blue
                            default:
                                fatalError("should not happen")
                            }
                        }
                    } else {
                        nextPixel.green = 0xFFFF // groups that can be chosen to paint
                    }
                } else {
                    // no group
                    nextPixel.green = 0x8888 // groups that are too small to paint
                }
                var nextValue = nextPixel.value
                
                test_paint_data.replaceSubrange(offset ..< offset+raw_pixel_size_bytes, // XXX error here sometimes
                                                 with: &nextValue, count: raw_pixel_size_bytes)
            }
        }
    }

    // record the extent of each group in the image, and also its brightness
    func calculateGroupBoundsAndAmounts() {

        Log.i("frame \(frame_index) calculating outlier group bounds")

        
        // calculate the outer bounds of each outlier group
        for x in 0 ..< width {
            for y in 0 ..< height { // XXX heap corruption :(
                let index = y*width+x
                if let group = outlier_groups[index]
                {
                    let amount = UInt64(outlier_amounts[index])
                    if let group_amount = group_amounts[group] {
                        group_amounts[group] = group_amount + amount
                    } else {
                        group_amounts[group] = amount
                    }
                    // first record amounts
                    
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

        for (group_name, group_size) in neighbor_groups {
            if let group_amount = group_amounts[group_name] {
                group_amounts[group_name] = group_amount / group_size
            }
        }
    }

    var houghTransform_rmax: Double = 0

    // this method runs a hough transform on the full resolution image that
    // contains only large enough outliers
    func fullHoughTransform() {
        let houghTransform = HoughTransform(data_width: width, data_height: height)
        houghTransform_rmax = houghTransform.rmax
        Log.i("frame \(frame_index) running full outlier hough transform")

        // do a hough transform and compare leading outlier groups to lines in the image
        
        // mark potential lines in the hough_data by groups larger than some size
        for (index, group_name) in outlier_groups.enumerated() { // XXX heap corruption :(
            if let group_name = group_name,
               let _ = neighbor_groups[group_name]
            {
                houghTransform.input_data[index] = true
            }
        }

        lines_from_full_image =
            houghTransform.lines(min_count: min_line_count,
                              number_of_lines_returned: max_number_of_lines)

        Log.d("frame \(frame_index) got \(lines_from_full_image.count) lines from the full outlier hough transform")
    }
                  
    // this method analyzises the outlier groups to determine paintability
    func outlierGroupPaintingAnalysis() {
        
        var processed_group_count = 0

        Log.i("frame \(frame_index) deciding paintability of \(neighbor_groups.count) outlier groups")

        // look through all neighber groups greater than min_group_size
        // this is a lot faster now
        for (name, size) in neighbor_groups {
            if let min_x = group_min_x[name], // bounding box for this group
               let min_y = group_min_y[name],
               let max_x = group_max_x[name],
               let max_y = group_max_y[name],
               let group_value = group_amounts[name] // how bright is this group?
            {
                // use assume_airplane_size to avoid doing extra processing on
                // really big outlier groups
                if size > assume_airplane_size {
                    Log.d("frame \(frame_index) assuming group \(name) of size \(size) (> \(assume_airplane_size)) is an airplane, will paint over it")
                    Log.d("frame \(frame_index) should_paint[\(name)] = (true, .assumed)")
                    should_paint[name] = (shouldPaint: true, why: .assumed)
                    continue
                }

                let group_width = max_x - min_x + 1
                let group_height = max_y - min_y + 1
                // creating a smaller HoughTransform is a lot faster,
                // but looses a small amount of precision
                let groupHoughTransform = HoughTransform(data_width: group_width,
                                                    data_height: group_height)
                
                processed_group_count += 1
                
                // first do a hough transform on just this outlier group
                // set all pixels of this group to true in the hough data
                for x in min_x ... max_x {
                    for y in min_y ... max_y {
                        let index = y * width + x
                        let group_index = (y-min_y) * group_width + (x-min_x)
                        if let group_name = outlier_groups[index],
                           name == group_name
                        {
                            groupHoughTransform.input_data[group_index] = true
                        }
                    }
                }
        
                // get the theta and rho of just this outlier group
                let lines_from_this_group =
                    groupHoughTransform.lines(min_count: group_min_line_count,
                                           number_of_lines_returned: 10)
                if lines_from_this_group.count == 0 {
                    Log.w("frame \(frame_index) got no group lines for group \(name) of size \(size)")
                    // this should only happen when there is no data in the input and therefore output 
                    //fatalError("bad input data")
                    continue
                }
                
                // this is the most likely line from the outlier group
                // useful data here could be other lines, and if there are any,
                // and how far away they are from the most prominent one.
                // i.e. detecting real lines vs the best line fit for a random blob
                let (group_theta, group_rho, group_count) = lines_from_this_group[0]

                group_lines[name] = lines_from_this_group[0] // keep this for later analysis
                
                Log.d("frame \(frame_index) group \(name) got \(lines_from_this_group.count) lines from group hough transform")
                
                Log.d("frame \(frame_index) group \(name) line at index 0 theta \(group_theta), rho \(group_rho), count \(group_count)")
                var lowest_count = group_count
                var first_count_drop = -111111111
                
                if lines_from_this_group.count > 1 {
                    let (_, _, first_count) = lines_from_this_group[1]
                    first_count_drop = group_count - first_count
                    for i in 1 ..< lines_from_this_group.count {
                        let (other_theta, other_rho, other_count) = lines_from_this_group[i]

                        if other_count < lowest_count {
                            lowest_count = other_count
                        }
                        // XXX clean this up with below, it's a copy
                        // o is the direct distance from the full screen origin
                        // to the group transform origin
                        //let o = sqrt(Double(min_x * min_x) + Double(min_y * min_y))
                        
                        // theta_r is the angle from the full screen origin to the
                        // to the group transform origin, in degrees
                        //let theta_r = acos(Double(min_x)/o)*180/Double.pi

                        // theta_p is the angle between them in degrees
                        //let theta_p = group_theta - theta_r

                        // add the calculated missing amount to the group_rho
                        //let adjusted_group_rho = other_rho + o * cos(theta_p * Double.pi/180)
                        // XXX clean this up with below, it's a copy

                        //Log.d("frame \(frame_index) group \(name) line at index \(i) theta \(other_theta), rho \(adjusted_group_rho), count \(other_count)")
                    }
                }
                
                if first_count_drop != -111111111 {
                    // we have information about other lines for this group
                    Log.d("frame \(frame_index) group \(name) group_count \(group_count) first_count_drop \(first_count_drop) lowest_count \(lowest_count)")

                    let lowest_diff = Double(group_count-lowest_count)/Double(group_count)
                    let first_diff = Double(first_count_drop)/Double(group_count)
                    Log.d("frame \(frame_index) group \(name) lowest_diff \(lowest_diff) first_diff \(first_diff)")
                    if(lowest_diff < 0.20 && first_diff < 0.1) { // XXX hardcoded constants
                        should_paint[name] = (shouldPaint: false, why: .tooBlobby(first_diff, lowest_diff))
                        continue
                    }
                } else {
                    fatalError("FUCK YOU")
                }

                // convert the rho from the group hough transform to what
                // it would have been if we had run the transformation full frame
                // precision is not 100% due to hough transformation bucket size differences
                // but that's what speeds this up :)

                // o is the direct distance from the full screen origin
                // to the group transform origin
                let o = sqrt(Double(min_x * min_x) + Double(min_y * min_y))

                // theta_r is the angle from the full screen origin to the
                // to the group transform origin, in degrees
                let theta_r = acos(Double(min_x)/o)*180/Double.pi

                // theta_p is the angle between them in degrees
                let theta_p = group_theta - theta_r

                // add the calculated missing amount to the group_rho
                let adjusted_group_rho = group_rho + o * cos(theta_p * Double.pi/180)

                let inital_min_theta_diff: Double = 360             // theta is in degrees
                let inital_min_rho_diff: Double = houghTransform_rmax // max rho value possible
                
                var min_theta_diff = inital_min_theta_diff
                var min_rho_diff = inital_min_rho_diff
                var best_choice_line_count: Int = 0
                var best_group_count: Int = 0
                var best_score: Double = 0


                var group_size_score: Double = 0 // size of the group in pixels

                if size < 10 {  
                    group_size_score = 0
                } else if size < 50 {
                    group_size_score = 25
                } else if size < 100 {
                    group_size_score = 40
                } else if size < 150 {
                    group_size_score = 50
                } else if size < 200 {
                    group_size_score = 60
                } else if size < 300 {
                    group_size_score = 70
                } else if size < 500 {
                    group_size_score = 80
                } else {
                    group_size_score = 100
                }
                
                var group_value_score: Double = 0 // score of how bright this group was overall
                if group_value < max_pixel_brightness_distance {
                    group_value_score = 0
                } else {
                    let max = UInt64(max_pixel_brightness_distance)
                    group_value_score = Double(group_value - max)/Double(max)*20
                    if group_value_score > 100 {
                        group_value_score = 100
                    }
                }
                
                var group_count_score: Double = 0 // score of the line from the group transform
                if group_count < 10 {
                    group_count_score = 0
                } else if group_count < 30 {
                    group_count_score = 20
                } else if group_count < 50 {
                    group_count_score = 50
                } else if group_count < 80 {
                    group_count_score = 80
                } else {
                    group_count_score = 100
                }

                for line in lines_from_full_image {
                    if line.count <= 10 /* min_line_count XXX */ { continue }

                    /*
                     proposal:

                     make a score based upon theta, rho and both line count and group size.

                     theta 0 == high score
                     theta 1 == medium
                     theta 2 == medium
                     theta 4 == less
                     theta 5 == less
                     theta 6 == unlikley

                     rho should be more flexable, allowing for up to 100 or more, but
                     less likely.  linear probability?

                     count should also matter
                     what is max count?

                     larger group sizes are preferred
                     smaller group sizes need to meet higher criteria

                     how to rank this score into a decision?

                     on each iteration of this list, calculate a score, and if it's best,
                     keep track of the values used to calculate it.

                     at the end, if the score is above some magical threshold, then paint
                     */

                    
                    let theta_diff = abs(line.theta-group_theta) // degrees
                    let rho_diff = abs(line.rho-adjusted_group_rho)       // pixels

                    var theta_score: Double = 0
                    
                    if theta_diff == 0 {
                        theta_score = 100
                    } else if theta_diff < 1 {
                        theta_score = 90
                    } else if theta_diff < 2 {
                        theta_score = 80
                    } else if theta_diff < 3 {
                        theta_score = 60
                    } else if theta_diff < 4 {
                        theta_score = 40
                    } else if theta_diff < 5 {
                        theta_score = 30
                    } else if theta_diff < 6 {
                        theta_score = 20
                    } else if theta_diff < 7 {
                        theta_score = 10
                    } else if theta_diff < 8 {
                        theta_score = 5
                    } else {
                        theta_score = 0
                    }

                    var rho_score: Double = 0 // score based upon how different the rho is

                    if rho_diff < 3 {
                        rho_score = 100
                    } else if rho_diff < 5 {
                        rho_score = 80
                    } else if rho_diff < 10 {
                        rho_score = 50
                    } else if rho_diff < 100 {
                        rho_score = 30
                    } else {
                        rho_score = 0
                    }
                    
                    var line_score: Double = 0 // score of the line from the full hough transform

                    if line.count < 30 {
                        line_score = 0
                    } else if line.count < 35 {
                        line_score = 10
                    } else if line.count < 100 {
                        line_score = 50
                    } else if line.count < 200 {
                        line_score = 70
                    } else if line.count < 500 {
                        line_score = 90
                    } else if line.count < 1000 {
                        line_score = 100
                    }
                    
                    let overall_score = (theta_score*line_score/100 + rho_score*line_score/100 + (group_size_score + group_count_score + group_value_score)/3) / 3

                    // record best comparison from all of them
                    if overall_score > best_score {
                        Log.d("frame \(frame_index) (theta_score \(theta_score) rho_score \(rho_score) line_score \(line_score) group_size_score \(group_size_score)) group_count_score \(group_count_score) group_value_score \(group_value_score) overall_score \(overall_score)")

                        best_score = overall_score
                        min_theta_diff = theta_diff
                        min_rho_diff = rho_diff
                        best_choice_line_count = line.count
                        best_group_count = group_count
                    }
                }

                Log.d("frame \(frame_index) final best match for group \(name) of size \(size) value \(group_value) width \(group_width) height \(group_height) - theta_diff \(min_theta_diff) rho_diff \(min_rho_diff) line_count \(best_choice_line_count) group_count \(best_group_count) group_value \(group_value) best_score \(best_score)")
                
                if best_score > 50 {
                    Log.d("frame \(frame_index) should_paint[\(name)] = (true, .goodScore(\(best_score))")
                    should_paint[name] = (shouldPaint: true, why: .goodScore(best_score))
                } else {
                    should_paint[name] = (shouldPaint: false, why: .badScore(best_score))
                    Log.d("frame \(frame_index) should_paint[\(name)] = (false, .badScore(\(best_score))")
                    if min_theta_diff == inital_min_theta_diff ||
                         min_rho_diff == inital_min_rho_diff
                    {
                        Log.w("frame \(frame_index) will NOT paint group \(name) no hough transform lines were found")
                    } else {
                        Log.d("frame \(frame_index) will NOT paint group \(name)")
                    }
                }
            }
        }
        Log.d("frame \(frame_index) processed \(processed_group_count) groups")
    }

    func paintOverAirplanes(toData data: inout Data, testData test_paint_data: inout Data) {

        Log.i("frame \(frame_index) painting airplane outlier groups")

        // paint over every outlier in the paint list with pixels from the adjecent frames
        for (index, group_name) in outlier_groups.enumerated() {
            if let group_name = group_name,
               let (will_paint, why) = should_paint[group_name],
               will_paint
            {
//                /*if group_name == "1996,230" { */Log.d("frame \(frame_index) will paint \(group_name) why \(why)") /*}*/
                let x = index % width;
                let y = index / width;
                paint(x: x, y: y, why: why,
                     toData: &data, testData: &test_paint_data)
            }
        }
    }

    func writeTestFile(withData data: Data) {
        image.writeTIFFEncoding(ofData: data, toFilename: test_paint_filename)
    }

    // paint over a selected outlier with data from pixels from adjecent frames
    func paint(x: Int, y: Int,
               why: PaintReason,
               toData data: inout Data,
               testData test_paint_data: inout Data) {
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
            switch why {
            case .assumed:
                paint_pixel.red = 0xFFFF // red
            case .goodScore:
                paint_pixel.red = 0xFFFF // yellow
                paint_pixel.green = 0xFFFF
            case .adjecentLine:
                paint_pixel.red = 0xFFFF // magenta
                paint_pixel.blue = 0xFFFF
            default:
                fatalError("should not happen")
            }
            
            var test_paint_value = paint_pixel.value
            test_paint_data.replaceSubrange(offset ..< offset+raw_pixel_size_bytes,
                                        with: &test_paint_value,
                                        count: raw_pixel_size_bytes)
        }
    }

    // run after should_paint has been set for each group, 
    // does the final painting and then writes out the output files
    func finish() {
        Log.i("frame \(self.frame_index) finishing")
        
        let _data = image.raw_image_data

        // copy the original image data as adjecent frames need
        // to access the original unmodified version
        guard let _mut_data = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                      CFDataGetLength(_data as CFData),
                                                      _data as CFData) as? Data else {
            Log.e("couldn't copy image data")
            fatalError("couldn't copy image data")
        }
        var output_data = _mut_data

        var test_paint_data: Data = Data()
        if test_paint {
            guard let foobar = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                      CFDataGetLength(_data as CFData),
                                                      _data as CFData) as? Data else {
                Log.e("couldn't copy image data")
                fatalError("couldn't copy image data")
            }
            test_paint_data = foobar
            self.testPaintOutliers(toData: &test_paint_data)
        }
        
        Log.d("frame \(self.frame_index) painting over airplanes")
                  
        self.paintOverAirplanes(toData: &output_data, testData: &test_paint_data)
        
        Log.d("frame \(self.frame_index) writing output files")

        self.writeTestFile(withData: test_paint_data)

        Log.i("frame \(self.frame_index) complete")

        // write frame out as a tiff file after processing it
        self.image.writeTIFFEncoding(ofData: output_data,  toFilename: self.output_filename)
    }

    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frame_index == rhs.frame_index
    }    

}

                  
