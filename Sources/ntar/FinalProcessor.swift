/*

This file is part of the Nightime Timelapse Airplane Remover (ntar).

ntar is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

ntar is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with ntar. If not, see <https://www.gnu.org/licenses/>.

*/

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
// frame and then sticks into the final queue to which calls finish() on it,
// which paints based upon the should_paint map, and then saves the output file(s).


    // identified airplane trails XXX why is this a global?  put this in the class and make these funcs part of it
var airplane_streaks: [String:[AirplaneStreakMember]] = [:] // XXX make this a map
// XXX may need to prune this eventually, for memory concerns

@available(macOS 10.15, *)
actor FinalProcessor {
    var frames: [FrameAirplaneRemover?]
    var current_frame_index = 0
    var max_added_index = 0
    let frame_count: Int
    let dispatch_group: DispatchHandler
    let final_queue: FinalQueue
    let max_concurrent: UInt

    var is_asleep = false
    
    init(numberOfFrames frame_count: Int,
         maxConcurrent max_concurrent: UInt,
         dispatchGroup dispatch_group: DispatchHandler)
    {
        frames = [FrameAirplaneRemover?](repeating: nil, count: frame_count)
        self.max_concurrent = max_concurrent
        self.frame_count = frame_count
        self.dispatch_group = dispatch_group
        self.final_queue = FinalQueue(max_concurrent: max_concurrent,
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
        Log.d("finishing all")
        var count = 0
        for frame in frames {
            if let frame = frame {
                count += 1
                await self.final_queue.method_list.add(atIndex: frame.frame_index) {
                    await frame.finish()
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
            let (cfi, frames_count) = await (current_frame_index, frames.count)
            done = cfi >= frames_count
            Log.d("done \(done) current_frame_index \(cfi) frames.count \(frames_count)")
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
            //var index_in_images_to_process_of_main_frame = 0
            //var index_in_images_to_process = 0
            for i in start_index ... end_index {
                if let next_frame = await self.frame(at: i) {
                    images_to_process.append(next_frame)
                    //if i == index_to_process {
                        //index_in_images_to_process_of_main_frame = index_in_images_to_process
                //}
                    //index_in_images_to_process += 1
                } else {
                    bad = true
                    // XXX bad
                    //Log.d("FINAL THREAD bad")
                }
            }
            if !bad {
                Log.i("FINAL THREAD frame \(index_to_process) doing inter-frame analysis with \(images_to_process.count) frames")
                await run_final_pass(frames: images_to_process)
                Log.d("FINAL THREAD frame \(index_to_process) done with inter-frame analysis")
                await self.incrementCurrentFrameIndex()


                if start_index > 0 && index_to_process < frame_count - number_final_processing_neighbors_needed - 1 {
                    // maybe finish a previous frame
                    // leave the ones at the end to finishAll()
                    let immutable_start = start_index
                    //Log.d("FINAL THREAD frame \(index_to_process) queueing into final queue")
                    if let frame_to_finish = await self.frame(at: immutable_start - 1),
                       let next_frame = await self.frame(at: immutable_start)
                       {

                        await really_final_streak_processing(onFrame: frame_to_finish,
                                                             nextFrame: next_frame)
// add a outlier streak validation step right before a frame is handed to the final queue for finalizing.
// identify all existing streaks with length of only 2
// try to find other nearby streaks, if not found, then skip for new not paint reason
                

                        
                        let final_frame_group_name = "final frame \(frame_to_finish.frame_index)"
                        await self.dispatch_group.enter(final_frame_group_name)
                        dispatchQueue.async {
                            Task {
                                Log.d("frame \(frame_to_finish.frame_index) adding at index ")
                                await self.final_queue.method_list.add(atIndex: frame_to_finish.frame_index) {
                                    Log.i("frame \(frame_to_finish.frame_index) finishing")
                                    await frame_to_finish.finish()
                                    Log.i("frame \(frame_to_finish.frame_index) finished")
                                }
                                //Log.d("frame \(frame_to_finish.frame_index) done adding to index ")
                                await self.clearFrame(at: immutable_start - 1)
                                await self.dispatch_group.leave(final_frame_group_name)
                            }
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
}    

// add a outlier streak validation step right before a frame is handed to the final queue for finalizing.
// identify all existing streaks with length of only 2
// try to find other nearby streaks, if not found, then skip for new not paint reason
@available(macOS 10.15, *)
func really_final_streak_processing(onFrame frame: FrameAirplaneRemover,
                                    nextFrame next_frame: FrameAirplaneRemover) async {
    // at this point, all frames before the given frame have been processed fully.
    // number_final_processing_neighbors_needed more neighbors have already had their
    // outlier group data added to the airplane_streaks map
    
    // look through all streaks
    // if the last member's frame index is less than here - 1, then discard it
    // if the streak has only two members, then:
    //   - look through all other streaks, and see if any of them might match up to it
    //     for both position and rough alignment of their members
    
    for (streak_name, airplane_streak) in airplane_streaks {
        if let last_member = airplane_streak.last {
            if last_member.frame_index < frame.frame_index - 5 { // XXX arbitrary, just to be sure 
                // delete the older streak we don't need anymore
                airplane_streaks.removeValue(forKey: streak_name)
            }
        }
    }
    
    for (streak_name, airplane_streak) in airplane_streaks {
        if airplane_streak.count == 2 {
            let first_member = airplane_streak[0]
            let last_member = airplane_streak[1]
            if last_member.frame_index == frame.frame_index || 
                 first_member.frame_index == frame.frame_index
            {
                var remove_small_streak = true
                
                // this is a two member airplane streak that is on our frame
                // look for other streaks that might match up to it on either side
                // if neither found, then dump it
                
                for (other_streak_name, other_airplane_streak) in airplane_streaks {
                    if other_streak_name == streak_name { continue }
                    
                    // this streak must begin or end at the right end of this 2 count streak
                    
                    if let last_other_airplane_streak = other_airplane_streak.last {
                        let first_other_airplane_streak = other_airplane_streak[0]

                        let move_me_theta_diff: Double = 20      // XXX move me
                        
                        if first_member.frame_index == last_other_airplane_streak.frame_index + 1 {
                            // found a streak that ended right before this one started
                            
                            let distance = edge_distance(from: last_other_airplane_streak.bounds,
                                                         to: first_member.bounds)

                            let theta_diff = abs(last_other_airplane_streak.line.theta -
                                                   first_member.line.theta)
                            
                            let hypo_avg = (first_member.bounds.hypotenuse +
                                              last_other_airplane_streak.bounds.hypotenuse)/2

                            let move_me_distance_limit = hypo_avg + 2 // XXX contstant
                            
                            // XXX constant
                            if distance < move_me_distance_limit && theta_diff < move_me_theta_diff {
                                remove_small_streak = false
                            }
                            
                        } else if last_member.frame_index + 1 == first_other_airplane_streak.frame_index {
                            // found a streak that starts right after this one ends
                            let distance = edge_distance(from: last_member.bounds,
                                                         to: first_other_airplane_streak.bounds)

                            let theta_diff = abs(first_other_airplane_streak.line.theta -
                                                   last_member.line.theta)

                            let hypo_avg = (last_member.bounds.hypotenuse +
                                              first_other_airplane_streak.bounds.hypotenuse)/2

                            let move_me_distance_limit =  hypo_avg + 2 // XXX contstant

                            if distance < move_me_distance_limit && theta_diff < move_me_theta_diff {
                                remove_small_streak = false
                            }
                        }
                    }
                }
                
                if remove_small_streak {
                    airplane_streaks.removeValue(forKey: streak_name) // XXX mutating while iterating?
                    
                    for member_to_remove in airplane_streak {
                        // change should_paint to new value for the frame
                        if member_to_remove.frame_index < frame.frame_index {
                            Log.e("frame \(member_to_remove.frame_index) is already finalized, modifying it now won't change anythig :(")
                            fatalError("FUCK")
                        }
                        if member_to_remove.frame_index == frame.frame_index {
                            // process the passed frame
                             await frame.setShouldPaint(group: member_to_remove.group_name,
                                                        why: .isolatedTwoStreak)
                        } else if member_to_remove.frame_index == next_frame.frame_index {
                            await next_frame.setShouldPaint(group: member_to_remove.group_name,
                                                             why: .isolatedTwoStreak)
                        } else {
                            Log.e("FUCK")
                            fatalError("doh")
                        }
                    }
                }
            }
        }
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
@available(macOS 10.15, *)
fileprivate func run_final_pass(frames: [FrameAirplaneRemover]) async {
    Log.d("final pass on \(frames.count) frames")

    await run_final_overlap_pass(frames: frames)
    await run_final_streak_pass(frames: frames)
}


@available(macOS 10.15, *)
fileprivate func run_final_overlap_pass(frames: [FrameAirplaneRemover]) async {
    for frame in frames {
        //Log.d("frame.group_lines.count \(frame.group_lines.count)")
        for (group_name, group_line) in await frame.group_lines {
            // look for more data to act upon

            if let reason = await frame.should_paint[group_name],
               reason.willPaint
            {
                switch reason {
                case .looksLikeALine:
                    Log.i("frame \(frame.frame_index) skipping group \(group_name) because of \(reason)") 
                    continue
                case .inStreak(let size):
                    if size > 2 {
                        Log.i("frame \(frame.frame_index) skipping group \(group_name) because of \(reason)") 
                        // XXX this skips streaks that it shouldn't
                    }
                    //continue
                default:
                    break
                }
            }
            
            let line_theta = group_line.theta
            let line_rho = group_line.rho

            if let group_bounds = await frame.group_bounding_boxes[group_name],
               let group_size = await frame.neighbor_groups[group_name]
            {
                for other_frame in frames {
                    if other_frame == frame { continue }
                    //Log.d("other frame.group_lines.count \(other_frame.group_lines.count)")

                    for (og_name, og_line) in await other_frame.group_lines {
                        let other_line_theta = og_line.theta
                        let other_line_rho = og_line.rho

                        let theta_diff = abs(line_theta-other_line_theta)
                        let rho_diff = abs(line_rho-other_line_rho)
                        if (theta_diff < final_theta_diff || abs(theta_diff - 180) < final_theta_diff) &&
                            rho_diff < final_rho_diff
                        {
                            if let other_group_bounds = await frame.group_bounding_boxes[og_name],
                               let other_group_size = await other_frame.neighbor_groups[og_name]
                            {
                                let pixel_overlap_amount =
                                  await pixel_overlap(box_1: group_bounds,
                                                      group_1_name: group_name,
                                                      group_1_frame: frame,
                                                      box_2: other_group_bounds,
                                                      group_2_name: og_name,
                                                      group_2_frame: other_frame)


                                //Log.d("frame \(frame.frame_index) \(group_name) \(og_name) pixel_overlap_amount \(pixel_overlap_amount)")
                                
                                if pixel_overlap_amount > 0.05 { // XXX hardcoded constant
                                
                                    var do_it = true

                                    // do paint over objects that look like lines
                                    if let frame_reason = await frame.should_paint[group_name]
                                    {
                                        if frame_reason.willPaint && frame_reason == .looksLikeALine {
                                            do_it = false
                                        }
                                    }
                                    
                                    if let other_reason = await other_frame.should_paint[og_name]
                                    {
                                        if other_reason.willPaint && other_reason == .looksLikeALine {
                                            do_it = false
                                        }
                                    }
                                    
                                    if do_it {
                                        // two overlapping groups
                                        // shouldn't be painted over
                                        let _ = await (
                                                frame.setShouldPaint(group: group_name,
                                                                     why: .adjecentOverlap(pixel_overlap_amount)),
                                                other_frame.setShouldPaint(group: og_name,
                                                                           why: .adjecentOverlap(pixel_overlap_amount)))
                                        
                                        //Log.d("frame \(frame.frame_index) should_paint[\(group_name)] = (false, .adjecentOverlap(\(pixel_overlap_amount))")
                                        //Log.d("frame \(other_frame.frame_index) should_paint[\(og_name)] = (false, .adjecentOverlap(\(pixel_overlap_amount))")
                                    } else {
                                        //Log.d("frame \(frame.frame_index) \(group_name) left untouched because of pixel overlap amount \(pixel_overlap_amount)")
                                        //Log.d("frame \(other_frame.frame_index) \(og_name) left untouched because of pixel overlap amount \(pixel_overlap_amount)")
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


// 
@available(macOS 10.15, *)
fileprivate func run_final_streak_pass(frames: [FrameAirplaneRemover]) async {

    let initial_frame_index = frames[0].frame_index
    
    for (batch_index, frame) in frames.enumerated() {
        let frame_index = frame.frame_index
        Log.w("frame_index \(frame_index)")
        if batch_index + 1 == frames.count { continue } // the last frame can be ignored here

        for (group_name, group_line) in await frame.group_lines {
            // look for more data to act upon

            if let reason = await frame.should_paint[group_name] {
                if reason == .adjecentOverlap(0) {
                    Log.d("frame \(frame.frame_index) skipping group \(group_name) because it has .adjecentOverlap")
                    continue
                }

                // grab a streak that we might already be in

                var existing_streak: [AirplaneStreakMember]?
                var existing_streak_name: String?
                
                for (streak_name, airplane_streak) in airplane_streaks {
                    if let _ = existing_streak { continue }
                    for streak_member in airplane_streak {
                        if frame_index == streak_member.frame_index &&
                             group_name == streak_member.group_name
                        {
                            existing_streak = airplane_streak
                            existing_streak_name = streak_name
                            Log.i("frame \(frame.frame_index) using existing streak for \(group_name)")
                            continue
                        }
                    }
                }

                if let group_bounds = await frame.group_bounding_boxes[group_name] {
                    Log.d("frame \(frame_index) looking for streak for group \(group_name)")
                    // search neighboring frames looking for potential tracks

                    // see if this group is already part of a streak, and pass that in

                    // if not, pass in the starting potential one frame streak

                    var potential_streak: [AirplaneStreakMember] = [(frame_index, group_name,
                                                                     group_bounds, group_line)]
                    var potential_streak_name = "\(frame_index).\(group_name)"
                    
                    if let existing_streak = existing_streak,
                       let existing_streak_name = existing_streak_name
                    {
                        potential_streak = existing_streak
                        potential_streak_name = existing_streak_name
                    }
                    
                    if let streak = 
                         await streak_starting_from(groupName: group_name,
                                                    groupLine: group_line,
                                                    groupBounds: group_bounds,
                                                    frames: frames,
                                                    startingIndex: batch_index+1,
                                                    potentialStreak: &potential_streak)
                    {
                        Log.i("frame \(frame_index) found streak \(potential_streak_name) of size \(streak.count) for group \(group_name)")
                        airplane_streaks[potential_streak_name] = streak
                    } else {
                        Log.d("frame \(frame_index) DID NOT find streak for group \(group_name)")
                    }
                }
            }
        }
    }

    // go through and mark all of airplane_streaks to paint
    Log.i("analyzing \(airplane_streaks.count) streaks")
    for (streak_name, airplane_streak) in airplane_streaks {
        let first_member = airplane_streak[0]
        Log.i("analyzing streak \(streak_name) starting with group \(first_member.group_name) frame_index \(first_member.frame_index) with \(airplane_streak.count) members")
        // XXX perhaps reject small streaks?
        //if airplane_streak.count < 3 { continue } 
        var verbotten = false
        var was_already_paintable = false
        //let index_of_first_streak = airplane_streak[0].frame_index
        for streak_member in airplane_streak {
            if streak_member.frame_index - initial_frame_index < 0 ||
               streak_member.frame_index - initial_frame_index >= frames.count {
                // these are frames that are part of the streak, but not part of the batch
                // being processed right now,
            } else {
                let frame = frames[streak_member.frame_index - initial_frame_index]
                if let should_paint = await frame.should_paint[streak_member.group_name] {
                    if should_paint == .adjecentOverlap(0) { verbotten = true }
                    //                if should_paint.willPaint { was_already_paintable = true }
                }
            }
        }
        if verbotten/* || !was_already_paintable*/ { continue }
        Log.i("painting over streak with \(airplane_streak.count) members")
        for streak_member in airplane_streak {
            if streak_member.frame_index - initial_frame_index < 0 ||
               streak_member.frame_index - initial_frame_index >= frames.count {
                // these are frames that are part of the streak, but not part of the batch
                // being processed right now,
            } else {
                let frame = frames[streak_member.frame_index - initial_frame_index]
                Log.d("frame \(streak_member.frame_index) will paint group \(streak_member.group_name) is .inStreak")

                // XXX check to see if this is already .inStreak with higher count
                await frame.setShouldPaint(group: streak_member.group_name, why: .inStreak(airplane_streak.count))
            }
        }
    }

}

typealias AirplaneStreakMember = (
  frame_index: Int,
  group_name: String,
  bounds: BoundingBox,
  line: Line
)

struct BoundingBox {
    let min: Coord
    let max: Coord

    var hypotenuse: Double {
        let width = Double(self.max.x - self.min.x)
        let height = Double(self.max.y - self.min.y)
        return sqrt(width*width + height*height)
    }
}


// see if there is a streak of airplane tracks starting from the given group
// a 'streak' is a set of outliers with simlar theta and rho, that are
// close enough to eachother, and that are moving in close enough to the same
// direction as the lines that describe them.
@available(macOS 10.15, *)
func streak_starting_from(groupName group_name: String,
                          groupLine group_line: Line,
                          groupBounds group_bounds: BoundingBox,
                          frames: [FrameAirplaneRemover],
                          startingIndex starting_index: Int,
                          potentialStreak potential_streak: inout [AirplaneStreakMember])
  async -> [AirplaneStreakMember]?
{

    //Log.d("trying to find streak starting at \(group_name)")
    
    // the bounding box of the last element of the streak
    var last_bounds = group_bounds
    var last_group_line = group_line

    // the best match found so far for a possible streak etension
    var best_bounds = group_bounds
    var best_frame_index = 0
    var best_group_name = group_name
    var best_group_line = group_line
    
    var count = 1
/*
    Log.d("streak:")
    for index in starting_index ..< frames.count {
        let frame = frames[index]
        Log.d("streak index \(index) frame \(frame.frame_index)")
    }
*/
    //Log.d("starting_index \(starting_index)  \(frames.count)")
    for index in starting_index ..< frames.count {
        let frame = frames[index]
        let frame_index = frame.frame_index
        count += 1

        let last_hypo = last_bounds.hypotenuse
        // calculate min distance from hypotenuse of last bounding box
        let min_distance: Double = last_hypo * 1.3 // XXX hardcoded constant
        
        var best_distance = min_distance
        //Log.d("looking at frame \(frame.frame_index)")
        for (other_group_name, other_group_line) in await frame.group_lines {
            if let group_bounds = await frame.group_bounding_boxes[other_group_name]
            {
                // XXX not sure this value is right
                // really we want the distance between the nearest pixels of each group
                // this isn't close enough for real
                let distance = edge_distance(from: last_bounds, to: group_bounds)

                let center_line_theta = center_theta(from: last_bounds, to: group_bounds)

                let theta_diff = abs(last_group_line.theta-other_group_line.theta)
                let rho_diff = abs(last_group_line.rho-other_group_line.rho)

                let center_line_theta_diff_1 = abs(center_line_theta-other_group_line.theta)
                let center_line_theta_diff_2 = abs(center_line_theta-last_group_line.theta)

                if distance < best_distance &&
                  (theta_diff < final_theta_diff || abs(theta_diff - 180) < final_theta_diff) &&
                  ((center_line_theta_diff_1 < center_line_theta_diff ||
                     abs(center_line_theta_diff_1 - 180) < center_line_theta_diff) ||
                  (center_line_theta_diff_2 < center_line_theta_diff ||
                     abs(center_line_theta_diff_2 - 180) < center_line_theta_diff)) &&
                   rho_diff < final_rho_diff
                {
                    best_bounds = group_bounds
                    best_group_name = other_group_name
                    best_group_line = other_group_line
                    best_distance = distance
                    best_frame_index = frame_index // XXX this WAS wrong
                } else {
                    //Log.d("frame \(frame.frame_index) group \(other_group_name) doesn't match group \(group_name) theta_diff \(theta_diff) rho_diff \(rho_diff) center_line_theta_diff_1 \(center_line_theta_diff_1) center_line_theta_diff_2 \(center_line_theta_diff_2) center_line_theta \(center_line_theta) last \(last_group_line.theta) other \(other_group_line.theta)")
                }
            }
        }
        if best_distance == min_distance {
            break               // no more streak
        } else {
            if best_frame_index == frame.frame_index {

                if let last_streak_item = potential_streak.last,//[potential_streak.count-1] {
                   best_frame_index > last_streak_item.frame_index
                {
                    // streak on
                    last_bounds = best_bounds
                    last_group_line = best_group_line
                    //Log.d("frame \(frame.frame_index) adding group \(best_group_name) to streak")
                    potential_streak.append((best_frame_index, best_group_name,
                                             best_bounds, best_group_line))
                }
            } else {
                break           // no more streak
            }
        }
    }
    if potential_streak.count == 1 {
        return nil              // nothing added
    } else {
        //Log.d("returning potential_streak \(potential_streak)")
        return potential_streak
    }
}


enum Edge {
    case vertical
    case horizontal
}

// the distance between the center point of the box described and the exit of the line from it
func distance_on(box bounding_box: BoundingBox,
                 slope: Double, y_intercept: Double, theta: Double) -> Double
{
    var edge: Edge = .horizontal
    let y_max_value = Double(bounding_box.max.x)*slope + Double(y_intercept)
    let x_max_value = Double(bounding_box.max.y)-y_intercept/slope
    //let y_min_value = Double(min_x)*slope + Double(y_intercept)
    //let x_min_value = Double(bounding_box.min.y)-y_intercept/slope

    // there is an error introduced by integer to floating point conversions
    let math_accuracy_error: Double = 3
    
    if Double(bounding_box.min.y) - math_accuracy_error <= y_max_value && y_max_value <= Double(bounding_box.max.y) + math_accuracy_error {
        //Log.d("vertical")
        edge = .vertical
    } else if Double(bounding_box.min.x) - math_accuracy_error <= x_max_value && x_max_value <= Double(bounding_box.max.x) + math_accuracy_error {
        //Log.d("horizontal")
        edge = .horizontal
    } else {
        //Log.d("slope \(slope) y_intercept \(y_intercept) theta \(theta)")
        //Log.d("min_x \(min_x) x_max_value \(x_max_value) bounding_box.max.x \(bounding_box.max.x)")
        //Log.d("bounding_box.min.y \(bounding_box.min.y) y_max_value \(y_max_value) bounding_box.max.y \(bounding_box.max.y)")
        //Log.d("min_x \(min_x) x_min_value \(x_min_value) bounding_box.max.x \(bounding_box.max.x)")
        //Log.d("bounding_box.min.y \(bounding_box.min.y) y_min_value \(y_min_value) bounding_box.max.y \(bounding_box.max.y)")
        // this means that the line generated from the given slope and line
        // does not intersect the rectangle given 

        // can happen for situations of overlapping areas like this:
        //(1119 124),  (1160 153)
        //(1122 141),  (1156 160)

        // is this really a problem? not sure
        //Log.d("the line generated from the given slope and line does not intersect the rectangle given")
    }

    var hypotenuse_length: Double = 0
    
    switch edge {
    case .vertical:
        let half_width = Double(bounding_box.max.x - bounding_box.min.x)/2
        //Log.d("vertical half_width \(half_width)")
        hypotenuse_length = half_width / cos((90/180*Double.pi)-theta)
        
    case .horizontal:
        let half_height = Double(bounding_box.max.y - bounding_box.min.y)/2
        //Log.d("horizontal half_height \(half_height)")
        hypotenuse_length = half_height / cos(theta)
    }
    
    return hypotenuse_length
}
/*
func center_distance(min_1_x: Int, min_1_y: Int,
                     max_1_x: Int, max_1_y: Int,
                     min_2_x: Int, min_2_y: Int,
                     max_2_x: Int, max_2_y: Int)
    -> Double // positive if they don't overlap, negative if they do
{
    let half_width_1 = Double(max_1_x - min_1_x)/2
    let half_height_1 = Double(max_1_y - min_1_y)/2
    
    let half_width_2 = Double(max_2_x - min_2_x)/2
    let half_height_2 = Double(max_2_y - min_2_y)/2

    let center_1_x = Double(min_1_x) + half_width_1
    let center_1_y = Double(min_1_y) + half_height_1

    let center_2_x = Double(min_2_x) + half_width_2
    let center_2_y = Double(min_2_y) + half_height_2

    let width = abs(center_1_x - center_2_x)
    let height = abs(center_1_y - center_2_y)

    return sqrt(width*width + height*height)
}
*/
func center_theta(from box_1: BoundingBox, to box_2: BoundingBox) -> Double {
    //Log.d("center_theta(box_1.min.x: \(box_1.min.x), box_1.min.y: \(box_1.min.y), box_1.max.x: \(box_1.max.x), box_1.max.y: \(box_1.max.y), min_2_x: \(min_2_x), min_2_y: \(min_2_y), max_2_x: \(max_2_x), box_2.max.y: \(box_2.max.y)")
    let half_width_1 = Double(box_1.max.x - box_1.min.x)/2
    let half_height_1 = Double(box_1.max.y - box_1.min.y)/2

    //Log.d("1 half size [\(half_width_1), \(half_height_1)]")
    
    let half_width_2 = Double(box_2.max.x - box_2.min.x)/2
    let half_height_2 = Double(box_2.max.y - box_2.min.y)/2
    
    //Log.d("2 half size [\(half_width_2), \(half_height_2)]")

    let center_1_x = Double(box_1.min.x) + half_width_1
    let center_1_y = Double(box_1.min.y) + half_height_1

    //Log.d("1 center [\(center_1_x), \(center_1_y)]")
    
    let center_2_x = Double(box_2.min.x) + half_width_2
    let center_2_y = Double(box_2.min.y) + half_height_2
    

    //Log.d("2 center [\(center_2_x), \(center_2_y)]")

    if center_1_y == center_2_y {
        // special case horizontal alignment, theta 0 degrees
        return 0
    }

    if center_1_x == center_2_x {
        // special case vertical alignment, theta 90 degrees
        return 90
    }

    var theta: Double = 0 //atan(Double(abs(center_1_x - center_2_x))/Double(abs(center_1_y - center_2_y)))


    let width = Double(abs(center_1_x - center_2_x))
    let height = Double(abs(center_1_y - center_2_y))

    let ninety_degrees_in_radians = 90 * Double.pi/180
    
    if center_1_x < center_2_x {
        if center_1_y < center_2_y {
            // 90 + case
            theta = ninety_degrees_in_radians + atan(height/width)
        } else { // center_1_y > center_2_y
            // 0 - 90 case
            theta = atan(width/height)
        }
    } else { // center_1_x > center_2_x
        if center_1_y < center_2_y {
            // 0 - 90 case
            theta = atan(width/height)
        } else { // center_1_y > center_2_y
            // 90 + case
            theta = ninety_degrees_in_radians + atan(height/width)
        }
    }

    // XXX what about rho?
    let theta_degrees = theta*180/Double.pi
    //Log.d("theta_degrees \(theta_degrees)")
    return  theta_degrees // convert from radians to degrees
}

// how many pixels actually overlap between the groups ?  returns 0-1 value of overlap amount
@available(macOS 10.15, *)
func pixel_overlap(box_1: BoundingBox,
                   group_1_name: String,
                   group_1_frame: FrameAirplaneRemover,
                   box_2: BoundingBox,
                   group_2_name: String,
                   group_2_frame: FrameAirplaneRemover) async -> Double // 1 means total overlap, 0 means none
{
    // throw out non-overlapping frames, do any slip through?
    if box_1.min.x > box_2.max.x || box_1.min.y > box_2.max.y { return 0 }
    if box_2.min.x > box_1.max.x || box_2.min.y > box_1.max.y { return 0 }

    var min_x = box_1.min.x
    var min_y = box_1.min.y
    var max_x = box_1.max.x
    var max_y = box_1.max.y
    
    if box_2.min.x < min_x { min_x = box_2.min.x }
    if box_2.min.y < min_y { min_y = box_2.min.y }
    
    if box_2.max.x > max_x { max_x = box_2.max.x }
    if box_2.max.y > max_y { max_y = box_2.max.y }
    
    // XXX could search a smaller space probably

    var overlap_pixel_amount = 0;
    
    let outlier_groups_1 = await group_1_frame.outlier_groups
    let outlier_groups_2 = await group_2_frame.outlier_groups
    let width = group_1_frame.width // they better be the same :)
    for x in min_x ... max_x {
        for y in min_y ... max_y {
            let index = y * width + x
            if let pixel_1_group = outlier_groups_1[index],
               let pixel_2_group = outlier_groups_2[index],
               pixel_1_group == group_1_name,
               pixel_2_group == group_2_name
            {
                overlap_pixel_amount += 1
            }
        }
    }

    if overlap_pixel_amount > 0 {
        if let group_1_size = await group_1_frame.neighbor_groups[group_1_name],
           let group_2_size = await group_2_frame.neighbor_groups[group_2_name]
        {
            let avg_group_size = (Double(group_1_size) + Double(group_2_size)) / 2
            return Double(overlap_pixel_amount)/avg_group_size
        } else {
            fatalError("should have sizes, WTF?")
        }
    }
    
    return 0
}

 // positive if they don't overlap, negative if they do
func edge_distance(from box_1: BoundingBox, to box_2: BoundingBox) -> Double {

    let half_width_1 = Double(box_1.max.x - box_1.min.x)/2
    let half_height_1 = Double(box_1.max.y - box_1.min.y)/2

    //Log.d("1 half size [\(half_width_1), \(half_height_1)]")
    
    let half_width_2 = Double(box_2.max.x - box_2.min.x)/2
    let half_height_2 = Double(box_2.max.y - box_2.min.y)/2
    
    //Log.d("2 half size [\(half_width_2), \(half_height_2)]")

    let center_1_x = Double(box_1.min.x) + half_width_1
    let center_1_y = Double(box_1.min.y) + half_height_1

    //Log.d("1 center [\(center_1_x), \(center_1_y)]")
    
    let center_2_x = Double(box_2.min.x) + half_width_2
    let center_2_y = Double(box_2.min.y) + half_height_2
    

    //Log.d("2 center [\(center_2_x), \(center_2_y)]")

    if center_1_y == center_2_y {
        // special case horizontal alignment
        // return the distance between their centers minus half of each of their widths
        return Double(abs(center_1_x - center_2_x) - half_width_1 - half_width_2)
    }

    if center_1_x == center_2_x {
        // special case vertical alignment
        // return the distance between their centers minus half of each of their heights
        return Double(abs(center_1_y - center_2_y) - half_height_1 - half_height_2)
    }

    // calculate slope and y intercept for the line between the center points
    // y = slope * x + y_intercept
    let slope = Double(center_1_y - center_2_y)/Double(center_1_x - center_2_x)

    // base the y_intercept on the center 1 coordinates
    let y_intercept = Double(center_1_y) - slope * Double(center_1_x)

    //Log.d("slope \(slope) y_intercept \(y_intercept)")
    

    var theta: Double = 0

    // width between center points
    let width = Double(abs(center_1_x - center_2_x))

    // height between center points
    let height = Double(abs(center_1_y - center_2_y))

    let ninety_degrees_in_radians = 90 * Double.pi/180

    if center_1_x < center_2_x {
        if center_1_y < center_2_y {
            // 90 + case
            theta = ninety_degrees_in_radians + atan(height/width)
        } else { // center_1_y > center_2_y
            // 0 - 90 case
            theta = atan(width/height)
        }
    } else { // center_1_x > center_2_x
        if center_1_y < center_2_y {
            // 0 - 90 case
            theta = atan(width/height)
        } else { // center_1_y > center_2_y
            // 90 + case
            theta = ninety_degrees_in_radians + atan(height/width)
        }
    }

    //Log.d("theta \(theta*180/Double.pi) degrees")
    
    // the distance along the line between the center points that lies within group 1
    let dist_1 = distance_on(box: box_1, slope: slope, y_intercept: y_intercept, theta: theta)
    //Log.d("dist_1 \(dist_1)")
    
    // the distance along the line between the center points that lies within group 2
    let dist_2 = distance_on(box: box_2, slope: slope, y_intercept: y_intercept, theta: theta)

    //Log.d("dist_2 \(dist_2)")

    // the direct distance bewteen the two centers
    let center_distance = sqrt(width * width + height * height)

    //Log.d("center_distance \(center_distance)")
    
    // return the distance between their centers minus the amount of the line which is within each group
    // will be positive if the distance is separation
    // will be negative if they overlap
    let ret = center_distance - dist_1 - dist_2
    //Log.d("returning \(ret)")
    return ret
}

