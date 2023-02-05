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
actor AirplaneStreaks {
    var streaks: [String:[AirplaneStreakMember]] = [:]

    func removeValue(forKey key: String) {
        streaks.removeValue(forKey: key)
    }

    func add(value: [AirplaneStreakMember], forKey key: String) {
        streaks[key] = value
    }

    var count: Int { return streaks.count }
}

@available(macOS 10.15, *)
var airplane_streaks = AirplaneStreaks()

@available(macOS 10.15, *)
public actor FinalProcessor {
    var frames: [FrameAirplaneRemover?]
    var current_frame_index = 0
    var max_added_index = 0
    let frame_count: Int
    let dispatch_group: DispatchHandler
    public let final_queue: FinalQueue
    let image_sequence: ImageSequence

    let config: Config
    let callbacks: Callbacks
    
    var is_asleep = false
    
    init(with config: Config,
         callbacks: Callbacks,
         numberOfFrames frame_count: Int,
         dispatchGroup dispatch_group: DispatchHandler,
         imageSequence: ImageSequence)
    {
        self.config = config
        self.callbacks = callbacks
        self.frames = [FrameAirplaneRemover?](repeating: nil, count: frame_count)
        self.frame_count = frame_count
        self.dispatch_group = dispatch_group
        self.image_sequence = imageSequence
        self.final_queue = FinalQueue(max_concurrent: config.numConcurrentRenders,
                                      dispatchGroup: dispatch_group)
    }

    func add(frame: FrameAirplaneRemover) {
        let index = frame.frame_index
        Log.i("FINAL THREAD frame \(index) added for final inter-frame analysis")
        if index > max_added_index {
            max_added_index = index
        }
        frames[index] = frame
        log()
    }

    func clearFrame(at index: Int) {
        frames[index] = nil
    }
    
    func incrementCurrentFrameIndex() {
        current_frame_index += 1

        log()
    }

    private func log() {
        if let updatable = callbacks.updatable {
            // show what frames are in place to be processed
            Task(priority: .userInitiated) {
                var padding = ""
                if self.config.numConcurrentRenders < config.progress_bar_length {
                    padding = String(repeating: " ", count: (config.progress_bar_length - self.config.numConcurrentRenders))
                }
                
                var message: String = padding + ConsoleColor.blue.rawValue + "["
                var count = 0
                let end = current_frame_index + config.numConcurrentRenders
                for i in current_frame_index ..< end {
                    if i >= self.frames.count {
                        message += ConsoleColor.yellow.rawValue + "-";
                    } else {
                        if let _ = self.frames[i] {
                            message += ConsoleColor.green.rawValue + "*";
                            count += 1
                        } else {
                            message += ConsoleColor.yellow.rawValue + "-";
                        }
                    }
                }
                message += ConsoleColor.blue.rawValue+"]"+ConsoleColor.reset.rawValue;
                let name = "frames awaiting inter frame processing"
                message += " \(count) \(name)"
                await updatable.log(name: name, message: message, value: 2)
            }
         }
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
    
    func finishAll() async throws {
        Log.d("finishing all")
        var count = 0
        for (index, frame) in frames.enumerated() {
            if let frame = frame {
                count += 1
                Log.d("adding frame \(frame.frame_index) to final queue")
                await self.final_queue.method_list.add(atIndex: frame.frame_index) {
                    if index + 2 <= self.frames.count,
                       let next_frame = self.frame(at: index + 1)
                    {
                        await really_final_streak_processing(onFrame: frame,
                                                             nextFrame: next_frame)
                    }

                    await self.finish(frame: frame)
                }
            }
        }
        let method_list_count = await self.final_queue.method_list.count
        Log.d("add all \(count) remaining frames to method list of count \(method_list_count)")
    }

    func finish(frame: FrameAirplaneRemover) async {
        // here is where the gui and cli paths diverge
        // if we have a frame check closure, we allow the user to check the frame here
        // but only if there are some outliers to check, otherwise just finish it.

        if let frameCheckClosure = callbacks.frameCheckClosure,
           await frame.outlierGroupCount > 0
        {
            // gui
            await frameCheckClosure(frame)
        } else {
            // cli
            await self.final_queue.add(atIndex: frame.frame_index) {
                Log.i("frame \(frame.frame_index) finishing")
                try await frame.finish()
                Log.i("frame \(frame.frame_index) finished")
            }
        }
    }

    nonisolated func run(shouldProcess: [Bool]) async throws {

        let frame_count = await frames.count
        
        var done = false
        while(!done) {
            Log.v("FINAL THREAD running")
            let (cfi, frames_count) = await (current_frame_index, frames.count)
            done = cfi >= frames_count
            Log.v("FINAL THREAD done \(done) current_frame_index \(cfi) frames.count \(frames_count)")
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
            
            var start_index = index_to_process - config.number_final_processing_neighbors_needed
            var end_index = index_to_process + config.number_final_processing_neighbors_needed
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
                    Log.v("FINAL THREAD bad")
                }
            }
            if !bad {
                Log.i("FINAL THREAD frame \(index_to_process) doing inter-frame analysis with \(images_to_process.count) frames")
                await run_final_pass(frames: images_to_process, config: config)
                Log.i("FINAL THREAD frame \(index_to_process) done with inter-frame analysis")
                await self.incrementCurrentFrameIndex()
                
                if start_index > 0,
                   index_to_process < frame_count - config.number_final_processing_neighbors_needed - 1
                {
                    // maybe finish a previous frame
                    // leave the ones at the end to finishAll()
                    let immutable_start = start_index
                    Log.v("FINAL THREAD frame \(index_to_process) queueing into final queue")
                    if let frame_to_finish = await self.frame(at: immutable_start - 1),
                       let next_frame = await self.frame(at: immutable_start)
                    {
                        await self.clearFrame(at: immutable_start - 1)

                        // identify all existing streaks with length of only 2
                        // try to find other nearby streaks, if not found,
                        //then skip for new not paint reason
                        await frame_to_finish.set(state: .interFrameProcessing)
                        
                        Log.d("running final streak processing on frame \(frame_to_finish.frame_index)")

                        await really_final_streak_processing(onFrame: frame_to_finish,
                                                             nextFrame: next_frame)

                        Log.d("running final streak processing on frame \(frame_to_finish.frame_index)")
                        //let final_frame_group_name = "final frame \(frame_to_finish.frame_index)"
                        Log.d("frame \(frame_to_finish.frame_index) adding at index ")
                        await frame_to_finish.set(state: .outlierProcessingComplete)
                        // XXX lots of images are getting blocked up here for some reason


                        // here we need to see if we are in gui or cli mode

                        // gui needs to have the user look at each image now and
                        // validate it, maybe making painting changes

                        // cli needs to go straight to the final queue as seen here

                        await self.finish(frame: frame_to_finish)
                    }
                    Log.v("FINAL THREAD frame \(index_to_process) done queueing into final queue")
                }
            } else {
                Log.v("FINAL THREAD sleeping")
                await self.setAsleep(to: true)

                try await Task.sleep(nanoseconds: 1_000_000_000)
                //sleep(1)        // XXX hardcoded sleep amount
                
                Log.v("FINAL THREAD waking up")
                await self.setAsleep(to: false)
            }
        }

        Log.i("FINAL THREAD finishing all remaining frames")
        try await self.finishAll()

        if let frameCheckClosure = callbacks.frameCheckClosure {
            // XXX there is a race condition here if we are in gui
            // mode where we add each frame off to the gui for processing
            // XXX make this better
            try await Task.sleep(nanoseconds: 5_000_000_000)
            
            Log.i("FINAL THREAD check closure")

            // XXX look for method to call here
            
            // XXX need to await here for the frame check if it's happening

            if let countOfFramesToCheck = callbacks.countOfFramesToCheck {
                var count = await countOfFramesToCheck()
                Log.i("FINAL THREAD countOfFramesToCheck \(count)")
                while(count > 0) {
                    Log.i("FINAL THREAD sleeping with count \(count)")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    count = await countOfFramesToCheck()
                }
            } else {
                Log.e("must set both frameCheckClosure and countOfFramesToCheck")
                fatalError("must set both frameCheckClosure and countOfFramesToCheck")
            }
        }
        
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
    
    for (streak_name, airplane_streak) in await airplane_streaks.streaks {
        if let last_member = airplane_streak.last {
            if last_member.frame_index < frame.frame_index - 5 { // XXX arbitrary, just to be sure 
                // delete the older streak we don't need anymore
                await airplane_streaks.removeValue(forKey: streak_name)
            }
        }
    }

    for (streak_name, airplane_streak) in await airplane_streaks.streaks {
        if airplane_streak.count != 2 { continue }
        let first_member = airplane_streak[0]
        let last_member = airplane_streak[1]
        if last_member.frame_index == frame.frame_index || 
             first_member.frame_index == frame.frame_index
        {
            var remove_small_streak = true
            
            // this is a two member airplane streak that is on our frame
            // look for other streaks that might match up to it on either side
            // if neither found, then dump it
            
            for (other_streak_name, other_airplane_streak) in await airplane_streaks.streaks {
                if other_streak_name == streak_name { continue }
                
                // this streak must begin or end at the right end of this 2 count streak
                
                if let last_other_airplane_streak = other_airplane_streak.last {
                    let first_other_airplane_streak = other_airplane_streak[0]
                    
                    let move_me_theta_diff: Double = 10      // XXX move me
                    
                    if first_member.frame_index == last_other_airplane_streak.frame_index + 1 {
                        // found a streak that ended right before this one started
                        
                        if let first_member_group_line = first_member.group.firstLine,
                           let last_other_airplane_streak_group_line = last_other_airplane_streak.group.firstLine
                        {
                            let distance = await distance(from: last_other_airplane_streak.group,
                                                          to: first_member.group)
                            
                            let theta_diff = abs(last_other_airplane_streak_group_line.theta -
                                                   first_member_group_line.theta)
                            
                            let hypo_avg = (first_member.group.bounds.hypotenuse +
                                              last_other_airplane_streak.group.bounds.hypotenuse)/2
                            
                            let move_me_distance_limit = hypo_avg + 2 // XXX contstant
                            
                            if distance < move_me_distance_limit && theta_diff < move_me_theta_diff {
                                remove_small_streak = false
                            }
                        }
                        
                    } else if last_member.frame_index + 1 == first_other_airplane_streak.frame_index {
                        if let last_member_group_line = last_member.group.firstLine,
                           let first_other_airplane_streak_group_line = first_other_airplane_streak.group.firstLine
                        {
                            // found a streak that starts right after this one ends
                            let distance = await distance(from: last_member.group,
                                                          to: first_other_airplane_streak.group)
                            
                            let theta_diff = abs(first_other_airplane_streak_group_line.theta -
                                                   last_member_group_line.theta)
                            
                            let hypo_avg = (last_member.group.bounds.hypotenuse +
                                              first_other_airplane_streak.group.bounds.hypotenuse)/2
                            
                            let move_me_distance_limit =  hypo_avg + 2 // XXX contstant
                            
                            if distance < move_me_distance_limit && theta_diff < move_me_theta_diff {
                                remove_small_streak = false
                            }
                        }
                    }
                }
            }
            
            if remove_small_streak {
                        
                var total_line_score: Double = 0
                // one last check on the line score
                for member_to_remove in airplane_streak {
                    total_line_score += member_to_remove.group.paintScore(from: .houghTransform)
                }
                total_line_score /= Double(airplane_streak.count)
                
                // only get rid of small streaks if they don't look like lines
                if total_line_score < 0.25 { // XXX constant
                    
                    await airplane_streaks.removeValue(forKey: streak_name) // XXX mutating while iterating?
                    
                    for member_to_remove in airplane_streak {
                        // change should_paint to new value for the frame
                        if member_to_remove.frame_index < frame.frame_index {
                            Log.w("frame \(member_to_remove.frame_index) is already finalized, modifying it now won't change anythig :(")
                            //fatalError("FUCK")
                        } 
                        // here 'removing' means 'de-streakifying' it
                        // it may or may not still be painted, but now it's not based upon other groups 
                        member_to_remove.group.setShouldPaintFromCombinedScore()
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
fileprivate func run_final_pass(frames: [FrameAirplaneRemover],
                                config: Config) async
{
    Log.i("final pass on \(frames.count) frames doing streak analysis")

    await run_final_streak_pass(frames: frames, config: config) // XXX not actually the final streak pass anymore..

    Log.i("running overlap pass on \(frames.count) frames")

    await run_final_overlap_pass(frames: frames, config: config)

    Log.i("done with final pass on \(frames.count) frames")
}

var GLOBAL_last_overlap_frame_number = 0 // XXX

@available(macOS 10.15, *)
fileprivate func run_final_overlap_pass(frames: [FrameAirplaneRemover],
                                        config: Config) async
{
    for (index, frame) in frames.enumerated() {
        if frame.frame_index < GLOBAL_last_overlap_frame_number { continue }
        if index + 1 >= frames.count { continue }
        GLOBAL_last_overlap_frame_number = frame.frame_index            
        let other_frame = frames[index+1]
        
        Log.d("overlap pass on frame with \(await frame.outlierGroupCount) outliers other frame has \(await other_frame.outlierGroupCount) outliers")
        
        await frame.foreachOutlierGroup { group in
                
            let houghScore = group.paintScore(from: .houghTransform)
            
            if houghScore > config.medium_hough_line_score { return .continue }
            
            // look for more data to act upon
            
            if let reason = group.shouldPaint,
               reason.willPaint
            {
                switch reason {
                case .looksLikeALine(let amount):
                    Log.i("frame \(frame.frame_index) skipping \(group) because of \(reason)") 
                    return .continue
                case .inStreak(let size):
                    if size > 2 {
                        return .continue
                        //Log.i("frame \(frame.frame_index) skipping \(group_name) because of \(reason)") 
                        // XXX this skips streaks that it shouldn't
                    }
                default:
                    break
                }
            }
            
            guard let group_line = group.firstLine else { return .continue }
            let (line_theta, line_rho) = (group_line.theta, group_line.rho)
            
            await other_frame.foreachOutlierGroup() { og in
                if group.size > og.size * 5 { return .continue } // XXX constant, five times larger
                if og.size > group.size * 5 { return .continue } // XXX constant, five times larger
                
                let distance = group.bounds.centerDistance(to: og.bounds)
                
                if distance > 300 { return .continue } // XXX arbitrary constant
                
                guard let og_line = og.firstLine else { return .continue }
                
                
                let other_line_theta = og_line.theta
                let other_line_rho = og_line.rho
                
                let theta_diff = abs(line_theta-other_line_theta)
                let rho_diff = abs(line_rho-other_line_rho)
                if (theta_diff < config.final_theta_diff || abs(theta_diff - 180) < config.final_theta_diff) &&
                     rho_diff < config.final_rho_diff
                {
                    // first see how much their bounds overlap
                    // if overlap is more than 30-40%, then skip the pixel overlap,
                    // and just mark them as no paint
                    
                    let overlap_amount = group.bounds.overlapAmount(with: og.bounds)
                    
                    var close_enough = false
                    
                    if overlap_amount > 0.33 { // XXX hardcoded constant
                        // first just check overlap of bounds
                        close_enough = true
                    }
                    
                    if !close_enough {
                        let pixel_overlap_amount =
                          await pixel_overlap(group_1: group, group_2: og)
                        
                        
                        var do_it = true
                        
                        // do paint over objects that look like lines
                        if let frame_reason = group.shouldPaint {
                            if frame_reason.willPaint && frame_reason == .looksLikeALine(0) {
                                do_it = false
                            }
                        }
                        
                        if let other_reason = og.shouldPaint {
                            if other_reason.willPaint && other_reason == .looksLikeALine(0) {
                                do_it = false
                            }
                        }
                        
                        if do_it {
                            close_enough = pixel_overlap_amount > 0.05 // XXX hardcoded constant
                        } else {
                            close_enough = false
                        }
                    }
                    
                    if close_enough {
                        group.shouldPaint(.adjecentOverlap(overlap_amount))
                        og.shouldPaint(.adjecentOverlap(overlap_amount))
                        Log.v("frame \(frame.frame_index) should_paint[\(group)] = (false, .adjecentOverlap(\(overlap_amount))")
                        Log.v("frame \(other_frame.frame_index) should_paint[\(og)] = (false, .adjecentOverlap(\(overlap_amount))")
                    } else {
                        Log.v("frame \(frame.frame_index) \(group) left untouched because of pixel overlap amount \(overlap_amount)")
                        Log.v("frame \(other_frame.frame_index) \(og) left untouched because of pixel overlap amount \(overlap_amount)")
                        
                    }
                }
                return .continue
            }
            return .continue
        }
    }
}

var GLOBAL_last_streak_frame_number = 0 // XXX

// looks for airplane streaks across frames
@available(macOS 10.15, *)
fileprivate func run_final_streak_pass(frames: [FrameAirplaneRemover],
                                       config: Config) async
{

    let initial_frame_index = frames[0].frame_index
    
    for (batch_index, frame) in frames.enumerated() {
        let frame_index = frame.frame_index
        if frame_index < GLOBAL_last_streak_frame_number { continue }
        Log.d("frame_index \(frame_index)")
        if batch_index + 1 == frames.count { continue } // the last frame can be ignored here
        GLOBAL_last_streak_frame_number = frame_index            

        await withTaskGroup(of: [AirplaneStreakMember].self) { taskGroup in
            await frame.foreachOutlierGroup() { group in
                // do streak detection in parallel at the level of groups in a single frame
                // look for more data to act upon
                
                if let reason = group.shouldPaint {
                    if reason == .adjecentOverlap(0) {
                        Log.v("frame \(frame.frame_index) skipping \(group) because it has .adjecentOverlap")
                        return .continue
                    }
                }
                taskGroup.addTask(priority: .medium) {
                        
                    // grab a streak that we might already be in
                        
                    var existing_streak: [AirplaneStreakMember]?
                    var existing_streak_name: String?
                        
                    for (streak_name, airplane_streak) in await airplane_streaks.streaks {
                        if let _ = existing_streak { continue }
                        for streak_member in airplane_streak {
                            if frame_index == streak_member.frame_index &&
                                 group.name == streak_member.group.name
                            {
                                existing_streak = airplane_streak
                                existing_streak_name = streak_name
                                Log.v("frame \(frame.frame_index) using existing streak for \(group)")
                                continue
                            }
                        }
                    }
                    
                    Log.v("frame \(frame_index) looking for streak for \(group)")
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
                    
                    let houghScore = group.paintScore(from: .houghTransform)
                    
                    if houghScore > 0.007 { // XXX constant
                        if let streak = 
                             await streak_from(group: group, 
                                               frames: frames,
                                               startingIndex: batch_index+1,
                                               potentialStreak: &potential_streak,
                                               config: config)
                        {
                            Log.v("frame \(frame_index) found streak \(potential_streak_name) of size \(streak.count) for \(group)")
                            return streak
                        }
                    }
                    return []  // no streak found here
                }
                return .continue
            }
            while let streak = await taskGroup.next() {
                if streak.count > 0 {
                    let first_member = streak[0]
                    let key = "\(first_member.group.frame_index).\(first_member.group.name)"
                    Log.v("frame \(frame_index) adding streak \(streak) named \(key)")
                    await airplane_streaks.add(value: streak, forKey: key)
                }
            }
        }
    }
    
    // go through and mark all of airplane_streaks to paint
    Log.d("analyzing \(await airplane_streaks.streaks.count) streaks")
    await withTaskGroup(of: Void.self) { taskGroup in
        for (streak_name, airplane_streak) in await airplane_streaks.streaks {
            let first_member = airplane_streak[0]
            Log.d("analyzing streak \(streak_name) starting with group \(first_member.group) frame_index \(first_member.frame_index) with \(airplane_streak.count) members")
            if airplane_streak.count < 3 { // XXX hardcoded constant
                // reject small streaks
                Log.v("ignoring two member streak \(airplane_streak)")
                continue
            } 
            taskGroup.addTask(priority: .medium) {
                var verbotten = false
                //let index_of_first_streak = airplane_streak[0].frame_index
                for streak_member in airplane_streak {
                    if streak_member.frame_index - initial_frame_index < 0 ||
                         streak_member.frame_index - initial_frame_index >= frames.count {
                        // these are frames that are part of the streak, but not part of the batch
                        // being processed right now,
                    } else {
                        //let frame = frames[streak_member.frame_index - initial_frame_index]
                        if let should_paint = streak_member.group.shouldPaint{
                            if should_paint == .adjecentOverlap(0) { verbotten = true }
                        }
                    }
                }
                if verbotten { return }
                Log.d("painting over airplane streak \(airplane_streak)")
                for streak_member in airplane_streak {
                    Log.d("frame \(streak_member.frame_index) will paint group \(streak_member.group) is .inStreak")

                    // XXX check to see if this is already .inStreak with higher count
                    streak_member.group.shouldPaint(.inStreak(airplane_streak.count))
                }
            }
        }
        await taskGroup.waitForAll()
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
                 potentialStreak potential_streak: inout [AirplaneStreakMember],
                 config: Config)
  async -> [AirplaneStreakMember]?
{

    Log.v("trying to find streak starting at \(group)")
    
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
    Log.v("starting_index \(starting_index)  \(frames.count)")
    for index in starting_index ..< frames.count {
        let frame = frames[index]
        let frame_index = frame.frame_index
        count += 1

        let last_hypo = last_group.bounds.hypotenuse
        // calculate min distance from hypotenuse of last bounding box
        let min_distance: Double = last_hypo * 2 // XXX hardcoded constant
        
        var best_distance = min_distance
        Log.v("looking at frame \(frame.frame_index)")

        await frame.foreachOutlierGroup() { other_group in
            // XXX not sure this value is right
            // really we want the distance between the nearest pixels of each group
            // this isn't close enough for real

            let distance = await distance(from: last_group, to: other_group)

            let last_group_hypo = last_hypo//last_group.bounds.hypotenuse
            let other_group_hypo = other_group.bounds.hypotenuse

            // too far apart
            if distance > last_group_hypo + other_group_hypo { return .continue }
            
            let center_line_theta = center_theta(from: last_group.bounds, to: other_group.bounds)

            guard let other_group_line = other_group.firstLine else { return .continue }
            guard let last_group_line = last_group.firstLine else { return .continue }
            
            let (other_group_line_theta,
                 last_group_line_theta) = (other_group_line.theta,
                                           last_group_line.theta)
            
            let (theta_diff, rho_diff) = (abs(last_group_line.theta-other_group_line_theta),
                                          abs(last_group_line.rho-other_group_line.rho))

            let center_line_theta_diff_1 = abs(center_line_theta-other_group_line_theta)
            let center_line_theta_diff_2 = abs(center_line_theta-last_group_line_theta)

            let houghScore = other_group.paintScore(from: .houghTransform)

            // XXX constant  VVV 
            if houghScore > 0.007 &&
                 distance < best_distance &&
                 (theta_diff < config.final_theta_diff || abs(theta_diff - 180) < config.final_theta_diff) &&
                 ((center_line_theta_diff_1 < config.center_line_theta_diff ||
                     abs(center_line_theta_diff_1 - 180) < config.center_line_theta_diff) || // && ??
                    (center_line_theta_diff_2 < config.center_line_theta_diff ||
                       abs(center_line_theta_diff_2 - 180) < config.center_line_theta_diff)) &&
                 rho_diff < config.final_rho_diff
            {
//                Log.d("frame \(frame.frame_index) \(other_group) is \(distance) away from \(last_group) other_group_line_theta \(other_group_line_theta) last_group_line_theta \(last_group_line_theta) center_line_theta \(center_line_theta)")

                Log.v("frame \(frame.frame_index) \(other_group) DOES match \(group) houghScore \(houghScore) medium_hough_line_score \(config.medium_hough_line_score) distance \(distance) best_distance \(best_distance) theta_diff \(theta_diff) rho_diff \(rho_diff) center_line_theta_diff_1 \(center_line_theta_diff_1) center_line_theta_diff_2 \(center_line_theta_diff_2) center_line_theta \(center_line_theta) last \(last_group_line_theta) other \(other_group_line_theta)")

                best_group = other_group
                best_distance = distance
                best_frame_index = frame_index
            } else {
                Log.v("frame \(frame.frame_index) \(other_group) doesn't match \(group) houghScore \(houghScore) medium_hough_line_score \(config.medium_hough_line_score) distance \(distance) best_distance \(best_distance) theta_diff \(theta_diff) rho_diff \(rho_diff) center_line_theta_diff_1 \(center_line_theta_diff_1) center_line_theta_diff_2 \(center_line_theta_diff_2) center_line_theta \(center_line_theta) last \(last_group_line_theta) other \(other_group_line_theta)")
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

                        let distance_one_back = best_group.bounds.centerDistance(to: member_one_back.group.bounds)
                        let distance_two_back = best_group.bounds.centerDistance(to: member_two_back.group.bounds)

                        if distance_two_back < distance_one_back {
                            Log.v("not adding \(best_group) to streak because it's not going in the right direction")
                            do_it = false
                        }

                        // also check if the center line theta between the three points are close enough
                        // i.e. the center line theta should not be too far off between this new group
                        // and the ones before it

                        let center_theta_one_back = center_theta(from: best_group.bounds,
                                                                 to: member_one_back.group.bounds)
                        let center_theta_two_back = center_theta(from: best_group.bounds,
                                                                 to: member_two_back.group.bounds)

                        if(abs(center_theta_one_back - center_theta_two_back) > 20) {// XXX constant (could be larger?)
                            Log.v("not adding \(best_group) to streak because \(center_theta_one_back) - \(center_theta_two_back) > 20")
                            do_it = false
                        }
                    }

                    if do_it {
                        // set previous last group here for comparison later
                        last_group = best_group
                        
                        Log.v("frame \(frame.frame_index) adding group \(best_group) to streak best_distance \(best_distance)")
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
        Log.v("returning potential_streak \(potential_streak)")
        return potential_streak
    }
}



// theta in degrees of the line between the centers of the two bounding boxes
func center_theta(from box_1: BoundingBox, to box_2: BoundingBox) -> Double {
    //Log.v("center_theta(box_1.min.x: \(box_1.min.x), box_1.min.y: \(box_1.min.y), box_1.max.x: \(box_1.max.x), box_1.max.y: \(box_1.max.y), min_2_x: \(min_2_x), min_2_y: \(min_2_y), max_2_x: \(max_2_x), box_2.max.y: \(box_2.max.y)")

    //Log.v("2 half size [\(half_width_2), \(half_height_2)]")

    let center_1_x = Double(box_1.min.x) + Double(box_1.width)/2
    let center_1_y = Double(box_1.min.y) + Double(box_1.height)/2

    //Log.v("1 center [\(center_1_x), \(center_1_y)]")
    
    let center_2_x = Double(box_2.min.x) + Double(box_2.width)/2
    let center_2_y = Double(box_2.min.y) + Double(box_2.height)/2
    
    //Log.v("2 center [\(center_2_x), \(center_2_y)]")

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
    //Log.v("theta_degrees \(theta_degrees)")
    return  theta_degrees
}

// how many pixels actually overlap between the groups ?  returns 0-1 value of overlap amount
@available(macOS 10.15, *)
func pixel_overlap(group_1: OutlierGroup,
                   group_2: OutlierGroup) async -> Double // 1 means total overlap, 0 means none
{
    // throw out non-overlapping frames, do any slip through?
    if group_1.bounds.min.x > group_2.bounds.max.x || group_1.bounds.min.y > group_2.bounds.max.y { return 0 }
    if group_2.bounds.min.x > group_1.bounds.max.x || group_2.bounds.min.y > group_1.bounds.max.y { return 0 }

    var min_x = group_1.bounds.min.x
    var min_y = group_1.bounds.min.y
    var max_x = group_1.bounds.max.x
    var max_y = group_1.bounds.max.y
    
    if group_2.bounds.min.x > min_x { min_x = group_2.bounds.min.x }
    if group_2.bounds.min.y > min_y { min_y = group_2.bounds.min.y }
    
    if group_2.bounds.max.x < max_x { max_x = group_2.bounds.max.x }
    if group_2.bounds.max.y < max_y { max_y = group_2.bounds.max.y }
    
    // XXX could search a smaller space probably

    var overlap_pixel_amount = 0;
    
    for x in min_x ... max_x {
        for y in min_y ... max_y {
            let outlier_1_index = (y - group_1.bounds.min.y) * group_1.bounds.width + (x - group_1.bounds.min.x)
            let outlier_2_index = (y - group_2.bounds.min.y) * group_2.bounds.width + (x - group_2.bounds.min.x)
            if outlier_1_index > 0,
               outlier_1_index < group_1.pixels.count,
               group_1.pixels[outlier_1_index] != 0,
               outlier_2_index > 0,
               outlier_2_index < group_2.pixels.count,
               group_2.pixels[outlier_2_index] != 0
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

// XXX this is likely causing false positives by being innacurate
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
        //Log.v("vertical")
        edge = .vertical
    } else if Double(bounding_box.min.x) - math_accuracy_error <= x_max_value && x_max_value <= Double(bounding_box.max.x) + math_accuracy_error {
        //Log.v("horizontal")
        edge = .horizontal
    } else {
        //Log.v("slope \(slope) y_intercept \(y_intercept) theta \(theta)")
        //Log.v("min_x \(min_x) x_max_value \(x_max_value) bounding_box.max.x \(bounding_box.max.x)")
        //Log.v("bounding_box.min.y \(bounding_box.min.y) y_max_value \(y_max_value) bounding_box.max.y \(bounding_box.max.y)")
        //Log.v("min_x \(min_x) x_min_value \(x_min_value) bounding_box.max.x \(bounding_box.max.x)")
        //Log.v("bounding_box.min.y \(bounding_box.min.y) y_min_value \(y_min_value) bounding_box.max.y \(bounding_box.max.y)")
        // this means that the line generated from the given slope and line
        // does not intersect the rectangle given 

        // can happen for situations of overlapping areas like this:
        //(1119 124),  (1160 153)
        //(1122 141),  (1156 160)

        // is this really a problem? not sure
        //Log.v("the line generated from the given slope and line does not intersect the rectangle given")
    }

    var hypotenuse_length: Double = 0
    
    switch edge {
    case .vertical:
        let half_width = Double(bounding_box.width)/2
        //Log.v("vertical half_width \(half_width)")
        hypotenuse_length = half_width / cos((90/180*Double.pi)-theta)
        
    case .horizontal:
        let half_height = Double(bounding_box.height)/2
        //Log.v("horizontal half_height \(half_height)")
        hypotenuse_length = half_height / cos(theta)
    }
    
    return hypotenuse_length
}
// positive if they don't overlap, negative if they do
func edge_distance(from box_1: BoundingBox, to box_2: BoundingBox) -> Double {
    
    let half_width_1 = Double(box_1.width)/2
    let half_height_1 = Double(box_1.height)/2
    
    //Log.v("1 half size [\(half_width_1), \(half_height_1)]")
    
    let half_width_2 = Double(box_2.width)/2
    let half_height_2 = Double(box_2.height)/2
    
    //Log.v("2 half size [\(half_width_2), \(half_height_2)]")

    let center_1_x = Double(box_1.min.x) + half_width_1
    let center_1_y = Double(box_1.min.y) + half_height_1

    //Log.v("1 center [\(center_1_x), \(center_1_y)]")
    
    let center_2_x = Double(box_2.min.x) + half_width_2
    let center_2_y = Double(box_2.min.y) + half_height_2
    

    //Log.v("2 center [\(center_2_x), \(center_2_y)]")

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

    //Log.v("slope \(slope) y_intercept \(y_intercept)")
    
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

    //Log.v("theta \(theta*180/Double.pi) degrees")
    
    // the distance along the line between the center points that lies within group 1
    let dist_1 = distance_on(box: box_1, slope: slope, y_intercept: y_intercept, theta: theta)
    //Log.v("dist_1 \(dist_1)")
    
    // the distance along the line between the center points that lies within group 2
    let dist_2 = distance_on(box: box_2, slope: slope, y_intercept: y_intercept, theta: theta)

    //Log.v("dist_2 \(dist_2)")

    // the direct distance bewteen the two centers
    let center_distance = sqrt(width * width + height * height)

    //Log.v("center_distance \(center_distance)")
    
    // return the distance between their centers minus the amount of the line which is within each group
    // will be positive if the distance is separation
    // will be negative if they overlap
    let ret = center_distance - dist_1 - dist_2
    //Log.v("returning \(ret)")
    return ret
}

