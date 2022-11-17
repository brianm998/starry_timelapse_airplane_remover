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
@available(macOS 10.15, *)
var airplane_streaks: [String:[AirplaneStreakMember]] = [:]

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
                Log.d("adding frame \(frame.frame_index) to final queue")
                await self.final_queue.method_list.add(atIndex: frame.frame_index) {
                    await frame.finish()
                }
            }
        }
        let method_list_count = await self.final_queue.method_list.count
        Log.d("add all \(count) remaining frames to method list of count \(method_list_count)")
    }

    nonisolated func run(shouldProcess: [Bool]) async {

        Task {
            await final_queue.start()
        }
        let frame_count = await frames.count
        
        var done = false
        while(!done) {
            Log.d("FINAL THREAD running")
            let (cfi, frames_count) = await (current_frame_index, frames.count)
            done = cfi >= frames_count
            Log.d("FINAL THREAD done \(done) current_frame_index \(cfi) frames.count \(frames_count)")
            if done {
                Log.d("we are done")
                continue
            }
            
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
                    Log.d("FINAL THREAD bad")
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
                        // identify all existing streaks with length of only 2
                        // try to find other nearby streaks, if not found,
                        //then skip for new not paint reason
                        
                        await really_final_streak_processing(onFrame: frame_to_finish,
                                                             nextFrame: next_frame)
                        
                        let final_frame_group_name = "final frame \(frame_to_finish.frame_index)"
                        await self.dispatch_group.enter(final_frame_group_name)
                        Task {
                            Log.d("frame \(frame_to_finish.frame_index) adding at index ")
                            let before_count = await self.final_queue.method_list.count
                            await self.final_queue.add(atIndex: frame_to_finish.frame_index) {
                                Log.i("frame \(frame_to_finish.frame_index) finishing")
                                await frame_to_finish.finish()
                                Log.i("frame \(frame_to_finish.frame_index) finished")
                            }
                            let after_count = await self.final_queue.method_list.count
                            Log.d("frame \(frame_to_finish.frame_index) done adding to index before_count \(before_count) after_count \(after_count)")
                            await self.clearFrame(at: immutable_start - 1)
                            await self.dispatch_group.leave(final_frame_group_name)
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

                        let move_me_theta_diff: Double = 10      // XXX move me
                        
                        if first_member.frame_index == last_other_airplane_streak.frame_index + 1 {
                            // found a streak that ended right before this one started
                            
                            let distance = await distance(from: last_other_airplane_streak.group,
                                                          to: first_member.group)

                            let theta_diff = await abs(last_other_airplane_streak.group.line.theta -
                                                         first_member.group.line.theta)
                            
                            let hypo_avg = (first_member.group.bounds.hypotenuse +
                                              last_other_airplane_streak.group.bounds.hypotenuse)/2

                            let move_me_distance_limit = hypo_avg + 2 // XXX contstant
                            
                            if distance < move_me_distance_limit && theta_diff < move_me_theta_diff {
                                remove_small_streak = false
                            }
                            
                        } else if last_member.frame_index + 1 == first_other_airplane_streak.frame_index {
                            // found a streak that starts right after this one ends
                            let distance = await distance(from: last_member.group,
                                                          to: first_other_airplane_streak.group)

                            let theta_diff = await abs(first_other_airplane_streak.group.line.theta -
                                                         last_member.group.line.theta)

                            let hypo_avg = (last_member.group.bounds.hypotenuse +
                                              first_other_airplane_streak.group.bounds.hypotenuse)/2

                            let move_me_distance_limit =  hypo_avg + 2 // XXX contstant

                            if distance < move_me_distance_limit && theta_diff < move_me_theta_diff {
                                remove_small_streak = false
                            }
                        }
                    }
                }
                
                if remove_small_streak {

                    var total_line_score: Double = 0
                    // one last check on the line score
                    for member_to_remove in airplane_streak {
                        total_line_score += await member_to_remove.group.paintScore(from: .houghTransform)
                    }
                    total_line_score /= Double(airplane_streak.count)

                    // only get rid of small streaks if they don't look like lines
                    if total_line_score < 0.2 { // XXX constant
                        
                        airplane_streaks.removeValue(forKey: streak_name) // XXX mutating while iterating?
                        
                        for member_to_remove in airplane_streak {
                            // change should_paint to new value for the frame
                            if member_to_remove.frame_index < frame.frame_index {
                                Log.e("frame \(member_to_remove.frame_index) is already finalized, modifying it now won't change anythig :(")
                                fatalError("FUCK")
                            }
                            // here 'removing' means 'de-streakifying' it
                            // it may or may not still be painted, but now it's not based upon other groups 
                            await member_to_remove.group.setShouldPaintFromCombinedScore()
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
    await run_final_streak_pass(frames: frames) // XXX not actually the final streak pass anymore..
}


@available(macOS 10.15, *)
fileprivate func run_final_overlap_pass(frames: [FrameAirplaneRemover]) async {
    for frame in frames {
        await frame.foreachOutlierGroup { group in
            // look for more data to act upon

            let houghScore = await group.paintScore(from: .houghTransform)

            if houghScore > medium_hough_line_score { return .continue }
            
            if let reason = await group.shouldPaint,
               reason.willPaint
            {
                switch reason {
                case .looksLikeALine(let amount):
                    Log.i("frame \(frame.frame_index) skipping \(group) because of \(reason)") 
                    return .continue // continue
                case .inStreak(let size):
                    if size > 2 {
                        //Log.i("frame \(frame.frame_index) skipping \(group_name) because of \(reason)") 
                        // XXX this skips streaks that it shouldn't
                    }
                default:
                    break
                }
            }
            
            let line_theta = await group.line.theta
            let line_rho = await group.line.rho

            if let group = await frame.outlierGroup(named: group.name) {
                for other_frame in frames {
                    if other_frame == frame { continue }

                    await other_frame.foreachOutlierGroup() { og in
                        let other_line_theta = await og.line.theta
                        let other_line_rho = await og.line.rho
                        
                        let theta_diff = abs(line_theta-other_line_theta)
                        let rho_diff = abs(line_rho-other_line_rho)
                        if (theta_diff < final_theta_diff || abs(theta_diff - 180) < final_theta_diff) &&
                             rho_diff < final_rho_diff
                        {
                            
                            let pixel_overlap_amount =
                              await pixel_overlap(group_1: group,
                                                  group_1_frame: frame,
                                                  group_2: og,
                                                  group_2_frame: other_frame)
                            
                            
                            //Log.d("frame \(frame.frame_index) \(group_name) \(og) pixel_overlap_amount \(pixel_overlap_amount)")
                            
                            if pixel_overlap_amount > 0.05 { // XXX hardcoded constant
                                
                                var do_it = true
                                
                                // do paint over objects that look like lines
                                if let frame_reason = await group.shouldPaint
                                {
                                    if frame_reason.willPaint && frame_reason == .looksLikeALine(0) {
                                        do_it = false
                                    }
                                }
                                
                                if let other_reason = await og.shouldPaint
                                {
                                    if other_reason.willPaint && other_reason == .looksLikeALine(0) {
                                        do_it = false
                                    }
                                }
                                
                                if do_it {
                                    // two overlapping groups
                                    // shouldn't be painted over
                                //    let _ = await (
                                    await group.shouldPaint(.adjecentOverlap(pixel_overlap_amount))
                                    //                                      frame.setShouldPaint(group: group_name,
                                    //                                                         why: ),
                                    await og.shouldPaint(.adjecentOverlap(pixel_overlap_amount))
                                    //                                      other_frame.setShouldPaint(group: og.name,
                                    //                                                                 why: .adjecentOverlap(pixel_overlap_amount)))
                                    
                                    //Log.d("frame \(frame.frame_index) should_paint[\(group_name)] = (false, .adjecentOverlap(\(pixel_overlap_amount))")
                                    //Log.d("frame \(other_frame.frame_index) should_paint[\(og)] = (false, .adjecentOverlap(\(pixel_overlap_amount))")
                                } else {
                                    //Log.d("frame \(frame.frame_index) \(group_name) left untouched because of pixel overlap amount \(pixel_overlap_amount)")
                                    //Log.d("frame \(other_frame.frame_index) \(og) left untouched because of pixel overlap amount \(pixel_overlap_amount)")
                                }
                            }
                        }
                        return .continue
                    }
                }
            }
            return .continue
        }
    }
}


// looks for airplane streaks across frames
@available(macOS 10.15, *)
fileprivate func run_final_streak_pass(frames: [FrameAirplaneRemover]) async {

    let initial_frame_index = frames[0].frame_index
    
    for (batch_index, frame) in frames.enumerated() {
        let frame_index = frame.frame_index
        Log.d("frame_index \(frame_index)")
        if batch_index + 1 == frames.count { continue } // the last frame can be ignored here

        await frame.foreachOutlierGroup() { group in
            // look for more data to act upon
            
            if let reason = await group.shouldPaint {
                if reason == .adjecentOverlap(0) {
                    Log.d("frame \(frame.frame_index) skipping \(group) because it has .adjecentOverlap")
                    return .continue
                }
                
                // grab a streak that we might already be in
                
                var existing_streak: [AirplaneStreakMember]?
                var existing_streak_name: String?
                
                for (streak_name, airplane_streak) in airplane_streaks {
                    if let _ = existing_streak { continue }
                    for streak_member in airplane_streak {
                        if frame_index == streak_member.frame_index &&
                             group.name == streak_member.group.name
                        {
                            existing_streak = airplane_streak
                            existing_streak_name = streak_name
                            Log.i("frame \(frame.frame_index) using existing streak for \(group)")
                            continue
                        }
                    }
                }
                
                
                Log.d("frame \(frame_index) looking for streak for \(group)")
                // search neighboring frames looking for potential tracks
                
                // see if this group is already part of a streak, and pass that in
                
                // if not, pass in the starting potential one frame streak
                
                var potential_streak: [AirplaneStreakMember] = [(frame_index, group, nil)]
                var potential_streak_name = "\(frame_index).\(group.name)"
                
                if let existing_streak = existing_streak,
                   let existing_streak_name = existing_streak_name
                {
                    potential_streak = existing_streak
                    potential_streak_name = existing_streak_name
                }

                let houghScore = await group.paintScore(from: .houghTransform)

                if houghScore > 0.007 { // XXX constant
                    if let streak = 
                         await streak_from(group: group, // XXX really start from ends of existing streak, not group, which could be in the middle
                                           frames: frames,
                                           startingIndex: batch_index+1,
                                           potentialStreak: &potential_streak)
                    {
                        Log.i("frame \(frame_index) found streak \(potential_streak_name) of size \(streak.count) for \(group)")
                        airplane_streaks[potential_streak_name] = streak
                    } else {
                        Log.d("frame \(frame_index) DID NOT find streak for \(group)")
                    }
                } else {
                    Log.d("frame \(frame_index) not starting streak for \(group) because of low hough score \(houghScore)")
                }
            }
            return .continue
        }
    }

    // go through and mark all of airplane_streaks to paint
    Log.d("analyzing \(airplane_streaks.count) streaks")
    for (streak_name, airplane_streak) in airplane_streaks {
        let first_member = airplane_streak[0]
        Log.d("analyzing streak \(streak_name) starting with group \(first_member.group) frame_index \(first_member.frame_index) with \(airplane_streak.count) members")
        // XXX perhaps reject small streaks?
        if airplane_streak.count < 3 {
            Log.d("ignoring two member streak \(airplane_streak)")
            continue
        } 
        var verbotten = false
        var was_already_paintable = false
        //let index_of_first_streak = airplane_streak[0].frame_index
        for streak_member in airplane_streak {
            if streak_member.frame_index - initial_frame_index < 0 ||
               streak_member.frame_index - initial_frame_index >= frames.count {
                // these are frames that are part of the streak, but not part of the batch
                // being processed right now,
            } else {
                //let frame = frames[streak_member.frame_index - initial_frame_index]
                if let should_paint = await streak_member.group.shouldPaint{
                    if should_paint == .adjecentOverlap(0) { verbotten = true }
                    //                if should_paint.willPaint { was_already_paintable = true }
                }
            }
        }
        if verbotten/* || !was_already_paintable*/ { continue }
        Log.d("painting over airplane streak \(airplane_streak)")
        for streak_member in airplane_streak {
            if streak_member.frame_index - initial_frame_index < 0 ||
               streak_member.frame_index - initial_frame_index >= frames.count {
                // these are frames that are part of the streak, but not part of the batch
                // being processed right now,
            } else {
                //let frame = frames[streak_member.frame_index - initial_frame_index]
                Log.d("frame \(streak_member.frame_index) will paint group \(streak_member.group) is .inStreak")

                // XXX check to see if this is already .inStreak with higher count
                await streak_member.group.shouldPaint(.inStreak(airplane_streak.count))
                //await frame.setShouldPaint(group: streak_member.group.name, why: )
            }
        }
    }
}


@available(macOS 10.15, *)
func streak_from(streak: inout [AirplaneStreakMember],
                 frames: [FrameAirplaneRemover],
                 startingIndex starting_index: Int)
  async -> [AirplaneStreakMember]?
{
    if streak.count == 1 {
        return await streak_from(group: streak[0].group,
                                 frames: frames,
                                 startingIndex: starting_index,
                                 potentialStreak: &streak)
    } else {
        if let new_streak = await streak_from(group: streak[0].group,
                                              frames: frames,
                                              startingIndex: starting_index,
                                              potentialStreak: &streak)
        {
            return new_streak
        } else if let last_streak_member = streak.last,
                  let new_streak = await streak_from(group: last_streak_member.group,
                                                     frames: frames,
                                                     startingIndex: starting_index,
                                                     potentialStreak: &streak)
        {
            return new_streak
        }
        return nil
    }
}


// see if there is a streak of airplane tracks starting from the given group
// a 'streak' is a set of outliers with simlar theta and rho, that are
// close enough to eachother, and that are moving in close enough to the same
// direction as the lines that describe them.
@available(macOS 10.15, *)
func streak_from(group: OutlierGroup,
                 frames: [FrameAirplaneRemover],
                 startingIndex starting_index: Int,
                 potentialStreak potential_streak: inout [AirplaneStreakMember])
  async -> [AirplaneStreakMember]?
{

    Log.d("trying to find streak starting at \(group)")
    
    // the bounding box of the last element of the streak

    var last_group = group

    // the best match found so far for a possible streak etension
    var best_group = group
    var best_frame_index = 0
    
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

        let last_hypo = last_group.bounds.hypotenuse
        // calculate min distance from hypotenuse of last bounding box
        let min_distance: Double = last_hypo * 1.3 // XXX hardcoded constant
        
        var best_distance = min_distance
        //Log.d("looking at frame \(frame.frame_index)")

        await frame.foreachOutlierGroup() { other_group in
            // XXX not sure this value is right
            // really we want the distance between the nearest pixels of each group
            // this isn't close enough for real

            let distance = await distance(from: last_group, to: other_group)

            let center_line_theta = center_theta(from: last_group.bounds, to: other_group.bounds)

            let (other_group_line_theta,
                 last_group_line_theta) = await (other_group.line.theta,
                                                 last_group.line.theta)
            
            let (theta_diff, rho_diff) = await (abs(last_group.line.theta-other_group_line_theta),
                                                abs(last_group.line.rho-other_group.line.rho))

            let center_line_theta_diff_1 = abs(center_line_theta-other_group_line_theta)
            let center_line_theta_diff_2 = abs(center_line_theta-last_group_line_theta)

            let houghScore = await other_group.paintScore(from: .houghTransform)

            // XXX constant  VVV 
            if houghScore > 0.007 /*medium_hough_line_score*/ &&
                 distance < best_distance &&
                 (theta_diff < final_theta_diff || abs(theta_diff - 180) < final_theta_diff) &&
                 ((center_line_theta_diff_1 < center_line_theta_diff ||
                     abs(center_line_theta_diff_1 - 180) < center_line_theta_diff) || // && ??
                    (center_line_theta_diff_2 < center_line_theta_diff ||
                       abs(center_line_theta_diff_2 - 180) < center_line_theta_diff)) &&
                 rho_diff < final_rho_diff
            {
                Log.d("frame \(frame.frame_index) \(other_group) is \(distance) away from \(last_group) other_group_line_theta \(other_group_line_theta) last_group_line_theta \(last_group_line_theta) center_line_theta \(center_line_theta)")
                best_group = other_group
                best_distance = distance
                best_frame_index = frame_index // XXX this WAS wrong
            } else {
                //Log.d("frame \(frame.frame_index) \(other_group) doesn't match \(group) houghScore \(houghScore) medium_hough_line_score \(medium_hough_line_score) distance \(distance) best_distance \(best_distance) theta_diff \(theta_diff) rho_diff \(rho_diff) center_line_theta_diff_1 \(center_line_theta_diff_1) center_line_theta_diff_2 \(center_line_theta_diff_2) center_line_theta \(center_line_theta) last \(last_group_line_theta) other \(other_group_line_theta)")
            }
            return .continue
        }
        if best_distance == min_distance {
            break               // no more streak
        } else {
            if best_frame_index == frame.frame_index {
                if let last_streak_item = potential_streak.last,//[potential_streak.count-1] {
                   best_frame_index > last_streak_item.frame_index
                {
                    // streak on (maybe)
                    var do_it = true
                    
                    // check here to make sure the distance between best_group
                    // and the potentel_streak - 2 are in line
                    if potential_streak.count > 1 {
                        let prev_index = potential_streak.count - 1
                        let member_one_back = potential_streak[prev_index]
                        let member_two_back = potential_streak[prev_index-1]

                        if let member_one_back_distance = member_one_back.distance {
                            let distance_two_back = await distance(from: best_group, to: member_two_back.group)
                            if distance_two_back < member_one_back_distance {
                                // this new potential member is actually closer to the member two back
                                // than the one in the middle. skip it.
                                Log.d("not adding \(best_group) to streak because it's not going in the right direction")
                                do_it = false
                            }
                        }

                        // also check if the center line theta between the three points are close enough
                        // i.e. the center line theta should not be too far off between this new group
                        // and the ones before it

                        let center_theta_one_back = center_theta(from: best_group.bounds,
                                                                 to: member_one_back.group.bounds)
                        let center_theta_two_back = center_theta(from: best_group.bounds,
                                                                 to: member_two_back.group.bounds)

                        if(abs(center_theta_one_back - center_theta_two_back) > 20) {// XXX constant (could be larger?)
                            Log.d("not adding \(best_group) to streak because \(center_theta_one_back) - \(center_theta_two_back) > 20")
                            do_it = false
                        }
                    }

                    if do_it {
                        // set previous last group here for comparison later
                        last_group = best_group
                        
                        Log.d("frame \(frame.frame_index) adding group \(best_group) to streak best_distance \(best_distance)")
                        potential_streak.append((best_frame_index, best_group, best_distance))
                    }
                }
            } else {
                break           // no more streak
            }
        }
    }
    if potential_streak.count == 1 {
        return nil              // nothing added
    } else {
        Log.d("returning potential_streak \(potential_streak)")
        return potential_streak
    }
}



// theta in degrees of the line between the centers of the two bounding boxes
func center_theta(from box_1: BoundingBox, to box_2: BoundingBox) -> Double {
    //Log.d("center_theta(box_1.min.x: \(box_1.min.x), box_1.min.y: \(box_1.min.y), box_1.max.x: \(box_1.max.x), box_1.max.y: \(box_1.max.y), min_2_x: \(min_2_x), min_2_y: \(min_2_y), max_2_x: \(max_2_x), box_2.max.y: \(box_2.max.y)")

    //Log.d("2 half size [\(half_width_2), \(half_height_2)]")

    let center_1_x = Double(box_1.min.x) + Double(box_1.width)/2
    let center_1_y = Double(box_1.min.y) + Double(box_1.height)/2

    //Log.d("1 center [\(center_1_x), \(center_1_y)]")
    
    let center_2_x = Double(box_2.min.x) + Double(box_2.width)/2
    let center_2_y = Double(box_2.min.y) + Double(box_2.height)/2
    
    //Log.d("2 center [\(center_2_x), \(center_2_y)]")

    // special case horizontal alignment, theta 0 degrees
    if center_1_y == center_2_y { return 0 }

    // special case vertical alignment, theta 90 degrees
    if center_1_x == center_2_x { return 90 }

    var theta: Double = 0

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
    let theta_degrees = theta*180/Double.pi // convert from radians to degrees
    //Log.d("theta_degrees \(theta_degrees)")
    return  theta_degrees
}

// how many pixels actually overlap between the groups ?  returns 0-1 value of overlap amount
@available(macOS 10.15, *)
func pixel_overlap(group_1: OutlierGroup,
                   group_1_frame: FrameAirplaneRemover,
                   group_2: OutlierGroup,
                   group_2_frame: FrameAirplaneRemover) async -> Double // 1 means total overlap, 0 means none
{
    // throw out non-overlapping frames, do any slip through?
    if group_1.bounds.min.x > group_2.bounds.max.x || group_1.bounds.min.y > group_2.bounds.max.y { return 0 }
    if group_2.bounds.min.x > group_1.bounds.max.x || group_2.bounds.min.y > group_1.bounds.max.y { return 0 }

    var min_x = group_1.bounds.min.x
    var min_y = group_1.bounds.min.y
    var max_x = group_1.bounds.max.x
    var max_y = group_1.bounds.max.y
    
    if group_2.bounds.min.x < min_x { min_x = group_2.bounds.min.x }
    if group_2.bounds.min.y < min_y { min_y = group_2.bounds.min.y }
    
    if group_2.bounds.max.x > max_x { max_x = group_2.bounds.max.x }
    if group_2.bounds.max.y > max_y { max_y = group_2.bounds.max.y }
    
    // XXX could search a smaller space probably

    var overlap_pixel_amount = 0;
    
    let outlier_groups_1 = await group_1_frame.outlier_group_list
    let outlier_groups_2 = await group_2_frame.outlier_group_list
    let width = group_1_frame.width // they better be the same :)
    for x in min_x ... max_x {
        for y in min_y ... max_y {
            let index = y * width + x
            if let pixel_1_group = outlier_groups_1[index],
               let pixel_2_group = outlier_groups_2[index],
               pixel_1_group == group_1.name,
               pixel_2_group == group_2.name
            {
                overlap_pixel_amount += 1
            }
        }
    }

    if overlap_pixel_amount > 0 {
        let avg_group_size = (Double(group_1.size) + Double(group_2.size)) / 2
        return Double(overlap_pixel_amount)/avg_group_size
    }
    
    return 0
}

@available(macOS 10.15, *) 
func distance(from group1: OutlierGroup, to group2: OutlierGroup) async -> Double {

    return edge_distance(from: group1.bounds, to: group2.bounds)
/*

    let group1_hypo = group1.bounds.hypotenuse
    let group2_hypo = group2.bounds.hypotenuse

    let center_distance = group1.bounds.centerDistance(to: group2.bounds)
    if(center_distance > group1_hypo/2 + group2_hypo/2) {
        // this is a rough approximation based upon the bounding boxes
        return center_distance - (group1_hypo/2) - (group2_hypo/2)
    } else {
        // this is a real pixel distance, but takes a LONG longer
        // so try to avoid it until they are closer and the accuracy matters
        return await group1.pixelDistance(to: group2)
    }
*/
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
        let half_width = Double(bounding_box.width)/2
        //Log.d("vertical half_width \(half_width)")
        hypotenuse_length = half_width / cos((90/180*Double.pi)-theta)
        
    case .horizontal:
        let half_height = Double(bounding_box.height)/2
        //Log.d("horizontal half_height \(half_height)")
        hypotenuse_length = half_height / cos(theta)
    }
    
    return hypotenuse_length
}
// positive if they don't overlap, negative if they do
func edge_distance(from box_1: BoundingBox, to box_2: BoundingBox) -> Double {
    
    let half_width_1 = Double(box_1.width)/2
    let half_height_1 = Double(box_1.height)/2
    
    //Log.d("1 half size [\(half_width_1), \(half_height_1)]")
    
    let half_width_2 = Double(box_2.width)/2
    let half_height_2 = Double(box_2.height)/2
    
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
