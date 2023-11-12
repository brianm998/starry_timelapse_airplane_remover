/*

This file is part of the Starry Timelapse Airplane Remover (star).

star is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version.

star is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU General Public License along with star. If not, see <https://www.gnu.org/licenses/>.

*/

import Foundation
import CoreGraphics
import Cocoa
import Combine

// this class handles the final processing of every frame
// it observes its frames array, and is tasked with finishing each frame.   
// In order to be able to calculate the classfier features for each outlier group,
// We need to line up all of the frames in order so that each frame can access
// some number of neighboring frames in each data when calculating partulcar features.

public actor ClassifierCentral {

    private var frameNumber: Int?
    
    public func classify(frame: FrameAirplaneRemover) async -> Bool {
        while frameNumber != nil {
            return false
            //try await Task.sleep(nanoseconds: 1_000_000_000)
        }
        if frameNumber != nil { Log.e("FUCKNUTS") }
        frameNumber = frame.frameIndex
        //Log.w("frame \(frame.frameIndex) \(frameNumber) BEGIN CENTRAL classify")
        await frame.maybeApplyOutlierGroupClassifier()
        //Log.w("frame \(frame.frameIndex) \(frameNumber) END CENTRAL classify")
        frameNumber = nil
        return true
    }
}

public actor FinalProcessor {

    let centralClassifier = ClassifierCentral()
    
    var frames: [FrameAirplaneRemover?]
    var currentFrameIndex = 0
    var maxAddedIndex = 0
    let frameCount: Int
    let dispatchGroup: DispatchHandler
    let imageSequence: ImageSequence

    let config: Config
    let callbacks: Callbacks
    let shouldProcess: [Bool]
    
    var isAsleep = false

    // this is kept around to keep the subscription active
    // will be canceled upon de-init
    var publishCancellable: AnyCancellable?

    let numberRunning = NumberRunning()

    let numConcurrentRenders: Int

    // are we running on the gui?
    public let isGUI: Bool

    init(with config: Config,
         numConcurrentRenders: Int,
         callbacks: Callbacks,
         publisher: PassthroughSubject<FrameAirplaneRemover, Never>,
         numberOfFrames frameCount: Int,
         shouldProcess: [Bool],
         dispatchGroup: DispatchHandler,
         imageSequence: ImageSequence,
         isGUI: Bool) async
    {
        self.numConcurrentRenders = numConcurrentRenders
        self.isGUI = isGUI
        self.config = config
        self.callbacks = callbacks
        self.frames = [FrameAirplaneRemover?](repeating: nil, count: frameCount)
        self.frameCount = frameCount
        self.dispatchGroup = dispatchGroup
        self.imageSequence = imageSequence
        self.shouldProcess = shouldProcess

        // this is called when frames are published for us
        publishCancellable = publisher.sink { frame in

            let index = frame.frameIndex
            if index > self.maxAddedIndex {
                self.maxAddedIndex = index
            }

            Log.d("frame \(index) added for final inter-frame analysis \(self.maxAddedIndex)")
            self.frames[index] = frame
            self.log()
        }

        /*
        await self.numberRunning.updateCallback() { numberOfFinishingFrames in
            // set the number of processes allowed for non-finishing activities
            let numConcurrentRenders = self.numConcurrentRenders - Int(numberOfFinishingFrames)
            if numConcurrentRenders > 0 {
                TaskRunner.maxConcurrentTasks = UInt(numConcurrentRenders)
            } else {
                TaskRunner.maxConcurrentTasks = 1
            }
            Log.d("numberOfFinishingFrames \(numberOfFinishingFrames) set TaskRunner.numConcurrentRendersTasks = \(TaskRunner.maxConcurrentTasks)")
        }
        */
    }

    func clearFrame(at index: Int) {
        frames[index] = nil
    }
    
    func incrementCurrentFrameIndex() {
        currentFrameIndex += 1

        log()
    }

    private func log() {
        if let updatable = callbacks.updatable {
            // show what frames are in place to be processed
            TaskWaiter.task(priority: .userInitiated) {
                var padding = ""
                if self.numConcurrentRenders < self.config.progressBarLength {
                    padding = String(repeating: " ", count: (self.config.progressBarLength - self.numConcurrentRenders))
                }
                
                var message: String = padding + ConsoleColor.blue.rawValue + "["
                var count = 0
                let end = self.currentFrameIndex + self.numConcurrentRenders
                for i in self.currentFrameIndex ..< end {
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
                var lowerBound = self.currentFrameIndex + end
                if lowerBound > self.frames.count { lowerBound = self.frames.count }
                
                for i in lowerBound ..< self.frames.count {
                    if let _ = self.frames[i] {
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

    func setAsleep(to value: Bool) {
        self.isAsleep = value
    }

    var framesBetween: Int {
        var ret = maxAddedIndex - currentFrameIndex
        if ret < 0 { ret = 0 }
        
        return ret
    }
    
    var isWorking: Bool {
        get {
            return !isAsleep
        }
    }
    
    func finishAll() async throws {
        Log.d("finishing all")
        try await withLimitedThrowingTaskGroup(of: Void.self) { taskGroup in
            for (_, frame) in frames.enumerated() {
                if let frame = frame {
                    Log.d("adding frame \(frame.frameIndex) to final queue")
                    try await taskGroup.addTask() {

                        while await self.centralClassifier.classify(frame: frame) == false {
                            //Log.w("WAITING")
                            try await Task.sleep(nanoseconds: 1_000_000_000)
                        }
                        
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

        Log.d("finish frame \(frame.frameIndex)")
        
        if let frameCheckClosure = callbacks.frameCheckClosure
        {
            // gui
            Log.d("calling frameCheckClosure for frame \(frame.frameIndex)")
            await frameCheckClosure(frame)
            return
        }            

        // cli and not checked frames go to the finish queue
        Log.d("adding frame \(frame.frameIndex) to the final queue")

        Log.d("frame \(frame.frameIndex) finishing")
        try await frame.finish()
        Log.d("frame \(frame.frameIndex) finished")
    }

    nonisolated func run() async throws {

        let frameCount = await frames.count
        
        var done = false
        try await withThrowingTaskGroup(of: Void.self) { taskGroup in
            while(!done) {
                Log.v("FINAL THREAD running")
                let (cfi, framesCount) = await (currentFrameIndex, frames.count)
                done = cfi >= framesCount
                Log.v("FINAL THREAD done \(done) currentFrameIndex \(cfi) frames.count \(framesCount)")
                if done {
                    Log.d("we are done")
                    continue
                }
                
                let indexToProcess = await currentFrameIndex

                Log.d("indexToProcess \(indexToProcess) shouldProcess[indexToProcess] \(shouldProcess[indexToProcess])")

                
                if !isGUI,         // always process on gui so we can see them all
                   !shouldProcess[indexToProcess]
                {
                    if let frameCheckClosure = callbacks.frameCheckClosure {
                        if let frame = await self.frame(at: indexToProcess) {
                            Log.d("calling frameCheckClosure for frame \(frame.frameIndex)")
                            await frameCheckClosure(frame)
                        } else {
                            Log.d("NOT calling frameCheckClosure for frame \(indexToProcess)")
                        }
                    } else {
                        Log.d("NOT calling frameCheckClosure for frame \(indexToProcess)")
                    }
                    
                    // don't process existing files on cli
                    Log.d("not processing \(indexToProcess)")
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

                Log.i("startIndex \(startIndex) endIndex \(endIndex)")
                
                var haveEnoughFramesToInterFrameProcess = true

                for i in startIndex ... endIndex {
                    Log.v("looking for frame at \(i)")
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
                    await doublyLink(frames: imagesToProcess)    

                    Log.i("FINAL THREAD frame \(indexToProcess) done with inter-frame analysis")
                    await self.incrementCurrentFrameIndex()
                    
                    if startIndex > 0,
                       indexToProcess < frameCount - config.numberFinalProcessingNeighborsNeeded - 1
                    {
                        // maybe finish a previous frame
                        // leave the ones at the end to finishAll()
                        let immutableStart = startIndex
                        Log.v("FINAL THREAD frame \(indexToProcess) queueing into final queue")
                        if let frameToFinish = await self.frame(at: immutableStart - 1) {
                            await self.clearFrame(at: immutableStart - 1)
                            Log.v("FINAL THREAD frame \(indexToProcess) adding task")


                            while(await numberRunning.currentValue() > numConcurrentRenders) {
                                Log.v("FINAL THREAD sleeping")
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                            Log.v("FINAL THREAD finishing sleeping")
                            await frameToFinish.clearOutlierGroupValueCaches()
                            while await self.centralClassifier.classify(frame: frameToFinish) == false {

                                Log.w("WAITING")
                                try await Task.sleep(nanoseconds: 1_000_000_000)
                            }
                            frameToFinish.set(state: .outlierProcessingComplete)
                            await numberRunning.increment()
                            /*try await*/ taskGroup.addTask() { 
                                Log.v("FINAL THREAD frame \(indexToProcess) task running")
                                Log.v("FINAL THREAD frame \(indexToProcess) classified")

//                                try await taskGroup.addTask() { 
                                    // XXX VVV this is blocking other tasks

                                do {
                                    try await self.finish(frame: frameToFinish)
                                } catch {
                                    Log.e("FINAL THREAD frame \(indexToProcess) ERROR \(error)")
                                }
                                await self.numberRunning.decrement()
                                Log.v("FINAL THREAD frame \(indexToProcess) DONE")
                                
  //                              }
                            }
                        }
                        Log.v("FINAL THREAD frame \(indexToProcess) done queueing into final queue")
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




