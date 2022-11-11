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
            var index_in_images_to_process_of_main_frame = 0
            var index_in_images_to_process = 0
            for i in start_index ... end_index {
                if let next_frame = await self.frame(at: i) {
                    images_to_process.append(next_frame)
                    if i == index_to_process {
                        index_in_images_to_process_of_main_frame = index_in_images_to_process
                    }
                    index_in_images_to_process += 1
                } else {
                    bad = true
                    // XXX bad
                    //Log.d("FINAL THREAD bad")
                }
            }
            if !bad {
                Log.i("FINAL THREAD frame \(index_to_process) doing inter-frame analysis with \(images_to_process.count) frames")
                await run_final_pass(frames: images_to_process,
                                     mainIndex: index_in_images_to_process_of_main_frame)
                Log.d("FINAL THREAD frame \(index_to_process) done with inter-frame analysis")
                await self.incrementCurrentFrameIndex()
                if start_index > 0 && index_to_process < frame_count - number_final_processing_neighbors_needed - 1 {
                    // maybe finish a previous frame
                    // leave the ones at the end to finishAll()
                    let immutable_start = start_index
                    //Log.d("FINAL THREAD frame \(index_to_process) queueing into final queue")
                    if let frame_to_finish = await self.frame(at: immutable_start - 1) {
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

// this method does a final pass on a group of frames, using
// the angle of outlier groups that don't overlap between frames
// to add a layer of airplane detection.
// if two outlier groups are found in different frames, with close
// to the same theta and rho, and they don't overlap, then they are
// likely adject airplane tracks.
// otherwise, if they do overlap, then it's more likely a cloud or 
// a bright star or planet, leave them as is.  
@available(macOS 10.15, *)
fileprivate func run_final_pass(frames: [FrameAirplaneRemover], mainIndex main_index: Int) async {
    Log.d("final pass on \(frames.count) frames")
    for frame in frames {
        //Log.d("frame.group_lines.count \(frame.group_lines.count)")
        for (group_name, group_line) in await frame.group_lines {
            // look for more data to act upon

            if let reason = await frame.should_paint[group_name],
               reason.willPaint && reason == .looksLikeALine
            {
                Log.i("frame \(frame.frame_index) skipping group \(group_name) because it .looksLikeALine") // XXX would be nice to have more data in this log line
                continue
            }
            
            let line_theta = group_line.theta
            let line_rho = group_line.rho

            if let line_min_x = await frame.group_min_x[group_name],
               let line_min_y = await frame.group_min_y[group_name],
               let line_max_x = await frame.group_max_x[group_name],
               let line_max_y = await frame.group_max_y[group_name]/*,
               let group_size = await frame.neighbor_groups[group_name]*/
            {
                for other_frame in frames {
                    if other_frame == frame { continue }
                    //Log.d("other frame.group_lines.count \(other_frame.group_lines.count)")

                    for (og_name, og_line) in await other_frame.group_lines {
                        let other_line_theta = og_line.theta
                        let other_line_rho = og_line.rho

                        let theta_diff = abs(line_theta-other_line_theta)
                        let rho_diff = abs(line_rho-other_line_rho)
                        //Log.d("overlap_amount \(overlap_amount) amt \(amt)")
                        if (theta_diff < final_theta_diff || abs(theta_diff - 180) < final_theta_diff) &&
                            rho_diff < final_rho_diff
                        {
                            if let other_line_min_x = await other_frame.group_min_x[og_name],
                               let other_line_min_y = await other_frame.group_min_y[og_name],
                               let other_line_max_x = await other_frame.group_max_x[og_name],
                               let other_line_max_y = await other_frame.group_max_y[og_name]/*,
                               let other_group_size = await other_frame.neighbor_groups[og_name]*/
                            {

                                //Log.d("frame \(frame.frame_index) group 1 \(group_name) of size \(group_size) (\(line_min_x) \(line_min_y)),  (\(line_max_x) \(line_max_y)) other frame \(other_frame.frame_index) group 2 \(og_name) of size \(group_size) (\(other_line_min_x) \(other_line_min_y)),  (\(other_line_max_x) \(other_line_max_y))")

                                let mult = abs(frame.frame_index - other_frame.frame_index)
                                // multiply the constant by how far the frames are away
                                // from eachother in the sequence
                                var edge_amt = Double(final_group_boundary_amt * mult)
                                let center_amt = Double(final_group_boundary_amt*final_center_distance_multiplier * mult)
                                if mult == 1 {
                                    // directly adjecent frames
                                    // -2 isn't enough
                                    edge_amt = final_adjecent_edge_amount // may not need this?
                                    // XXX maybe only if they are in alignment?
                                }

                                // XXX include both distance between edges as below,
                                // and also add distance between centers.
                                // if the center hardly moves, then reject
                                
                                // the amount of the line between their center points that
                                // is not covered by either one of them
                                // this is negative when they overlap
                                let distance_bewteen_groups =
                                    edge_distance(min_1_x: line_min_x,
                                                  min_1_y: line_min_y,
                                                  max_1_x: line_max_x,
                                                  max_1_y: line_max_y,
                                                  min_2_x: other_line_min_x,
                                                  min_2_y: other_line_min_y,
                                                  max_2_x: other_line_max_x,
                                                  max_2_y: other_line_max_y)

                                // the length of the line between the center points
                                // of the groups
                                let center_distance_bewteen_groups =
                                    center_distance(min_1_x: line_min_x,
                                                  min_1_y: line_min_y,
                                                  max_1_x: line_max_x,
                                                  max_1_y: line_max_y,
                                                  min_2_x: other_line_min_x,
                                                  min_2_y: other_line_min_y,
                                                  max_2_x: other_line_max_x,
                                                  max_2_y: other_line_max_y)

                                //Log.d("frame \(frame.frame_index) edge_distance_bewteen_groups \(distance_bewteen_groups) center_distance \(center_distance_bewteen_groups) \(group_name) \(og_name) edge_amt \(edge_amt) center_amt \(center_amt)")
                                if distance_bewteen_groups < edge_amt &&
                                   center_distance_bewteen_groups < center_amt
                                {
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
                                                                     why: .adjecentOverlap(-distance_bewteen_groups)),
                                                other_frame.setShouldPaint(group: og_name,
                                                                           why: .adjecentOverlap(-distance_bewteen_groups)))
                                        
                                        //Log.d("frame \(frame.frame_index) should_paint[\(group_name)] = (false, .adjecentOverlap(\(-distance_bewteen_groups))")
                                        //Log.d("frame \(other_frame.frame_index) should_paint[\(og_name)] = (false, .adjecentOverlap(\(-distance_bewteen_groups))")
                                    }
                                } 
                            }
                        }
                    }
                }
            }
        }
    }

    // identify airplane trails
    var airplane_streaks: [[AirplaneStreakMember]] = [] 
    
    for (frame_index, frame) in frames.enumerated() {
        //Log.d("frame.group_lines.count \(frame.group_lines.count)")

        if frame_index + 1 == frames.count { continue } // the last frame can be ignored here

        for (group_name, group_line) in await frame.group_lines {
            // look for more data to act upon

            if let reason = await frame.should_paint[group_name] {
                if reason == .adjecentOverlap(0) {
                    //Log.d("frame \(frame.frame_index) skipping group \(group_name) because it has .adjecentOverlap")
                    continue
                }

                // make sure we're not in a streak already
                for airplane_streak in airplane_streaks {
                    for streak_member in airplane_streak {
                        if frame_index == streak_member.frame_index &&
                             group_name == streak_member.group_name
                        {
                            continue
                        }
                    }
                }

                if let first_min_x = await frame.group_min_x[group_name],
                   let first_min_y = await frame.group_min_y[group_name],
                   let first_max_x = await frame.group_max_x[group_name],
                   let first_max_y = await frame.group_max_y[group_name]
                {
                    //Log.d("frame \(frame_index) looking for streak for group \(group_name)")
                    // search neighboring frames looking for potential tracks
                    if let streak = 
                         await streak_starting_from(groupName: group_name,
                                                    groupLine: group_line,
                                                    min_x: first_min_x,
                                                    min_y: first_min_y,
                                                    max_x: first_max_x,
                                                    max_y: first_max_y,
                                                    frames: frames,
                                                    startingIndex: frame_index+1)
                    {
                        //Log.i("frame \(frame_index) found streak for group \(group_name)")
                        airplane_streaks.append(streak)
                    } else {
                        //Log.d("frame \(frame_index) DID NOT find streak for group \(group_name)")
                    }
                }
            }
        }
    }

    // XXX go through and mark all of airplane_streaks to paint
    //Log.i("analyzing \(airplane_streaks.count) streaks")
    for airplane_streak in airplane_streaks {
        //Log.i("analyzing streak with \(airplane_streak.count) members")
        // XXX perhaps reject small streaks?
        //if airplane_streak.count < 3 { continue } 
        var verbotten = false
        var was_already_paintable = false
        for streak_member in airplane_streak {
            let frame = frames[streak_member.frame_index]
            if let should_paint = await frame.should_paint[streak_member.group_name] {
                if should_paint == .adjecentOverlap(0) { verbotten = true }
                if should_paint.willPaint { was_already_paintable = true }
            }
        }
        if verbotten || !was_already_paintable { continue }
        //Log.i("painting over streak with \(airplane_streak.count) members")
        for streak_member in airplane_streak {
            let frame = frames[streak_member.frame_index]
            //Log.d("frame \(frame.frame_index) will paint group \(streak_member.group_name) is .inStreak")
            await frame.setShouldPaint(group: streak_member.group_name, why: .inStreak)
        }
    }
}

typealias AirplaneStreakMember = (
  frame_index: Int,
  group_name: String,
  line: Line
)

// see if there is a streak of airplane tracks starting from the given group
// a 'streak' is a set of outliers with simlar theta and rho, that are
// close enough to eachother, and that are moving in close enough to the same
// direction as the lines that describe them.
@available(macOS 10.15, *)
func streak_starting_from(groupName group_name: String,
                          groupLine group_line: Line,
                          min_x: Int, min_y: Int, max_x: Int, max_y: Int,
                          frames: [FrameAirplaneRemover],
                          startingIndex starting_index: Int) async -> [AirplaneStreakMember]?
{
    var potential_streak: [AirplaneStreakMember] = [(starting_index-1, group_name, group_line)]

    var last_min_x = min_x
    var last_min_y = min_y
    var last_max_x = max_x
    var last_max_y = max_y
    var last_group_line = group_line

    var best_min_x = min_x
    var best_min_y = min_y
    var best_max_x = max_x
    var best_max_y = max_y
    var best_index = 0
    var best_group_name = group_name
    var best_group_line = group_line
    
    var count = 1

    let min_distance: Double = 100      // XXX constant
/*
    Log.d("streak:")
    for index in starting_index ..< frames.count {
        let frame = frames[index]
        Log.d("streak index \(index) frame \(frame.frame_index)")
    }
  */  
    for index in starting_index ..< frames.count {
        let frame = frames[index]
        count += 1
        var best_distance = min_distance
        //Log.d("looking at frame \(frame.frame_index)")
        for (other_group_name, other_group_line) in await frame.group_lines {
            if let group_min_x = await frame.group_min_x[other_group_name],
               let group_min_y = await frame.group_min_y[other_group_name],
               let group_max_x = await frame.group_max_x[other_group_name],
               let group_max_y = await frame.group_max_y[other_group_name]
            {
                let distance = edge_distance(min_1_x: last_min_x, min_1_y: last_min_y,
                                             max_1_x: last_max_x, max_1_y: last_max_y,
                                             min_2_x: group_min_x, min_2_y: group_min_y,
                                             max_2_x: group_max_x, max_2_y: group_max_y)

                let center_line_theta = center_theta(min_1_x: last_min_x, min_1_y: last_min_y,
                                                     max_1_x: last_max_x, max_1_y: last_max_y,
                                                     min_2_x: group_min_x, min_2_y: group_min_y,
                                                     max_2_x: group_max_x, max_2_y: group_max_y)

                let theta_diff = abs(last_group_line.theta-other_group_line.theta)
                let rho_diff = abs(last_group_line.rho-other_group_line.rho)

                let center_line_theta_diff_1 = abs(center_line_theta-other_group_line.theta)
                let center_line_theta_diff_2 = abs(center_line_theta-last_group_line.theta)

                let center_line_theta_diff = final_theta_diff*2 // XXX hardcoded constant
                
                if distance < best_distance &&
                  (theta_diff < final_theta_diff || abs(theta_diff - 180) < final_theta_diff) &&
                  ((center_line_theta_diff_1 < center_line_theta_diff ||
                     abs(center_line_theta_diff_1 - 180) < center_line_theta_diff) ||
                  (center_line_theta_diff_2 < center_line_theta_diff ||
                     abs(center_line_theta_diff_2 - 180) < center_line_theta_diff)) &&
                   rho_diff < final_rho_diff
                {
                    best_min_x = group_min_x
                    best_min_y = group_min_y
                    best_max_x = group_max_x
                    best_max_y = group_max_y
                    best_group_name = other_group_name
                    best_group_line = other_group_line
                    best_distance = distance
                    best_index = index
                } else {
                    //Log.d("frame \(frame.frame_index) group \(other_group_name) doesn't match group \(group_name) theta_diff \(theta_diff) rho_diff \(rho_diff) center_line_theta_diff_1 \(center_line_theta_diff_1) center_line_theta_diff_2 \(center_line_theta_diff_2) center_line_theta \(center_line_theta) last \(last_group_line.theta) other \(other_group_line.theta)")
                }
            }
        }
        if best_distance == min_distance {
            break               // no more streak
        } else {
            // streak on
            last_min_x = best_min_x
            last_min_y = best_min_y
            last_max_x = best_max_x
            last_max_y = best_max_y
            last_group_line = best_group_line
            potential_streak.append((best_index, best_group_name, best_group_line))
        }
    }
    if potential_streak.count == 1 {
        return nil              // nothing added
    } else {
        return potential_streak
    }
}


enum Edge {
    case vertical
    case horizontal
}

// the distance between the center point of the box described and the exit of the line from it
func distance_on(min_x: Int, min_y: Int, max_x: Int, max_y: Int,
                 slope: Double, y_intercept: Double, theta: Double) -> Double
{
    var edge: Edge = .horizontal
    let y_max_value = Double(max_x)*slope + Double(y_intercept)
    let x_max_value = Double(max_y)-y_intercept/slope
    //let y_min_value = Double(min_x)*slope + Double(y_intercept)
    //let x_min_value = Double(min_y)-y_intercept/slope

    // there is an error introduced by integer to floating point conversions
    let math_accuracy_error: Double = 3
    
    if Double(min_y) - math_accuracy_error <= y_max_value && y_max_value <= Double(max_y) + math_accuracy_error {
        //Log.d("vertical")
        edge = .vertical
    } else if Double(min_x) - math_accuracy_error <= x_max_value && x_max_value <= Double(max_x) + math_accuracy_error {
        //Log.d("horizontal")
        edge = .horizontal
    } else {
        //Log.d("slope \(slope) y_intercept \(y_intercept) theta \(theta)")
        //Log.d("min_x \(min_x) x_max_value \(x_max_value) max_x \(max_x)")
        //Log.d("min_y \(min_y) y_max_value \(y_max_value) max_y \(max_y)")
        //Log.d("min_x \(min_x) x_min_value \(x_min_value) max_x \(max_x)")
        //Log.d("min_y \(min_y) y_min_value \(y_min_value) max_y \(max_y)")
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
        let half_width = Double(max_x - min_x)/2
        //Log.d("vertical half_width \(half_width)")
        hypotenuse_length = half_width / cos((90/180*Double.pi)-theta)
        
    case .horizontal:
        let half_height = Double(max_y - min_y)/2
        //Log.d("horizontal half_height \(half_height)")
        hypotenuse_length = half_height / cos(theta)
    }
    
    return hypotenuse_length
}

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

func center_theta(min_1_x: Int, min_1_y: Int,
                  max_1_x: Int, max_1_y: Int,
                  min_2_x: Int, min_2_y: Int,
                  max_2_x: Int, max_2_y: Int) -> Double
{
    //Log.d("center_theta(min_1_x: \(min_1_x), min_1_y: \(min_1_y), max_1_x: \(max_1_x), max_1_y: \(max_1_y), min_2_x: \(min_2_x), min_2_y: \(min_2_y), max_2_x: \(max_2_x), max_2_y: \(max_2_y)")
    let half_width_1 = Double(max_1_x - min_1_x)/2
    let half_height_1 = Double(max_1_y - min_1_y)/2

    //Log.d("1 half size [\(half_width_1), \(half_height_1)]")
    
    let half_width_2 = Double(max_2_x - min_2_x)/2
    let half_height_2 = Double(max_2_y - min_2_y)/2
    
    //Log.d("2 half size [\(half_width_2), \(half_height_2)]")

    let center_1_x = Double(min_1_x) + half_width_1
    let center_1_y = Double(min_1_y) + half_height_1

    //Log.d("1 center [\(center_1_x), \(center_1_y)]")
    
    let center_2_x = Double(min_2_x) + half_width_2
    let center_2_y = Double(min_2_y) + half_height_2
    

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

func edge_distance(min_1_x: Int, min_1_y: Int,
                   max_1_x: Int, max_1_y: Int,
                   min_2_x: Int, min_2_y: Int,
                   max_2_x: Int, max_2_y: Int)
    -> Double // positive if they don't overlap, negative if they do
{
    let half_width_1 = Double(max_1_x - min_1_x)/2
    let half_height_1 = Double(max_1_y - min_1_y)/2

    //Log.d("1 half size [\(half_width_1), \(half_height_1)]")
    
    let half_width_2 = Double(max_2_x - min_2_x)/2
    let half_height_2 = Double(max_2_y - min_2_y)/2
    
    //Log.d("2 half size [\(half_width_2), \(half_height_2)]")

    let center_1_x = Double(min_1_x) + half_width_1
    let center_1_y = Double(min_1_y) + half_height_1

    //Log.d("1 center [\(center_1_x), \(center_1_y)]")
    
    let center_2_x = Double(min_2_x) + half_width_2
    let center_2_y = Double(min_2_y) + half_height_2
    

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
    let dist_1 = distance_on(min_x: min_1_x, min_y: min_1_y, max_x: max_1_x, max_y: max_1_y,
                             slope: slope, y_intercept: y_intercept, theta: theta)
    //Log.d("dist_1 \(dist_1)")
    
    // the distance along the line between the center points that lies within group 2
    let dist_2 = distance_on(min_x: min_2_x, min_y: min_2_y, max_x: max_2_x, max_y: max_2_y,
                             slope: slope, y_intercept: y_intercept, theta: theta)

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

