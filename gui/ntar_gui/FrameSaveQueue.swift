import Foundation
import SwiftUI
import Cocoa
import NtarCore
import Zoomable

class FrameSaveQueue {

    class Pergatory {
        var timer: Timer
        let frame: FrameAirplaneRemover
        let block: @Sendable (Timer) -> Void
        let wait_time: TimeInterval = 5 // minimum time to wait in purgatory
        
        init(frame: FrameAirplaneRemover, block: @escaping @Sendable (Timer) -> Void) {
            self.frame = frame
            self.timer = Timer.scheduledTimer(withTimeInterval: wait_time,
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
        Log.w("actually saving frame \(frame.frame_index)")
        self.saving[frame.frame_index] = frame
        Task {
            await self.finalProcessor.final_queue.add(atIndex: frame.frame_index) {
                Log.i("frame \(frame.frame_index) finishing")
                try await frame.loadOutliers()
                try await frame.finish()
                Log.i("frame \(frame.frame_index) finished")
                let dispatchGroup = DispatchGroup()
                dispatchGroup.enter()
                await MainActor.run {
                    self.saving[frame.frame_index] = nil
                    Task {
                        Log.i("frame \(frame.frame_index) about to purge output files")
                        await frame.purgeCachedOutputFiles()
                        Log.i("frame \(frame.frame_index) about to call completion closure")
                        await completionClosure()
                        Log.i("frame \(frame.frame_index) completion closure called")
                        dispatchGroup.leave()
                    }
                }
                dispatchGroup.wait()
            }
        }
    }
    
    func readyToSave(frame: FrameAirplaneRemover, completionClosure: @escaping () async -> Void) {
        Log.w("frame \(frame.frame_index) entering pergatory")
        if let candidate = pergatory[frame.frame_index] {
            candidate.retainLonger()
        } else {
            let candidate = Pergatory(frame: frame) { timer in
                Log.w("pergatory has ended for frame \(frame.frame_index)")
                self.pergatory[frame.frame_index] = nil
                if let _ = self.saving[frame.frame_index] {
                    // go back to pergatory
                    self.readyToSave(frame: frame, completionClosure: completionClosure)
                } else {
                    self.saveNow(frame: frame, completionClosure: completionClosure)
                }
            }
        }
    }
}

