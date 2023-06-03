import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable

class FrameSaveQueue {

    class Pergatory {
        var timer: Timer
        let frame: FrameAirplaneRemover
        let block: @Sendable (Timer) -> Void
        let wait_time: TimeInterval // minimum time to wait in purgatory
        
        init(frame: FrameAirplaneRemover,
             waitTime: TimeInterval = 5,
             block: @escaping @Sendable (Timer) -> Void) {
            self.frame = frame
            self.wait_time = waitTime
            self.timer = Timer.scheduledTimer(withTimeInterval: waitTime,
                                              repeats: false, block: block)
            self.block = block
        }

        func retainLonger() {
            self.timer = Timer.scheduledTimer(withTimeInterval: wait_time,
                                              repeats: false, block: block)
        }
    }

    var pergatory: [Int: Pergatory] = [:] // both indexed by frame_index
    var saving: [Int: FrameAirplaneRemover] = [:]

    let finalProcessor: FinalProcessor
    
    init(_ finalProcessor: FinalProcessor) {
        self.finalProcessor = finalProcessor
    }

    // no purgatory
    func saveNow(frame: FrameAirplaneRemover, completionClosure: @escaping () async -> Void) {
        Log.i("saveNow for frame \(frame.frame_index)")
        // check to see if it's not already being saved
        if self.saving[frame.frame_index] != nil {
            // another save is in progress
            Log.d("setting frame \(frame.frame_index) to readyToSave because already saving frame \(frame.frame_index)")
            self.readyToSave(frame: frame, waitTime: 0.01, completionClosure: completionClosure)
        } else {
            Log.d("actually saving frame \(frame.frame_index)")
            self.saving[frame.frame_index] = frame
            Task {
                frame.changesHandled()
                self.saving[frame.frame_index] = nil
//                await self.finalProcessor.final_queue.add(atIndex: frame.frame_index) {
                Log.i("frame \(frame.frame_index) finishing")
                try await frame.loadOutliers()
                try await frame.finish()
                Log.i("frame \(frame.frame_index) finished")
                //let dispatchGroup = DispatchGroup()
                //dispatchGroup.enter()
                let save_task = await MainActor.run {
                    return Task {
                        Log.i("frame \(frame.frame_index) about to purge output files")
                        await frame.purgeCachedOutputFiles()
                        Log.i("frame \(frame.frame_index) about to call completion closure")
                        await completionClosure()
                        Log.i("frame \(frame.frame_index) completion closure called")
                        //dispatchGroup.leave()
                    }
                }
                await save_task.value
               // dispatchGroup.wait()
//                }
            }
        }
    }
    
    func readyToSave(frame: FrameAirplaneRemover,
                     waitTime: TimeInterval = 5,
                     completionClosure: @escaping () async -> Void) {

        Log.w("frame \(frame.frame_index) entering pergatory")
        if let candidate = pergatory[frame.frame_index] {
            candidate.retainLonger()
        } else {
            let candidate = Pergatory(frame: frame, waitTime: waitTime) { timer in
                Log.w("pergatory has ended for frame \(frame.frame_index)")
                self.pergatory[frame.frame_index] = nil
                if let _ = self.saving[frame.frame_index] {
                    // go back to pergatory
                    // going back to purgatory seems like hell, it never stops :(
                    //self.readyToSave(frame: frame, completionClosure: completionClosure)
                    Log.e("pergatory problem for frame \(frame.frame_index)")
                } else {
                    self.saveNow(frame: frame, completionClosure: completionClosure)
                }
            }
        }
    }
}


