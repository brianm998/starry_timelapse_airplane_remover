/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import Cocoa


// this class handles the final processing of every frame
// it observes its frames array, and is tasked with finishing each frame.   
// In order to be able to calculate the classfier features for each outlier group,
// We need to line up all of the frames in order so that each frame can access
// some number of neighboring frames in each data when calculating partulcar features.

public actor FinalProcessor {
    var frames: [FrameAirplaneRemover?]
    var current_frame_index = 0
    var max_added_index = 0
    let frame_count: Int
    let dispatch_group: DispatchHandler
    let image_sequence: ImageSequence

    let config: Config
    let callbacks: Callbacks
    
    var is_asleep = false

    // are we running on the gui?
    public let is_gui: Bool

    init(with config: Config,
         callbacks: Callbacks,
         numberOfFrames frame_count: Int,
         dispatchGroup dispatch_group: DispatchHandler,
         imageSequence: ImageSequence,
         isGUI: Bool)
    {
        self.is_gui = isGUI
        self.config = config
        self.callbacks = callbacks
        self.frames = [FrameAirplaneRemover?](repeating: nil, count: frame_count)
        self.frame_count = frame_count
        self.dispatch_group = dispatch_group
        self.image_sequence = imageSequence
    }

    func add(frame: FrameAirplaneRemover) async {
        Log.d("add frame \(frame.frame_index)")

        let frame_state = frame.processingState()
        Log.d("add frame \(frame.frame_index) with state \(frame_state)")
        
        let index = frame.frame_index
        if index > max_added_index {
            max_added_index = index
        }

        Log.d("frame \(index) added for final inter-frame analysis \(max_added_index)")
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
                        message += ConsoleColor.yellow.rawValue + "-"
                    } else {
                        if let _ = self.frames[i] {
                            message += ConsoleColor.green.rawValue + "*"
                            count += 1
                        } else {
                            message += ConsoleColor.yellow.rawValue + "-"
                        }
                    }
                }
                message += ConsoleColor.blue.rawValue+"]"+ConsoleColor.reset.rawValue
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
        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
            for (_, frame) in frames.enumerated() {
                if let frame = frame {
                    Log.d("adding frame \(frame.frame_index) to final queue")
                    try await taskGroup.addTask() { 
                        await frame.maybeApplyOutlierGroupClassifier()
                        frame.set(state: .outlierProcessingComplete)
                        try await self.finish(frame: frame)
                    }
                }
            }
            try await taskGroup.waitForAll()
        }
    }

    nonisolated func finish(frame: FrameAirplaneRemover) async throws {
        // here is where the gui and cli paths diverge
        // if we have a frame check closure, we allow the user to check the frame here
        // but only if there are some outliers to check, otherwise just finish it.

        Log.d("finish frame \(frame.frame_index)")
        
        if let frameCheckClosure = callbacks.frameCheckClosure
        {
            // gui
            Log.d("calling frameCheckClosure for frame \(frame.frame_index)")
            await frameCheckClosure(frame)
            return
        }            

        // cli and not checked frames go to the finish queue
        Log.d("adding frame \(frame.frame_index) to the final queue")

        Log.d("frame \(frame.frame_index) finishing")
        try await frame.finish()
        Log.d("frame \(frame.frame_index) finished")
    }

    nonisolated func run(shouldProcess: [Bool]) async throws {

        let frame_count = await frames.count
        
        var done = false
        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
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

                Log.d("index_to_process \(index_to_process) shouldProcess[index_to_process] \(shouldProcess[index_to_process])")

                
                if !is_gui,         // always process on gui so we can see them all
                   !shouldProcess[index_to_process]
                {
                    if let frameCheckClosure = callbacks.frameCheckClosure {
                        if let frame = await self.frame(at: index_to_process) {
                            Log.d("calling frameCheckClosure for frame \(frame.frame_index)")
                            await frameCheckClosure(frame)
                        } else {
                            Log.d("NOT calling frameCheckClosure for frame \(index_to_process)")
                        }
                    } else {
                        Log.d("NOT calling frameCheckClosure for frame \(index_to_process)")
                    }
                    
                    // don't process existing files on cli
                    Log.d("not processing \(index_to_process)")
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

                Log.i("start_index \(start_index) end_index \(end_index)")
                
                var have_enough_frames_to_inter_frame_process = true
                //var index_in_images_to_process_of_main_frame = 0
                //var index_in_images_to_process = 0
                for i in start_index ... end_index {
                    Log.v("looking for frame at \(i)")
                    if let next_frame = await self.frame(at: i) {
                        images_to_process.append(next_frame)
                    } else {
                        // this means we don't have enough neighboring frames to inter frame process yet
                        have_enough_frames_to_inter_frame_process = false
                    }
                }
                if have_enough_frames_to_inter_frame_process {
                    Log.i("FINAL THREAD frame \(index_to_process) doing inter-frame analysis with \(images_to_process.count) frames")

                    // doubly link the outliers so their feature values across frames work
                    await doublyLink(frames: images_to_process)    

                    Log.i("FINAL THREAD frame \(index_to_process) done with inter-frame analysis")
                    await self.incrementCurrentFrameIndex()
                    
                    if start_index > 0,
                       index_to_process < frame_count - config.number_final_processing_neighbors_needed - 1
                    {
                        // maybe finish a previous frame
                        // leave the ones at the end to finishAll()
                        let immutable_start = start_index
                        Log.v("FINAL THREAD frame \(index_to_process) queueing into final queue")
                        if let frame_to_finish = await self.frame(at: immutable_start - 1) {
                            await self.clearFrame(at: immutable_start - 1)

                            try await taskGroup.addTask() { 
                                await frame_to_finish.clearOutlierGroupValueCaches()
                                await frame_to_finish.maybeApplyOutlierGroupClassifier()
                                frame_to_finish.set(state: .outlierProcessingComplete)

//                                try await taskGroup.addTask() { 
                                    // XXX VVV this is blocking other tasks
                                    try await self.finish(frame: frame_to_finish)
  //                              }
                            }
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

            // wait for all existing tasks to complete 
            try await taskGroup.waitForAll()
        }

        Log.i("FINAL THREAD finishing all remaining frames")
        try await self.finishAll() 
        Log.i("FINAL THREAD done finishing all remaining frames")

        if let _ = callbacks.frameCheckClosure {
            Log.d("FINAL THREAD check closure")

            // XXX look for method to call here
            
            // XXX need to await here for the frame check if it's happening

            if let countOfFramesToCheck = callbacks.countOfFramesToCheck {
                var count = await countOfFramesToCheck()
                Log.d("FINAL THREAD countOfFramesToCheck \(count)")
                while(count > 0) {
                    Log.d("FINAL THREAD sleeping with count \(count)")
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                    count = await countOfFramesToCheck()
                }
            } else {
                Log.e("must set both frameCheckClosure and countOfFramesToCheck")
                fatalError("must set both frameCheckClosure and countOfFramesToCheck")
            }
        }
        Log.d("FINAL THREAD done")
    }
}    


fileprivate func doublyLink(frames: [FrameAirplaneRemover]) async {
    // doubly link frames here so that the decision tree can have acess to other frames
    for (i, frame) in frames.enumerated() {
        if frames[i].previousFrame == nil,
           i > 0
        {
            frame.setPreviousFrame(frames[i-1])
        }
        if frames[i].nextFrame == nil,
           i < frames.count - 1
        {
            frame.setNextFrame(frames[i+1])
        }
    }
}




