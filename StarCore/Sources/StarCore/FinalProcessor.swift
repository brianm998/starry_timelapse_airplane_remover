/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import logging
import Cocoa
import Semaphore

// this class handles the final processing of every frame
// it observes its frames array, and is tasked with finishing each frame.   
// In order to be able to calculate the classfier features for each outlier group,
// We need to line up all of the frames in order so that each frame can access
// some number of neighboring frames in each data when calculating partulcar features.

public actor FinalProcessor {

    var frames: [FrameAirplaneRemover?]
    var currentFrameIndex = 0
    var maxAddedIndex = 0
    let frameCount: Int
    let imageSequence: ImageSequence

    let config: Config
    let callbacks: Callbacks 
    let shouldProcess: [Bool]

    private let semaphore = AsyncSemaphore(value: 0)
    
    // are we running on the gui?
    public let isGUI: Bool

    init(with config: Config,
         callbacks: Callbacks,
         numberOfFrames frameCount: Int,
         shouldProcess: [Bool],
         imageSequence: ImageSequence,
         isGUI: Bool) async
    {
        self.isGUI = isGUI
        self.config = config
        self.callbacks = callbacks
        self.frames = [FrameAirplaneRemover?](repeating: nil, count: frameCount)
        self.frameCount = frameCount
        self.imageSequence = imageSequence
        self.shouldProcess = shouldProcess
    }

    func add(frame: FrameAirplaneRemover) {
        let index = frame.frameIndex
        if index > self.maxAddedIndex {
            self.maxAddedIndex = index
        }

        Log.d("frame \(index) added for final inter-frame analysis \(self.maxAddedIndex)")
        self.frames[index] = frame

        self.semaphore.signal()
        
        self.log()
    }
    
    func clearFrame(at index: Int) {
        frames[index] = nil //SIGABRT after reloading a different sequence
    }
    
    func incrementCurrentFrameIndex() {
        currentFrameIndex += 1

        log()
    }

    private func log() {
        if let updatable = callbacks.updatable {
           let localFrames = self.frames
            // show what frames are in place to be processed
           TaskWaiter.shared.task(priority: .userInitiated) {
               var padding = ""
               let numConcurrentRenders = 30 // XXX
               if numConcurrentRenders < self.config.progressBarLength {
                   padding = String(repeating: " ", count: (self.config.progressBarLength - numConcurrentRenders))
               }
               
               var message: String = padding + ConsoleColor.blue.rawValue + "["
               var count = 0
               let end = self.currentFrameIndex + numConcurrentRenders
               for i in self.currentFrameIndex ..< end {
                   if i >= localFrames.count {
                       message += ConsoleColor.yellow.rawValue + "-"
                   } else {
                       if let _ = localFrames[i] {
                           message += ConsoleColor.green.rawValue + "*"
                           count += 1
                       } else {
                           message += ConsoleColor.yellow.rawValue + "-"
                       }
                   }
               }
               var lowerBound = self.currentFrameIndex + end
               if lowerBound > localFrames.count { lowerBound = localFrames.count }
               
               for i in lowerBound ..< localFrames.count {
                   if let _ = localFrames[i] {
                       count += 1
                   }
               }
               message += ConsoleColor.blue.rawValue+"]"+ConsoleColor.reset.rawValue
               let name = "frames awaiting inter frame processing"
               message += " \(count) \(name)"
               await updatable.log(name: name, message: message, value: 50)
           }
        }
    }


    func frame(at index: Int) -> FrameAirplaneRemover? {
        return frames[index]
    }

    var framesBetween: Int {
        var ret = maxAddedIndex - currentFrameIndex
        if ret < 0 { ret = 0 }
        
        return ret
    }
    
    func finishAll() async throws {
        Log.d("finishing all")
        try await withLimitedThrowingTaskGroup(of: Void.self,
                                               at: .medium) { taskGroup in
            for (_, frame) in frames.enumerated() {
                if let frame {
                    Log.d("adding frame \(frame.frameIndex) to final queue")
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

        Log.d("finish frame \(frame.frameIndex)")
        
        if let frameCheckClosure = callbacks.frameCheckClosure
        {
            // gui
            await MainActor.run {
                Log.d("calling frameCheckClosure for frame \(frame.frameIndex)")
                let t0 = NSDate().timeIntervalSince1970
                frameCheckClosure(frame)
                let t1 = NSDate().timeIntervalSince1970
                Log.i("frame \(frame.frameIndex) took \(t1-t0) seconds on frame check closure")
            }
        }            

        // cli and not checked frames go to the finish queue
        Log.d("adding frame \(frame.frameIndex) to the final queue")

        Log.d("frame \(frame.frameIndex) finishing")
        try await frame.finish()
        Log.d("frame \(frame.frameIndex) finished")
    }

    nonisolated func run() async throws {

        let frameCount = await frames.count

        // wait here for at least one frame to be published
        await semaphore.wait()
        
        var done = false
        try await withLimitedThrowingTaskGroup(of: Void.self,
                                               at: .medium) { taskGroup in
            while(!done) {
                //Log.v("FINAL THREAD running")
                let (cfi, framesCount) = await (currentFrameIndex, frames.count)
                done = cfi >= framesCount
                //Log.v("FINAL THREAD done \(done) currentFrameIndex \(cfi) frames.count \(framesCount)")
                if done {
                    Log.d("we are done")
                    continue
                }
                
                let indexToProcess = await currentFrameIndex

                //Log.d("indexToProcess \(indexToProcess) shouldProcess[indexToProcess] \(shouldProcess[indexToProcess])")
                
                if !isGUI,         // always process on gui so we can see them all
                   !shouldProcess[indexToProcess]
                {
                    if let frameCheckClosure = callbacks.frameCheckClosure {
                        if let frame = await self.frame(at: indexToProcess) {
                            //Log.d("calling frameCheckClosure for frame \(frame.frameIndex)")
                            await MainActor.run {
                                frameCheckClosure(frame)
                            }
                        } else {
                            //Log.d("NOT calling frameCheckClosure for frame \(indexToProcess)")
                        }
                    } else {
                        //Log.d("NOT calling frameCheckClosure for frame \(indexToProcess)")
                    }
                    
                    // don't process existing files on cli
                    //Log.d("not processing \(indexToProcess)")
                    await self.incrementCurrentFrameIndex()
                    continue
                }

                var imagesToProcess: [FrameAirplaneRemover] = []
                
                var startIndex = indexToProcess - config.numberFinalProcessingNeighborsNeeded
                var endIndex = indexToProcess + config.numberFinalProcessingNeighborsNeeded
                if startIndex < 0 {
                    startIndex = 0
                }
                if endIndex >= frameCount {
                    endIndex = frameCount - 1
                }

                //Log.d("startIndex \(startIndex) endIndex \(endIndex)")
                
                var haveEnoughFramesToInterFrameProcess = true

                for i in startIndex ... endIndex {
                    //Log.v("looking for frame at \(i)")
                    if let nextFrame = await self.frame(at: i) {
                        imagesToProcess.append(nextFrame)
                    } else {
                        // this means we don't have enough neighboring frames to inter frame process yet
                        haveEnoughFramesToInterFrameProcess = false
                    }
                }
                if haveEnoughFramesToInterFrameProcess {
                    Log.i("FINAL THREAD frame \(indexToProcess) doing inter-frame analysis with \(imagesToProcess.count) frames")

                    // doubly link the outliers so their feature values across frames work
                    doublyLink(frames: imagesToProcess)    

                    Log.i("FINAL THREAD frame \(indexToProcess) done with inter-frame analysis")
                    await self.incrementCurrentFrameIndex()
                    
                    if startIndex > 0,
                       indexToProcess < frameCount - config.numberFinalProcessingNeighborsNeeded - 1
                    {
                        // maybe finish a previous frame
                        // leave the ones at the end to finishAll()
                        let immutableStart = startIndex
                        //Log.v("FINAL THREAD frame \(indexToProcess) queueing into final queue")
                        if let frameToFinish = await self.frame(at: immutableStart - 1) {
                            await self.clearFrame(at: immutableStart - 1)
                            
                            // run as a deferred task so we never block here 
                            try await taskGroup.addDeferredTask() {

                                await frameToFinish.clearOutlierGroupValueCaches()

                                await frameToFinish.maybeApplyOutlierGroupClassifier()
                                frameToFinish.set(state: .outlierProcessingComplete)
                                
                                Log.v("FINAL THREAD frame \(indexToProcess) classified")
                                do {
                                    try await self.finish(frame: frameToFinish)
                                } catch {
                                    Log.e("FINAL THREAD frame \(indexToProcess) ERROR \(error)")
                                }
                                Log.v("FINAL THREAD frame \(indexToProcess) DONE")
                            }
                        }
                        //Log.v("FINAL THREAD frame \(indexToProcess) done queueing into final queue")
                    }
                } else {
                    // we don't have enough frames to process, wait for another
                    await semaphore.wait()
                }
            }
                    
            // wait for all existing tasks to complete 
            try await taskGroup.waitForAll()
        }

        Log.i("FINAL THREAD finishing all remaining frames")
        try await self.finishAll() 
        Log.i("FINAL THREAD done finishing all remaining frames")
    }
}    


public func doublyLink(frames: [FrameAirplaneRemover]) {
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




