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

// the first pass is done upon init, finding and pruning outlier groups

enum LoopReturn {
    case `continue`
    case `break`
}

@available(macOS 10.15, *)
actor FrameAirplaneRemover: Equatable { 
    let width: Int
    let height: Int
    let bytesPerPixel: Int
    let bytesPerRow: Int
    let otherFrameIndexes: [Int] // used in found outliers and paint only
    let max_pixel_distance: UInt16
    let min_group_size: Int
    let frame_index: Int
    
    var test_paint_filename: String = "" // the filename to write out test paint data to
    var test_paint = false               // should we test paint?  helpful for debugging

    let outlier_output_dirname: String?

    // populated by pruning
    private var outlier_groups: [String: OutlierGroup] = [:] // keyed by group name

    var outlierGroupCount: Int { return outlier_groups.count }
    
    let output_filename: String

    let image_sequence: ImageSequence
    
    init(imageSequence image_sequence: ImageSequence,
         atIndex frame_index: Int,
         otherFrameIndexes: [Int],
         outputFilename output_filename: String,
         testPaintFilename tpfo: String?,
         outlierOutputDirname outlier_output_dirname: String?,
         maxPixelDistance max_pixel_distance: UInt16,
         minGroupSize min_group_size: Int) async throws
    {

        guard let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index])
        else { throw "Couldn't load image" }
        self.image_sequence = image_sequence
        self.frame_index = frame_index // frame index in the image sequence
        self.otherFrameIndexes = otherFrameIndexes
        self.output_filename = output_filename
        self.min_group_size = min_group_size
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
        
        // find outlying bright pixels between frames,
        // and group neighboring outlying pixels into groups
        try await self.findOutliers()        
        
        Log.i("frame \(frame_index) detected outlier groups")
    }
    

    func outlierGroup(named outlier_name: String) -> OutlierGroup? {
        return outlier_groups[outlier_name]
    }
    
    func foreachOutlierGroup(_ closure: (OutlierGroup)async->LoopReturn) async {
        for (_, group) in self.outlier_groups {
            let result = await closure(group)
            if result == .break { break }
        }
    }
    
    // this is still a slow part of the process, but is now about 10x faster than before
    func findOutliers() async throws {

        guard let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index])
        else { throw "Couldn't load image" }

        var otherFrames: [PixelatedImage] = []

        for otherFrameIndex in otherFrameIndexes {
            guard let otherFrame = try await image_sequence.getImage(withName: image_sequence.filenames[otherFrameIndex])
            else { throw "Couldn't load image" }
            otherFrames.append(otherFrame)
        }
        
        // XXX move this out of class memory, and just use it for populating the outlier list
        // need to have the OutlierGroup class contain a mini version of this for each one
        
        // one dimentional array mirroring pixels indexed by y*width + x
        var outlier_group_list = [String?](repeating: nil, count: width*height)
        
        Log.i("frame \(frame_index) finding outliers")
        var outlier_amount_list = [UInt](repeating: 0, count: width*height)
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
                            let other_1_red_diff = (Int(orig_red) - Int(other_1_red))
                            let other_1_green_diff = (Int(orig_green) - Int(other_1_green))
                            let other_1_blue_diff = (Int(orig_blue) - Int(other_1_blue))

                            // take a max based upon overal brightness, or just one channel
                            let other_1_max = max(other_1_red_diff +
                                                    other_1_green_diff +
                                                    other_1_blue_diff / 3,
                                                  max(other_1_red_diff,
                                                      max(other_1_green_diff,
                                                          other_1_blue_diff)))
                            
                            var total_difference: Int = Int(other_1_max)
                            
                            if have_two_other_frames {
                                // rgb values of another adjecent image at this x,y
                                let other_2_red = other_image_2_pixels[offset]
                                let other_2_green = other_image_2_pixels[offset+1]
                                let other_2_blue = other_image_2_pixels[offset+2]
                                
                                // how much brighter in each channel was the image we're modifying?
                                let other_2_red_diff = (Int(orig_red) - Int(other_2_red))
                                let other_2_green_diff = (Int(orig_green) - Int(other_2_green))
                                let other_2_blue_diff = (Int(orig_blue) - Int(other_2_blue))
            
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
                            // record the brightness change if it is brighter
                            if total_difference > 0  {
                                outlier_amount_list[amount_index] = UInt(total_difference)
                            }
                        }
                    }
                }
            }
        }

        // XXX was a boundary
        
        Log.i("frame \(frame_index) pruning outliers")
        
        // go through the outliers and link together all the outliers that are adject to eachother,
        // outputting a mapping of group name to size
        
        var individual_group_counts: [String: UInt] = [:]

        var pending_outliers: [Int]
        var pending_outlier_insert_index = 0;
        var pending_outlier_access_index = 0;
       
        let array = [Int](repeating: -1, count: width*height) 
        pending_outliers = array

        Log.d("frame \(frame_index) labeling adjecent outliers")

        // then label all adject outliers
        for (index, outlier_amount) in outlier_amount_list.enumerated() {
            
            if outlier_amount <= max_pixel_distance { continue }
            
            let outlier_groupname = outlier_group_list[index]
            if outlier_groupname != nil { continue }
            
            // not part of a group yet
            var group_size: UInt = 0
            // tag this virgin outlier with its own key
            
            let outlier_key = "\(index % width),\(index / width)"; // arbitrary but needs to be unique
            //Log.d("initial index = \(index)")
            outlier_group_list[index] = outlier_key
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
                if let _ = outlier_group_list[next_outlier_index] {
                    group_size += 1
                    
                    let outlier_x = next_outlier_index % width;
                    let outlier_y = next_outlier_index / width;

                    let next_outlier_amount = Double(outlier_amount_list[next_outlier_index])

                    //Log.e("min_pixel_distance \(min_pixel_distance) max_pixel_distance \(max_pixel_distance)")
                    
                    if outlier_x > 0 { // add left neighbor
                        let left_neighbor_index = outlier_y * width + outlier_x - 1
                        let left_neighbor_amount = outlier_amount_list[left_neighbor_index]
                        if left_neighbor_amount > min_pixel_distance,
                           outlier_group_list[left_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = left_neighbor_index
                            outlier_group_list[left_neighbor_index] = outlier_key
                            pending_outlier_insert_index += 1
                        }
                    }
                    
                    if outlier_x < width - 1 { // add right neighbor
                        let right_neighbor_index = outlier_y * width + outlier_x + 1
                        let right_neighbor_amount = outlier_amount_list[right_neighbor_index]
                        if right_neighbor_amount > min_pixel_distance,
                           outlier_group_list[right_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = right_neighbor_index
                            outlier_group_list[right_neighbor_index] = outlier_key
                            pending_outlier_insert_index += 1
                        }
                    }
                    
                    if outlier_y > 0 { // add top neighbor
                        let top_neighbor_index = (outlier_y - 1) * width + outlier_x
                        let top_neighbor_amount = outlier_amount_list[top_neighbor_index]
                        if top_neighbor_amount > min_pixel_distance,
                           outlier_group_list[top_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = top_neighbor_index
                            outlier_group_list[top_neighbor_index] = outlier_key
                            pending_outlier_insert_index += 1
                        }
                    }
                    
                    if outlier_y < height - 1 { // add bottom neighbor
                        let bottom_neighbor_index = (outlier_y + 1) * width + outlier_x
                        let bottom_neighbor_amount = outlier_amount_list[bottom_neighbor_index]
                        if bottom_neighbor_amount > min_pixel_distance,
                           outlier_group_list[bottom_neighbor_index] == nil
                        {
                            pending_outliers[pending_outlier_insert_index] = bottom_neighbor_index
                            outlier_group_list[bottom_neighbor_index] = outlier_key
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

        var group_amounts: [String: UInt] = [:] // keyed by group name, average brightness of each group

        Log.i("frame \(frame_index) calculating outlier group bounds")
        var group_min_x: [String:Int] = [:]   // keyed by group name, image bounds of each group
        var group_min_y: [String:Int] = [:]
        var group_max_x: [String:Int] = [:]
        var group_max_y: [String:Int] = [:]
        
        // calculate the outer bounds of each outlier group
        for x in 0 ..< width {
            for y in 0 ..< height {
                let index = y*width+x
                if let group = outlier_group_list[index]
                {
                    let amount = outlier_amount_list[index]
                    if let group_amount = group_amounts[group] {
                        group_amounts[group] = group_amount + amount
                    } else {
                        group_amounts[group] = amount
                    }
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

        // populate the outlier_groups
        for (group_name, group_size) in individual_group_counts {
            if let min_x = group_min_x[group_name],
               let min_y = group_min_y[group_name],
               let max_x = group_max_x[group_name],
               let max_y = group_max_y[group_name],
               let group_amount = group_amounts[group_name]
            {
                let bounding_box = BoundingBox(min: Coord(x: min_x, y: min_y),
                                               max: Coord(x: max_x, y: max_y))
                let group_brightness = UInt(group_amount) / group_size


                var outlier_amounts = [UInt32](repeating: 0, count: bounding_box.width*bounding_box.height)
                for x in min_x ... max_x {
                    for y in min_y ... max_y {
                        let index = y * self.width + x
                        if let pixel_group_name = outlier_group_list[index],
                           pixel_group_name == group_name
                        {
                            let pixel_amount = outlier_amount_list[index]
                            let idx = (y-min_y) * bounding_box.width + (x-min_x)
                            outlier_amounts[idx] = UInt32(pixel_amount)
                        }
                    }
                }
                
                outlier_groups[group_name] =
                  await OutlierGroup(name: group_name,
                                     size: group_size,
                                     brightness: group_brightness,
                                     bounds: bounding_box,
                                     frame: self,
                                     pixels: outlier_amounts,
                                     max_pixel_distance: max_pixel_distance)
            }
        }
        Log.i("frame \(frame_index) has \(outlier_groups.count) outlier groups")
    }

    // paint the outliers that we decided not to paint, to enable debuging
    private func testPaintOutliers(toData test_paint_data: inout Data) async {
        Log.d("frame \(frame_index) painting outliers green")

        for (name, group) in outlier_groups {
            for x in group.bounds.min.x ... group.bounds.max.x {
                for y in group.bounds.min.y ... group.bounds.max.y {
                    let pixel_index = (y-group.bounds.min.y)*group.bounds.width + (x - group.bounds.min.x)
                    if group.pixels[pixel_index] != 0 {                    
                        var nextPixel = Pixel()
                        if let reason = await group.shouldPaint,
                           !reason.willPaint
                        {
                            nextPixel.value = reason.testPaintPixel.value
                            
                            var nextValue = nextPixel.value
                            let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
                            
                            test_paint_data.replaceSubrange(offset ..< offset+self.bytesPerPixel,
                                                            with: &nextValue,
                                                            count: self.bytesPerPixel)
                        }
                    }
                }
            }
        }
    }

    // actually paint over outlier groups that have been selected as airplane tracks
    private func paintOverAirplanes(toData data: inout Data,
                                    testData test_paint_data: inout Data,
                                    otherFrames: [PixelatedImage]) async throws
    {
        Log.i("frame \(frame_index) painting airplane outlier groups")

        guard let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index])
        else { throw "Couldn't load image" }

        // paint over every outlier in the paint list with pixels from the adjecent frames
        for (group_name, group) in outlier_groups {
            if let reason = await group.shouldPaint,
               reason.willPaint
            {
                Log.d("frame \(frame_index) painting over group \(group_name) for reason \(reason)")
                //let x = index % width;
                //let y = index / width;
                for x in group.bounds.min.x ... group.bounds.max.x {
                    for y in group.bounds.min.y ... group.bounds.max.y {
                        let pixel_index = (y - group.bounds.min.y)*group.bounds.width + (x - group.bounds.min.x)
                        if group.pixels[pixel_index] != 0 {

                            let pixel_amount = group.pixels[pixel_index]

                            var alpha: Double = 0
                            
                            if pixel_amount > max_pixel_distance {
                                alpha = 1
                            } else if pixel_amount < min_pixel_distance {
                                alpha = 0
                            } else {
                                alpha = Double(UInt16(pixel_amount) - min_pixel_distance) /
                                  Double(max_pixel_distance - min_pixel_distance)
                            }

                            if alpha > 0 {
                                paint(x: x, y: y, why: reason, alpha: alpha,
                                      toData: &data,
                                      testData: &test_paint_data,
                                      image: image,
                                      otherFrames: otherFrames)
                            }
                        }
                    }
                }
                
            }
        }
    }

    private func writeTestFile(withData data: Data) async throws {
        guard let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index])
        else { throw "Couldn't load image" }
        try image.writeTIFFEncoding(ofData: data, toFilename: test_paint_filename)
    }

    // paint over a selected outlier pixel with data from pixels from adjecent frames
    private func paint(x: Int, y: Int,
                       why: PaintReason,
                       alpha: Double,
                       toData data: inout Data,
                       testData test_paint_data: inout Data,
                       image: PixelatedImage,
                       otherFrames: [PixelatedImage])
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
        var paint_pixel = Pixel(merging: pixels_to_paint_with)

        if alpha < 1 {
            let op = image.readPixel(atX: x, andY: y)
            paint_pixel = Pixel(merging: paint_pixel, with: op, atAlpha: alpha)
        }

        // this is the numeric value we need to write out to paint over the airplane
        var paint_value = paint_pixel.value
        
        // the is the place in the image data to write to
        let offset = (Int(y) * bytesPerRow) + (Int(x) * bytesPerPixel)
        
        // actually paint over that airplane like thing in the image data
        data.replaceSubrange(offset ..< offset+self.bytesPerPixel,
                             with: &paint_value, count: self.bytesPerPixel)
        
        // for testing, colors changed pixels
        if test_paint {
            var test_paint_pixel = why.testPaintPixel

            if alpha < 1 {
                let op = image.readPixel(atX: x, andY: y)
                test_paint_pixel = Pixel(merging: op, with: test_paint_pixel, atAlpha: alpha)
                //Log.i("alpha \(alpha) @ [\(x), \(y)]")
            }
            var test_paint_value = test_paint_pixel.value
            
            test_paint_data.replaceSubrange(offset ..< offset+self.bytesPerPixel,
                                            with: &test_paint_value,
                                            count: self.bytesPerPixel)
        }
    }
    
    // run after should_paint has been set for each group, 
    // does the final painting and then writes out the output files
    func finish() async throws {
        Log.i("frame \(self.frame_index) finishing")
        guard let image = try await image_sequence.getImage(withName: image_sequence.filenames[frame_index])
        else { throw "Couldn't load image" }

        var otherFrames: [PixelatedImage] = []

        for otherFrameIndex in otherFrameIndexes {
            guard let otherFrame = try await image_sequence.getImage(withName: image_sequence.filenames[otherFrameIndex])
            else { throw "Couldn't load image" }
            otherFrames.append(otherFrame)
        }
        
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
            await self.testPaintOutliers(toData: &test_paint_data)
        }
                  
        Log.d("frame \(self.frame_index) painting over airplanes")
                  
        try await self.paintOverAirplanes(toData: &output_data,
                                          testData: &test_paint_data,
                                          otherFrames: otherFrames)
        
        Log.d("frame \(self.frame_index) writing output files")

        do {
            try await self.writeTestFile(withData: test_paint_data)
            // write frame out as a tiff file after processing it
            try image.writeTIFFEncoding(ofData: output_data,  toFilename: self.output_filename)
        } catch {
            Log.e(error)
        }
        
        Log.i("frame \(self.frame_index) complete")
    }
    
    public static func == (lhs: FrameAirplaneRemover, rhs: FrameAirplaneRemover) -> Bool {
        return lhs.frame_index == rhs.frame_index
    }    

    // write out a set of text files that desribe each outlier group
    // these are the initial step of data generation
    func writeOutlierGroupFiles() {
        Log.e("writing outlier group images")              
        for (group_name, group) in self.outlier_groups {
            Log.i("writing text file for group \(group_name)")
            
            if let output_dirname = outlier_output_dirname
            {
                // XXX check the determined paintability of each group and write them
                // out to different output dirnames
                
                let filename = "\(frame_index)_outlier_\(group.name).txt".replacingOccurrences(of: ",", with: "_")
                
                let full_path = "\(output_dirname)/\(filename)"
                if file_manager.fileExists(atPath: full_path) {
                    Log.w("cannot write to \(full_path), it already exists")
                } else {
                    Log.i("creating \(full_path)")                      
                    var line = ""
                    
                    for y in 0 ..< group.bounds.height {
                        for x in 0 ..< group.bounds.width {
                            if group.pixels[y*group.bounds.width+x] != 0 {
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
