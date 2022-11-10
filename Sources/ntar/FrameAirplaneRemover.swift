import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

// this class holds the logic for removing airplanes from a single frame

@available(macOS 10.15, *)
actor FrameAirplaneRemover: Equatable { 
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

    let outlier_output_dirname: String?
    
    // one dimentional arrays indexed by y*width + x
    var outlier_amounts: [UInt32]  // amount difference of each outlier
    var outlier_groups: [String?]  // named outlier group for each outlier
    
    // populated by pruning
    var neighbor_groups: [String: UInt64] = [:] // keyed by group name, value is the size of each
                                           // group, only groups larger than min_group_size
    var lines_from_full_image: [Line] = [] // lines from all large enough outliers

    var should_paint: [String:PaintReason] = [:] // keyed by group name, should we paint it?
    var group_min_x: [String:Int] = [:]   // keyed by group name, image bounds of each group
    var group_min_y: [String:Int] = [:]
    var group_max_x: [String:Int] = [:]
    var group_max_y: [String:Int] = [:]

    var group_amounts: [String: UInt64] = [:] // keyed by group name, average brightness of each group

    var group_lines: [String:Line] = [:] // keyed by group name, the best line found for each group

    func setShouldPaint(group group_name: String, why: PaintReason) {
        self.should_paint[group_name] = why
    }
    
    let output_filename: String
    
    init?(fromImage image: PixelatedImage,
          atIndex frame_index: Int,
          otherFrames: [PixelatedImage],
          output_filename: String,
          test_paint_filename tpfo: String?,
          outlier_output_dirname: String?,
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

        self.outlier_output_dirname = outlier_output_dirname
        self.width = image.width
        self.height = image.height

        self.bytesPerPixel = image.bytesPerPixel
        self.bytesPerRow = width*bytesPerPixel
        self.max_pixel_distance = max_pixel_distance
        self.outlier_amounts = [UInt32](repeating: 0, count: width*height)
        self.outlier_groups = [String?](repeating: nil, count: width*height)

        Log.i("frame \(frame_index) starting processing")
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

    // this method groups outliers into groups of direct neighbors,
    // treating smaller groups of outliers as noise and pruning them
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
                    
                    if outlier_y > 0 { // add top neighbor
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

    // paint the outliers that we decided not to paint, to enable debuging
    func testPaintOutliers(toData test_paint_data: inout Data) {
        Log.d("frame \(frame_index) painting outliers green")

        for (name, _) in neighbor_groups {
            if let min_x = group_min_x[name], // bounding box for this group
               let min_y = group_min_y[name],
               let max_x = group_max_x[name],
               let max_y = group_max_y[name]
            {
                for x in min_x ... max_x {
                    for y in min_y ... max_y {
                        let index = y*width + x
                        if let group_name = outlier_groups[index],
                           group_name == name
                        {
                            var nextPixel = Pixel()
                            if let reason = should_paint[group_name] {
                                if !reason.willPaint {
                                    nextPixel.value = reason.testPaintPixel.value
                                }
                            } else {
                                nextPixel.green = 0xFFFF // groups that can be chosen to paint
                            }

                            var nextValue = nextPixel.value
                            let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
                            
                            test_paint_data.replaceSubrange(offset ..< offset+raw_pixel_size_bytes,
                                                            with: &nextValue,
                                                            count: raw_pixel_size_bytes)
                        }
                    }
                }
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
        self.outlier_amounts = [] // not used after here, try to save memory
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
                    should_paint[name] = .assumed
                    continue
                }

                let group_width = max_x - min_x + 1
                let group_height = max_y - min_y + 1
                let group_aspect_ratio = Double(group_width) / Double(group_height)
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
                let lines_from_this_group = groupHoughTransform.lines(min_count: group_min_line_count)
                if lines_from_this_group.count == 0 {
                    Log.w("frame \(frame_index) got no group lines for group \(name) of size \(size)")
                    // this should only happen when there is no data in the input and therefore output 
                    //fatalError("bad input data")
                    continue
                }

                let paint_score_from_lines = paint_score_from(lines: lines_from_this_group)
                if paint_score_from_lines > 0.5 {
                    if size < 300 { // XXX constant XXX
                        // don't assume small ones are lines
                    } else {
                        Log.d("frame \(frame_index) will paint group \(name) because it looks like a line from the group hough transform")
                        should_paint[name] = .looksLikeALine
                        continue
                    }
                }
                
                // this is the most likely line from the outlier group
                // useful data here could be other lines, and if there are any,
                // and how far away they are from the most prominent one.
                // i.e. detecting real lines vs the best line fit for a random blob
                group_lines[name] = lines_from_this_group[0] // keep this for later analysis
                
                //Log.d("frame \(frame_index) group \(name) got \(lines_from_this_group.count) lines from group hough transform")
                
                //Log.d("frame \(frame_index) group \(name) line at index 0 theta \(group_theta), rho \(group_rho), count \(group_count)")

                let group_size_score = paint_score_from(groupSize: size)
                let group_fill_amount = Double(size)/(Double(group_width)*Double(group_height))
                //Log.d("should_paint group_size \(size) group_fill_amount \(group_fill_amount) group_aspect_ratio \(group_aspect_ratio)")
                let group_fill_amount_score = paint_score_from(fillAmount: group_fill_amount)
                let group_aspect_ratio_score = paint_score_from(aspectRatio: group_aspect_ratio)
                
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
                
                var overall_score = group_size_score + group_fill_amount_score +
                                    group_aspect_ratio_score + 
                                    (group_value_score/100) + paint_score_from_lines

                //Log.d("frame \(frame_index) should_paint group_size_score \(group_size_score) group_fill_amount_score \(group_fill_amount_score) group_aspect_ratio_score \(group_aspect_ratio_score) group_aspect_ratio_score \(group_aspect_ratio_score) group_value_score \(group_value_score/100) + paint_score_from_lines \(paint_score_from_lines)")
                
                overall_score /= 5
                
                if overall_score > 0.5 {
                    //Log.d("frame \(frame_index) should_paint[\(name)] = (true, .goodScore(\(overall_score))")
                    should_paint[name] = .goodScore(overall_score)
                } else {
                    should_paint[name] = .badScore(overall_score)
                    //Log.d("frame \(frame_index) should_paint[\(name)] = (false, .badScore(\(overall_score))")
                }
            }
        }
        Log.d("frame \(frame_index) processed \(processed_group_count) groups")
    }

    // actually paint over outlier groups that have been selected as airplane tracks
    func paintOverAirplanes(toData data: inout Data, testData test_paint_data: inout Data) {
        
        Log.i("frame \(frame_index) painting airplane outlier groups")

        // paint over every outlier in the paint list with pixels from the adjecent frames
        for (index, group_name) in outlier_groups.enumerated() {
            if let group_name = group_name,
               let reason = should_paint[group_name],
               reason.willPaint
            {
                let x = index % width;
                let y = index / width;
                paint(x: x, y: y, why: reason,
                     toData: &data, testData: &test_paint_data)
            }
        }
    }

    private func writeTestFile(withData data: Data) {
        image.writeTIFFEncoding(ofData: data, toFilename: test_paint_filename)
    }

    // paint over a selected outlier pixel with data from pixels from adjecent frames
    private func paint(x: Int, y: Int,
                       why: PaintReason,
                       toData data: inout Data,
                       testData test_paint_data: inout Data)
    {
        var pixels_to_paint_with: [Pixel] = []
        
        // grab the pixels from the same image spot from adject frames
//        for i in 0 ..< otherFrames.count {
//            pixels_to_paint_with.append(otherFrames[i].readPixel(atX: x, andY: y))
//        }

        // XXX blending both adjecent frames can make the painted airlane streak darker
        // then it was before because the bright stars are dimmed 50% due to them moving across
        // two frames.  try just using one frame and see how that works.  maybe make it an option?
        
        pixels_to_paint_with.append(otherFrames[0].readPixel(atX: x, andY: y))
        
        // blend the pixels from the adjecent frames
        let paint_pixel = Pixel(merging: pixels_to_paint_with)
        
        // this is the numeric value we need to write out to paint over the airplane
        var paint_value = paint_pixel.value
        
        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
        
        // actually paint over that airplane like thing in the image data
        data.replaceSubrange(offset ..< offset+raw_pixel_size_bytes,
                          with: &paint_value, count: raw_pixel_size_bytes)
        
        // for testing, colors changed pixels
        if test_paint {
            var test_paint_value = why.testPaintPixel.value
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
                                                      _data as CFData) as? Data
        else {
            Log.e("couldn't copy image data")
            fatalError("couldn't copy image data")
        }
        var output_data = _mut_data
        
        var test_paint_data: Data = Data()
        if test_paint {
            guard let foobar = CFDataCreateMutableCopy(kCFAllocatorDefault,
                                                       CFDataGetLength(_data as CFData),
                                                       _data as CFData) as? Data
            else {
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
        
        // write frame out as a tiff file after processing it
        self.image.writeTIFFEncoding(ofData: output_data,  toFilename: self.output_filename)
        
        Log.i("frame \(self.frame_index) complete")
    }

    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frame_index == rhs.frame_index
    }    

                  
    func writeOutlierGroupFiles() {
        Log.e("writing outlier group images")              
        for (group_name, _) in self.neighbor_groups {
            Log.i("writing text file for group \(group_name)")
            
            if let min_x = group_min_x[group_name],
               let min_y = group_min_y[group_name],
               let max_x = group_max_x[group_name],
               let max_y = group_max_y[group_name],
               let output_dirname = outlier_output_dirname
            {
                let filename = "\(frame_index)_outlier_\(group_name).txt".replacingOccurrences(of: ",", with: "_")
                
                let full_path = "\(output_dirname)/\(filename)"
                if file_manager.fileExists(atPath: full_path) {
                    Log.w("cannot write to \(full_path), it already exists")
                } else {
                    Log.i("creating \(full_path)")                      
                    var line = ""
                    
                    for y in min_y ... max_y {
                        for x in min_x ... max_x {
                            let index = y*width+x
                            if let new_group_name = outlier_groups[index],
                               new_group_name == group_name
                            {
                                line += "*" // outlier spot
                            } else {
                                line += " "
                            }
                        }
                        line += "\n"
                    }
                    if let data = line.data(using: .utf8) {
                        file_manager.createFile(atPath: full_path, contents: data, attributes: nil)
                        Log.i("wrote \(full_path)")
                    } else {
                        Log.e("cannot create data?")
                    }
                }
            } else {
                Log.w("cannot write image for group \(group_name)")
            }
        }
    }
}
