import Foundation
import CoreGraphics
import Cocoa

/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/


// this class handles the final processing of every frame
// it observes its frames array, and is tasked with finishing
// each frame.  This means adjusting each frame's should_paint map
// to be concurent with those of the adjecent frames.
// at this point each frame has been processed to have a good idea of 
// what outlier groups to paint and not to paint.
// this process puts the final touches on the should_paint map of each
// frame and then calls finish() on it, which paints based upon the
// should_paint map, and then saves the output file(s).


@available(macOS 10.15, *)
actor FinalProcessor {
    var frames: [FrameAirplaneRemover?]
    var current_frame_index = 0
    var max_added_index = 0
    let frame_count: Int
    let dispatch_group: DispatchHandler
    let final_queue: FinalQueue

    var is_asleep = false
    
    init(numberOfFrames frame_count: Int,
         dispatchGroup dispatch_group: DispatchHandler)
    {
        frames = [FrameAirplaneRemover?](repeating: nil, count: frame_count)
        self.frame_count = frame_count
        self.dispatch_group = dispatch_group
        self.final_queue = FinalQueue(max_concurrent: max_concurrent_frames,
                                      dispatchGroup: dispatch_group)
    }

    func add(frame: FrameAirplaneRemover, at index: Int) {
        Log.i("FINAL THREAD frame \(index) added for final inter-frame analysis")
        if index > max_added_index {
            max_added_index = index
        }
        frames[index] = frame
    }

    func clearFrame(at index: Int) {
        frames[index] = nil
    }
    func incrementCurrentFrameIndex() {
        current_frame_index += 1
    }

    func frame(at index: Int) -> FrameAirplaneRemover? {
        return frames[index]
    }

    func setAsleep(to value: Bool) {
        self.is_asleep = value
    }

    var framesBetween: Int {
        var ret = max_added_index - current_frame_index
        if ret < 0 { ret = 0 }
        return ret
    }
    
    var isWorking: Bool {
        get {
            return !is_asleep
        }
    }
    
    func finishAll() async {
        var count = 0
        for frame in frames {
            if let frame = frame {
                let name = "finishAll \(count)"
                self.dispatch_group.enter(name)
                count += 1
                await self.final_queue.method_list.add(atIndex: frame.frame_index) {
                    frame.finish()
                    self.dispatch_group.leave(name)
                }
            }
        }
        let method_list_count = await self.final_queue.method_list.count
        Log.d("add all \(count) remaining frames to method list of count \(method_list_count)")
    }

    nonisolated func run(shouldProcess: [Bool]) async {

        await final_queue.start()
        let frame_count = await frames.count
        
        var done = false
        while(!done) {
            done = await current_frame_index >= frames.count
            //Log.d("done \(done)")
            if done { continue }
            
            let index_to_process = await current_frame_index
            if !shouldProcess[index_to_process] {
                await self.incrementCurrentFrameIndex()
                continue
            }
            
            var images_to_process: [FrameAirplaneRemover] = []
            
            var start_index = index_to_process - number_final_processing_neighbors_needed
            var end_index = index_to_process + number_final_processing_neighbors_needed
            if start_index < 0 {
                start_index = 0
            }
            if end_index >= frame_count {
                end_index = frame_count - 1
            }
            
            var bad = false
            for i in start_index ... end_index {
                if let next_frame = await self.frame(at: i) {
                    images_to_process.append(next_frame)
                } else {
                    bad = true
                    // XXX bad
                    //Log.d("FINAL THREAD bad")
                }
            }
            if !bad {
                Log.i("FINAL THREAD frame \(index_to_process) doing inter-frame analysis with \(images_to_process.count) frames")
                self.handle(frames: images_to_process)
                Log.d("FINAL THREAD frame \(index_to_process) done with inter-frame analysis")
                await self.incrementCurrentFrameIndex()
                if start_index > 0 && index_to_process < frame_count - number_final_processing_neighbors_needed - 1 {
                    // maybe finish a previous frame
                    // leave the ones at the end to finishAll()
                    let immutable_start = start_index
                    //Log.d("FINAL THREAD frame \(index_to_process) queueing into final queue")
                    dispatchQueue.async {
                        Task {
                            if let frame_to_finish = await self.frame(at: immutable_start - 1) {
                                let final_frame_group_name = "final frame \(frame_to_finish.frame_index)"
                                self.dispatch_group.enter(final_frame_group_name)
                                // XXX async here
                                Log.d("frame \(frame_to_finish.frame_index) adding at index ")
                                await self.final_queue.method_list.add(atIndex: frame_to_finish.frame_index) {
                                    Log.i("frame \(frame_to_finish.frame_index) finishing")
                                    frame_to_finish.finish()
                                    Log.i("frame \(frame_to_finish.frame_index) finished")
                                    self.dispatch_group.leave(final_frame_group_name)
                                }
                                //Log.d("frame \(frame_to_finish.frame_index) done adding to index ")
                            }
                            await self.clearFrame(at: immutable_start - 1)
                        }
                    }
                    //Log.d("FINAL THREAD frame \(index_to_process) done queueing into final queue")
                }
            } else {
                //Log.d("FINAL THREAD sleeping")
                await self.setAsleep(to: true)
                sleep(1)        // XXX hardcoded sleep amount
                //Log.d("FINAL THREAD waking up")
                await self.setAsleep(to: false)
            }
            //sleep(1)
        }

        Log.i("FINAL THREAD finishing all remaining frames")
        await self.finishAll()
        Log.d("FINAL THREAD check")
        await final_queue.finish()
        Log.d("FINAL THREAD done")
    }
    
    nonisolated func do_overlap(min_1_x: Int, min_1_y: Int,
                            max_1_x: Int, max_1_y: Int,
                            min_2_x: Int, min_2_y: Int,
                            max_2_x: Int, max_2_y: Int) -> Bool
    {
        if min_1_x <= min_2_x && min_2_x <= max_1_x ||
           min_1_x <= max_2_x && max_2_x <= max_1_x
        {
            // min_2_x is bewteen min_1_x and max_1_x
            //   or 
            // max_2_x is bewteen min_1_x and max_1_x
            if min_1_y <= min_2_y && min_2_y <= max_1_y {
                // min_2_y is bewteen min_1_y and max_1_y
                return true
            }
            if min_1_y <= max_2_y && max_2_y <= max_1_y {
                // max_2_y is bewteen min_1_y and max_1_y
                return true
            }
        }
        return false
    }
    
    nonisolated func overlap_amount(min_1_x: Int, min_1_y: Int,
                                    max_1_x: Int, max_1_y: Int,
                                    min_2_x: Int, min_2_y: Int,
                                    max_2_x: Int, max_2_y: Int) -> Double
    {
        let half_width_1 = (max_1_x - min_1_x)/2
        let half_height_1 = (max_1_y - min_1_y)/2
        
        let half_width_2 = (max_2_x - min_2_x)/2
        let half_height_2 = (max_2_y - min_2_y)/2
        
        let center_1_x = min_1_x + half_width_1
        let center_1_y = min_1_y + half_height_1

        let center_2_x = min_2_x + half_width_2
        let center_2_y = min_2_y + half_height_2

        let center_distance_x = abs(center_1_x - center_2_x)
        let center_distance_y = abs(center_1_y - center_2_y)

        let overlap_x = center_distance_x - half_width_1 - half_width_2
        let overlap_y = center_distance_y - half_height_1 - half_height_2

        let do_overlap = overlap_x < 0 && overlap_y < 0

        let double_overlap_x = Double(overlap_x)
        let double_overlap_y = Double(overlap_y)
        let overlap_amount = sqrt(double_overlap_x * double_overlap_x + double_overlap_y * double_overlap_y)

        if do_overlap {
           return -overlap_amount // negative value means they do overlap
        } else {
            return overlap_amount
        }
    }
    
    // this method does a final pass on a group of frames, using
    // the angle of outlier groups that don't overlap between frames
    // to add a layer of airplane detection.
    // if two outlier groups are found in different frames, with close
    // to the same theta and rho, and they don't overlap, then they are
    // likely adject airplane tracks.
    // otherwise, if they do overlap, then it's more likely a cloud or 
    // a bright star or planet, leave them as is.  
    nonisolated func handle(frames: [FrameAirplaneRemover]) {
        Log.d("final pass on \(frames.count) frames")
        for frame in frames {
            //Log.d("frame.group_lines.count \(frame.group_lines.count)")
            for (group_name, group_line) in frame.group_lines {
                // look for

                let line_theta = group_line.theta
                let line_rho = group_line.rho

                if let line_min_x = frame.group_min_x[group_name],
                   let line_min_y = frame.group_min_y[group_name],
                   let line_max_x = frame.group_max_x[group_name],
                   let line_max_y = frame.group_max_y[group_name],
                   let group_size = frame.neighbor_groups[group_name]
                {
                    for other_frame in frames {
                        if other_frame == frame { continue }
                        //Log.d("other frame.group_lines.count \(other_frame.group_lines.count)")

                        for (og_name, og_line) in other_frame.group_lines {
                            let other_line_theta = og_line.theta
                            let other_line_rho = og_line.rho

                            let theta_diff = abs(line_theta-other_line_theta)
                            let rho_diff = abs(line_rho-other_line_rho)
                            
                            if let other_line_min_x = other_frame.group_min_x[og_name],
                               let other_line_min_y = other_frame.group_min_y[og_name],
                               let other_line_max_x = other_frame.group_max_x[og_name],
                               let other_line_max_y = other_frame.group_max_y[og_name],
                               let other_group_size = other_frame.neighbor_groups[og_name]
                            {
                                //Log.d("frame \(frame.frame_index) group 1 \(group_name) of size \(group_size) (\(line_min_x) \(line_min_y)),  (\(line_max_x) \(line_max_y)) other frame \(other_frame.frame_index) group 2 \(og_name) of size \(group_size) (\(other_line_min_x) \(other_line_min_y)),  (\(other_line_max_x) \(other_line_max_y))")
                                
                                let mult = abs(frame.frame_index - other_frame.frame_index)
                                // multiply the constant by how far the frames are away
                                // from eachother in the sequence
                                let amt = Double(final_group_boundary_amt * mult)
                                // increate overlap amt by frame index difference
                                let overlap_amount = overlap_amount(min_1_x: line_min_x,
                                                                    min_1_y: line_min_y,
                                                                    max_1_x: line_max_x,
                                                                    max_1_y: line_max_y,
                                                                    min_2_x: other_line_min_x,
                                                                    min_2_y: other_line_min_y,
                                                                    max_2_x: other_line_max_x,
                                                                    max_2_y: other_line_max_y)
                                //Log.d("overlap_amount \(overlap_amount) amt \(amt)")
                                if overlap_amount < amt {
                                    // XXX This is wrong for frame 1058 in 09_24_2022-a9-2
                                    
                                    // two overlapping groups
                                    // shouldn't be painted over
                                    frame.should_paint[group_name] =
                                        (shouldPaint: false, why: .adjecentOverlap(-overlap_amount))
                                    other_frame.should_paint[og_name] =
                                        (shouldPaint: false, why: .adjecentOverlap(-overlap_amount))
                                    //Log.d("frame \(frame.frame_index) should_paint[\(group_name)] = (false, .adjecentOverlap)")
                                    //Log.d("frame \(other_frame.frame_index) should_paint[\(og_name)] = (false, .adjecentOverlap)")
                                    
                                } else if theta_diff < final_theta_diff && rho_diff < final_rho_diff {
                                        
                                    // don't overwrite adjecent overlaps
                                    var do_it = true
                                        
                                    if let (frame_should_paint, frame_why) =
                                           frame.should_paint[group_name]
                                    {
                                        if !frame_should_paint &&
                                             (frame_why == .adjecentOverlap(-1) ||
                                                frame_why == .tooBlobby(0,0)) // XXX -1
                                        {
                                            do_it = false
                                        }
                                    }
                                    
                                    if let (other_should_paint, other_why) = 
                                           other_frame.should_paint[og_name]
                                    {
                                        if !other_should_paint &&
                                             (other_why == .adjecentOverlap(-1) || 
                                                other_why == .tooBlobby(0,0))  // XXX -1
                                        {
                                            do_it = false
                                        }
                                    }
                                    
                                    if do_it {
                                        // XXX perhaps keep a record of all matches
                                        // and vote?
                                        
                                        // mark as should paint
                                        //Log.d("frame \(frame.frame_index) should_paint[\(group_name)] = (true, .adjecentLine(\(theta_diff), \(rho_diff))) overlap_amount \(overlap_amount) amt \(amt)")
                                        frame.should_paint[group_name] = (shouldPaint: true,
                                                                          why: .adjecentLine(theta_diff, rho_diff)) // XXX -1
                                        
                                        //Log.d("frame \(other_frame.frame_index) should_paint[\(og_name)] = (true, .adjecentLine(\(theta_diff), \(rho_diff))) overlap_amount \(overlap_amount) \(amt)")
                                        other_frame.should_paint[og_name] = (shouldPaint: true,
                                                                             why: .adjecentLine(theta_diff, rho_diff)) // XXX -1
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}


