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
    }

    @Published var purgatory: [Int: Purgatory] = [:] // both indexed by frameIndex
    @Published var saving: [Int: FrameAirplaneRemover] = [:]

    init() { }

    func frameIsInPurgatory(_ frameIndex: Int) -> Bool {
        return purgatory.keys.contains(frameIndex)
    }
    
    func doneSaving(frame frameIndex: Int) {
        self.saving[frameIndex] = nil
    }
    
    // no purgatory
    func saveNow(frame: FrameAirplaneRemover, completionClosure: @escaping () async -> Void) {
        Log.i("saveNow for frame \(frame.frameIndex)")
        // check to see if it's not already being saved
        if self.saving[frame.frameIndex] != nil {
            // another save is in progress
            Log.i("setting frame \(frame.frameIndex) to readyToSave because already saving frame \(frame.frameIndex)")
            self.readyToSave(frame: frame, waitTime: 5, completionClosure: completionClosure)
        } else {
            Log.i("actually saving frame \(frame.frameIndex)")
            self.saving[frame.frameIndex] = frame
            frame.changesHandled()
            Task {
                do {
                    try await frame.loadOutliers()
                    try await frame.finish()

                    let save_task = await MainActor.run {
                        // XXX this VVV doesn't always update in the UI without user action
                        self.doneSaving(frame: frame.frameIndex)
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

    func endPurgatory(for frameIndex: Int) {
        Log.i("ending purgatory for frame \(frameIndex)")
        self.purgatory[frameIndex] = nil
    }
    
    func readyToSave(frame: FrameAirplaneRemover,
                     waitTime: TimeInterval = 12,
                     completionClosure: @escaping () async -> Void) {

        if let candidate = purgatory[frame.frameIndex] {
            Log.i("frame \(frame.frameIndex) is already in purgatory")
        } else {
            Log.i("frame \(frame.frameIndex) entering purgatory")
            let candidate = Purgatory(frame: frame, waitTime: waitTime) { timer in
                Log.i("purgatory has ended for frame \(frame.frameIndex)")
                Task {
                    await MainActor.run {
                        /*await*/ self.endPurgatory(for: frame.frameIndex)
                        /*await*/ self.saveNow(frame: frame, completionClosure: completionClosure)
                    }
                }
            }
            Log.i("starting purgatory for frame \(frame.frameIndex)")
            purgatory[frame.frameIndex] = candidate
        }
    }
}


