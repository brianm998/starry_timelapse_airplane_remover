import Foundation
import SwiftUI
import Cocoa
import StarCore
import Zoomable

@MainActor class FrameSaveQueue: ObservableObject {

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
    }

    @Published var purgatory: [Int: Purgatory] = [:] // both indexed by frame_index
    @Published var saving: [Int: FrameAirplaneRemover] = [:]

    init() { }

    func doneSaving(frame frame_index: Int) {
        self.saving[frame_index] = nil
    }
    
    // no purgatory
    func saveNow(frame: FrameAirplaneRemover, completionClosure: @escaping () async -> Void) {
        Log.i("saveNow for frame \(frame.frame_index)")
        // check to see if it's not already being saved
        if self.saving[frame.frame_index] != nil {
            // another save is in progress
            Log.i("setting frame \(frame.frame_index) to readyToSave because already saving frame \(frame.frame_index)")
            self.readyToSave(frame: frame, waitTime: 5, completionClosure: completionClosure)
        } else {
            Log.i("actually saving frame \(frame.frame_index)")
            self.saving[frame.frame_index] = frame
            frame.changesHandled()
            Task {
                do {
                    try await frame.loadOutliers()
                    try await frame.finish()

                    let save_task = await MainActor.run {
                        // XXX this VVV doesn't always update in the UI without user action
                        self.doneSaving(frame: frame.frame_index)
                        return Task {
                            await frame.purgeCachedOutputFiles()
                            await completionClosure()
                        }
                    }
                    await save_task.value
                } catch {
                    Log.e("error \(error)")
                }
            }
        }
    }

    func endPurgatory(for frame_index: Int) {
        Log.i("ending purgatory for frame \(frame_index)")
        self.purgatory[frame_index] = nil
    }
    
    func readyToSave(frame: FrameAirplaneRemover,
                     waitTime: TimeInterval = 12,
                     completionClosure: @escaping () async -> Void) {

        if let candidate = purgatory[frame.frame_index] {
            Log.i("frame \(frame.frame_index) is already in purgatory")
        } else {
            Log.i("frame \(frame.frame_index) entering purgatory")
            let candidate = Purgatory(frame: frame, waitTime: waitTime) { timer in
                Log.i("purgatory has ended for frame \(frame.frame_index)")
                Task {
                    await MainActor.run {
                        /*await*/ self.endPurgatory(for: frame.frame_index)
                        /*await*/ self.saveNow(frame: frame, completionClosure: completionClosure)
                    }
                }
            }
            Log.i("starting purgatory for frame \(frame.frame_index)")
            purgatory[frame.frame_index] = candidate
        }
    }
}


