import Foundation
import CoreGraphics
import Cocoa



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
    let frame_count: Int
    let dispatch_group: DispatchGroup
    let final_queue: FinalQueue
    
    init(numberOfFrames frame_count: Int,
         dispatchGroup dispatch_group: DispatchGroup)
    {
        frames = [FrameAirplaneRemover?](repeating: nil, count: frame_count)
        self.frame_count = frame_count
        self.dispatch_group = dispatch_group
        self.final_queue = FinalQueue(max_concurrent: max_concurrent_frames,
                                   dispatchGroup: dispatch_group)
    }

    func add(frame: FrameAirplaneRemover, at index: Int) {
        Log.i("frame \(index) added")
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

    func finishAll() async {
        var count = 0
        for frame in frames {
            if let frame = frame {
                count += 1
                self.dispatch_group.enter()
                await self.final_queue.method_list.add(atIndex: frame.frame_index) {
                    frame.finish()
                    self.dispatch_group.leave()
                }
            }
        }
        let method_list_count = await self.final_queue.method_list.count
        Log.d("add all \(count) remaining frames to method list of count \(method_list_count)")
    }

    nonisolated func run(shouldProcess: [Bool]) async {

        await final_queue.start()
        
        var done = false
        while(!done) {
            done = await current_frame_index >= frames.count
            Log.d("done \(done)")
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
                }
            }
            if !bad {
                Log.i("processing frame index \(images_to_process.count) frames")
                self.handle(frames: images_to_process)
                await self.incrementCurrentFrameIndex()
                
                if start_index > 0 {
                    let immutable_start = start_index
                    dispatchQueue.async {
                        Task {
                            if let frame_to_finish = await self.frame(at: immutable_start - 1) {
                                self.dispatch_group.enter()
                                // XXX async here
                                Log.d("frame \(frame_to_finish.frame_index) adding at index ")
                                await self.final_queue.method_list.add(atIndex: frame_to_finish.frame_index) {
                                    Log.i("frame \(frame_to_finish.frame_index) finishing")
                                    frame_to_finish.finish()
                                    self.dispatch_group.leave()
                                }
                                Log.d("frame \(frame_to_finish.frame_index) done adding to index ")
                            }
                            await self.clearFrame(at: immutable_start - 1)
                        }
                    }
                }
            } else {
                sleep(1)        // XXX hardcoded sleep amount
            }
            //sleep(1)
        }

        Log.i("finishing all remaining frames")
        await self.finishAll()
        Log.d("check")
        await final_queue.finish()
        Log.d("done")
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
    
    // this method does a final pass on a group of frames, using
    // the angle of outlier groups that don't overlap between frames
    // to add a layer of airplane detection.
    // if two outlier groups are found in different frames, with close
    // to the same theta and rho, and they don't overlap, then they are
    // likely adject airplane tracks.
    // otherwise, if they do overlap, then it's more likely a cloud or 
    // a bright star or planet, leave them as is.  
    nonisolated func handle(frames: [FrameAirplaneRemover]) {
        Log.i("handle \(frames.count) frames")
        for frame in frames {
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

                        for (og_name, og_line) in other_frame.group_lines {
                            let other_line_theta = og_line.theta
                            let other_line_rho = og_line.rho

                            let theta_diff = abs(line_theta-other_line_theta)
                            let rho_diff = abs(line_rho-other_line_rho)
                            
                            if theta_diff < final_theta_diff && rho_diff < final_rho_diff {

                                if let other_line_min_x = other_frame.group_min_x[og_name],
                                   let other_line_min_y = other_frame.group_min_y[og_name],
                                   let other_line_max_x = other_frame.group_max_x[og_name],
                                   let other_line_max_y = other_frame.group_max_y[og_name],
                                   let other_group_size = other_frame.neighbor_groups[og_name]
                                {
                                    let mult = abs(frame.frame_index - other_frame.frame_index)
                                    // multiply the constant by how far the frames are away
                                    // from eachother in the sequence
                                    let amt = final_group_boundary_amt * mult
                                    // increate overlap amt by frame index difference
                                    if do_overlap(min_1_x: line_min_x - amt,
                                                 min_1_y: line_min_y - amt,
                                                 max_1_x: line_max_x + amt,
                                                 max_1_y: line_max_y + amt,
                                                 min_2_x: other_line_min_x - amt,
                                                 min_2_y: other_line_min_y - amt,
                                                 max_2_x: other_line_max_x + amt,
                                                 max_2_y: other_line_max_y + amt)
                                    {
                                        if group_size < final_overlapping_group_size,
                                           other_group_size < final_overlapping_group_size
                                        {
                                            // two somewhat small overlapping groups
                                            // shouldn't be painted over
                                            frame.should_paint[group_name] =
                                                (shouldPaint: false, why: .adjecentOverlap)
                                            other_frame.should_paint[og_name] =
                                                (shouldPaint: false, why: .adjecentOverlap)
                                            //Log.d("frame \(frame.frame_index) should_paint[\(group_name)] = (false, .adjecentOverlap)")
                                            //Log.d("frame \(other_frame.frame_index) should_paint[\(og_name)] = (false, .adjecentOverlap)")
                                        }
                                    } else {
                                        // don't overwrite adjecent overlaps
                                        var do_it = true
                                        
                                        if let (frame_should_paint, frame_why) =
                                               frame.should_paint[group_name]
                                        {
                                            if !frame_should_paint,
                                               frame_why == .adjecentOverlap
                                            {
                                                do_it = false
                                            }
                                        }

                                        if let (other_should_paint, other_why) = 
                                               other_frame.should_paint[og_name]
                                        {
                                            if !other_should_paint,
                                               other_why == .adjecentOverlap
                                            {
                                                do_it = false
                                            }
                                        }
                                        
                                        if do_it {
                                            // XXX perhaps keep a record of all matches
                                            // and vote?
                                            
                                            // mark as should paint
                                            //Log.d("frame \(frame.frame_index) should_paint[\(group_name)] = (true, .adjecentLine)")
                                            frame.should_paint[group_name] = (shouldPaint: true, why: .adjecentLine)
                                            
                                            //Log.d("frame \(other_frame.frame_index) should_paint[\(og_name)] = (true, .adjecentLine)")
                                            other_frame.should_paint[og_name] = (shouldPaint: true, why: .adjecentLine)
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
}


