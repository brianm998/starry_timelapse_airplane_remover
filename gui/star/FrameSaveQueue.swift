import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable

class FrameSaveQueue: ObservableObject {

    class Purgatory {
        var timer: Timer
        let frame: FrameAirplaneRemover
        let block: @Sendable (Timer) -> Void
        let wait_time: TimeInterval // minimum time to wait in purgatory
        
        init(frame: FrameAirplaneRemover,
             waitTime: TimeInterval = 5,
             block: @escaping @Sendable (Timer) -> Void)
        {
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

    @Published var purgatory: [Int: Purgatory] = [:] // both indexed by frame_index
    @Published var saving: [Int: FrameAirplaneRemover] = [:]

    init() { }

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
                Log.i("frame \(frame.frame_index) finishing")
                try await frame.loadOutliers()
                try await frame.finish()
                frame.changesHandled()
                Log.i("frame \(frame.frame_index) finished")

                self.saving[frame.frame_index] = nil
                
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
            }
        }
    }

    func endPurgatory(for frame_index: Int) {
        self.purgatory[frame_index] = nil
    }
    
    func readyToSave(frame: FrameAirplaneRemover,
                     waitTime: TimeInterval = 12,
                     completionClosure: @escaping () async -> Void) {

        Log.w("frame \(frame.frame_index) entering purgatory")
        if let candidate = purgatory[frame.frame_index] {
            candidate.retainLonger()
        } else {
            let candidate = Purgatory(frame: frame, waitTime: waitTime) { timer in
                Task {
                    Log.w("purgatory has ended for frame \(frame.frame_index)")
                    await self.endPurgatory(for: frame.frame_index)
                    await self.saveNow(frame: frame, completionClosure: completionClosure)
                }
            }
            purgatory[frame.frame_index] = candidate
        }
    }
}


